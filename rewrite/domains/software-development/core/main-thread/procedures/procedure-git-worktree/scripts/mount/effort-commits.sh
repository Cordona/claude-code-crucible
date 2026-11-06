#!/usr/bin/env sh
# Proves a commit builds only on an effort's own work on top of another: the
# start is its ancestor, and every commit between carries the effort's
# Effort trailer or is a snapshot of the checkout taken on the start. Reads
# only.
set -eu
umask 077

readonly PROG='effort-commits.sh'
readonly SNAPSHOT_MESSAGE='crucible(snapshot): uncommitted changes'
readonly SNAPSHOT_AUTHOR='crucible'
readonly SNAPSHOT_EMAIL='crucible@crucible.invalid'
readonly EFFORT_TRAILER='Effort'
# The C locale keeps the shell byte-wise.
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside --repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

usage() {
	cat <<EOF
usage: sh ${PROG} --repo DIR --effort-id ID --from SHA --to SHA
       sh ${PROG} --help | -h

Checks that --to holds only effort work on top of --from: --from is --to
or an ancestor of it, and every commit of from..to carries the trailer
"${EFFORT_TRAILER}: ID" or is a snapshot commit (subject "${SNAPSHOT_MESSAGE}",
author ${SNAPSHOT_AUTHOR} <${SNAPSHOT_EMAIL}>, one parent: --from).
Several snapshots must share one tree. Reads only.

--repo DIR      absolute path of a folder of the repository
--effort-id ID  the effort id the commits' ${EFFORT_TRAILER} trailer holds
--from SHA      the commit the effort work must start on
--to SHA        the commit to check

stdout, one JSON line:
  {"ok":true,"from":<sha>,"start":<sha>,"commits":N}
    start: the first snapshot commit found (newest first), else --from;
    the commit whose tree the paths must hold before the work applies
  {"ok":false,"reason":R,"commit":<sha>|null,"subject":<text>|null}
    R: not_ancestor (commit null), foreign_commit or snapshot_mismatch
    (the first such commit, newest first); stderr says it in one line

exit codes:
  0  the range is the effort's work
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: a value that is not absolute, no commit in DIR or a bad
     effort id
  4  environment: git or jq missing or failed
  5  refused: the range holds other work

needs: POSIX sh, git 2.26+, jq 1.6+
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

die() {
	warn "$2"
	exit "$1"
}

usage_error() {
	warn "$1"
	printf "Try 'sh %s --help'.\n" "${PROG}" >&2
	exit 2
}

# Prints $1 with each control character as "?", so a value can't split a stderr line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Sets $option_value from "$1 $2", refusing a repeat or a missing value.
take_value() {
	[ -n "$3" ] || usage_error "$1 needs a value; expected $1 $4"
	[ -z "$2" ] || usage_error "$1 given twice; expected one"
	option_value=$3
}

parse_args() {
	repo='' effort_id='' from='' to=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--repo)
				take_value "$1" "${repo}" "${2-}" DIR
				repo=${option_value}
				;;
			--effort-id)
				take_value "$1" "${effort_id}" "${2-}" ID
				effort_id=${option_value}
				;;
			--from)
				take_value "$1" "${from}" "${2-}" SHA
				from=${option_value}
				;;
			--to)
				take_value "$1" "${to}" "${2-}" SHA
				to=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --repo, --effort-id, --from, --to or --help"
				;;
		esac
		shift 2
	done
	[ -n "${repo}" ] || usage_error '--repo missing; expected --repo DIR'
	[ -n "${effort_id}" ] || usage_error '--effort-id missing; expected --effort-id ID'
	[ -n "${from}" ] || usage_error '--from missing; expected --from SHA'
	[ -n "${to}" ] || usage_error '--to missing; expected --to SHA'
}

load_dependencies() {
	command -v git >/dev/null 2>&1 || die 4 'git not found; expected git 2.26+ on PATH'
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
}

# Sets from_sha and to_sha.
check_inputs() {
	shown_repo=$(printable "${repo}")
	case ${repo} in
		/*) ;;
		*) die 3 "--repo ${shown_repo} is not absolute; expected an absolute path" ;;
	esac
	git -C "${repo}" -c core.fsmonitor=false rev-parse --git-dir >/dev/null 2>&1 ||
		die 3 "--repo ${shown_repo} is not a git repository folder; expected one"
	case ${effort_id} in
		*[[:cntrl:]]*)
			shown_id=$(printable "${effort_id}")
			die 3 "--effort-id ${shown_id} holds a control character; expected the effort id"
			;;
		*) ;;
	esac
	resolve --from "${from}"
	from_sha=${resolved}
	resolve --to "${to}"
	to_sha=${resolved}
}

# Sets resolved to the full sha of option $1's commit $2.
resolve() {
	resolved=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --verify --quiet --end-of-options "$2^{commit}" 2>/dev/null) || {
		shown_commit=$(printable "$2")
		die 3 "$1 ${shown_commit} is not a commit in ${shown_repo}; expected a commit sha"
	}
}

check_ancestor() {
	ancestor_rc=0
	git -C "${repo}" -c core.fsmonitor=false merge-base --is-ancestor "${from_sha}" "${to_sha}" 2>"${work_dir}/stderr" ||
		ancestor_rc=$?
	case ${ancestor_rc} in
		0) ;;
		1)
			refuse not_ancestor '' '' \
				"commit ${from_sha} is not an ancestor of ${to_sha}; expected the seats' work built on top of HEAD"
			;;
		*) git_failed 'git merge-base --is-ancestor' ;;
	esac
}

# Writes work_dir/range.json: from..to newest first, each commit's sha,
# parents, tree, author, subject and Effort trailer values.
read_range() {
	git -C "${repo}" -c core.fsmonitor=false log -z --no-show-signature \
		--format="%H%n%P%n%T%n%an%n%ae%n%(trailers:key=${EFFORT_TRAILER},valueonly,unfold,separator=%x1f)%n%s" \
		"${from_sha}..${to_sha}" -- >"${work_dir}/range" 2>"${work_dir}/stderr" || git_failed 'git log of the range'
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -Rsc 'split("\u0000") | map(select(. != "") | split("\n")
		| {commit: .[0], parents: (.[1] | split(" ") | map(select(. != ""))), tree: .[2], name: .[3], email: .[4],
			efforts: (.[5] | split("\u001f")), subject: (.[6:] | join("\n"))})' \
		"${work_dir}/range" >"${work_dir}/range.json" 2>/dev/null || die 4 'jq could not read the git log of the range'
}

# Sets verdict to the first commit that is no effort work, or the start.
judge_range() {
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	verdict=$(jq -c --arg effort "${effort_id}" --arg from "${from_sha}" --arg message "${SNAPSHOT_MESSAGE}" \
		--arg name "${SNAPSHOT_AUTHOR}" --arg email "${SNAPSHOT_EMAIL}" '
		def snapshot: .subject == $message and .name == $name and .email == $email and .parents == [$from];
		reduce .[] as $commit ({commits: length, snapshot: null, refusal: null};
			if .refusal != null then .
			elif any($commit.efforts[]; . == $effort) then .
			elif ($commit | snapshot | not) then .refusal = {reason: "foreign_commit", commit: $commit}
			elif .snapshot == null then .snapshot = $commit
			elif .snapshot.tree != $commit.tree then .refusal = {reason: "snapshot_mismatch", commit: $commit}
			else .
			end)' "${work_dir}/range.json") || die 4 'jq could not judge the range'
}

report_verdict() {
	reason=$(printf '%s\n' "${verdict}" | jq -r '.refusal.reason // ""') || die 4 'jq could not read the verdict'
	if [ -n "${reason}" ]; then
		commit=$(printf '%s\n' "${verdict}" | jq -r '.refusal.commit.commit') || die 4 'jq could not read the verdict'
		subject=$(printf '%s\n' "${verdict}" | jq -r '.refusal.commit.subject') || die 4 'jq could not read the verdict'
		shown_subject=$(printable "${subject}")
		case ${reason} in
			foreign_commit) line="commit ${commit} (${shown_subject}) is not this effort's work; expected only effort commits between HEAD and the seats" ;;
			*) line="commit ${commit} (${shown_subject}) is a snapshot holding other changes than the first one found; expected every snapshot under the seats to hold one tree" ;;
		esac
		refuse "${reason}" "${commit}" "${subject}" "${line}"
	fi
	printf '%s\n' "${verdict}" | jq -c --arg from "${from_sha}" \
		'{ok: true, from: $from, start: (.snapshot.commit // $from), commits: .commits}' || die 4 'jq could not print the result'
}

# Prints the refusal of reason $1 for commit $2 (subject $3, both may be
# empty) and exits 5 with stderr line $4.
refuse() {
	jq -nc --arg reason "$1" --arg commit "$2" --arg subject "$3" \
		'{ok: false, reason: $reason, commit: (if $commit == "" then null else $commit end),
		  subject: (if $commit == "" then null else $subject end)}' || die 4 'jq could not print the result'
	warn "$4"
	exit 5
}

git_failed() {
	first_line=$(head -n 1 "${work_dir}/stderr" 2>/dev/null) || first_line=''
	shown_line=$(printable "${first_line}")
	die 4 "$1 failed: ${shown_line}"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
}

work_dir=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
load_dependencies
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-effort-commits.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
check_inputs
check_ancestor
read_range
judge_range
report_verdict
