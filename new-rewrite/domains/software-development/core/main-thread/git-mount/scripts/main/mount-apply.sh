#!/usr/bin/env sh
# Applies one or more trees' committed work to the human's working tree as a
# patch, and keeps what undoes it in the checkout's git folder.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gm_ function exits on its own failure, and one in a condition is there for its status; a read inside a test or a message gives an empty or wrong value the test then refuses, or only shortens the message
set -eu
# git apply writes the checkout's files under the human's own umask.
caller_umask=$(umask)
umask 077

usage() {
	cat <<'USAGE'
usage: sh mount-apply.sh --effort FOLDER --name NAME [--name NAME]...

Puts the named trees' committed work into their repository's main checkout
as uncommitted changes. Use it when the human wants to try that work.

Options:
  --effort FOLDER  the effort's folder, absolute
  --name NAME      a live tree of the effort, all of one repository; repeatable
Requires:  effort open; trees idle and committed; no mount in place; a full
           checkout with a HEAD, no merge or rebase under way, no change of its
           own at a path the mount changes; 2+ trees: identity (git-identity)
Writes:    the checkout's files, never its index or refs; an undo record for
           mount-undo.sh; mount.made; mount.undone first if the last mount was
           committed; 2+ trees: an unreferenced merge commit of their tips
Stdout:    one JSON line {event, target, start, paths, left_alone}: the event's
           absolute path; the tip, or the merge of 2+ tips; the commit patched
           onto; counts of paths mounted and of other uncommitted paths left
Exit:
  0  mounted
  2  refused; only mount.undone or git objects written; reason on stderr
  4  git, jq or a neighbour failed; put back, or stderr says how to by hand
  6  the events lock stayed held; put back: rerun
USAGE
}

gm_prog='mount-apply.sh'
. "$(dirname -- "$0")/../lib/mount.sh"
effort='' names=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --name)
			[ $# -ge 2 ] || gm_refuse "$1 needs a value"
			case $1 in
				--effort) effort=$2 ;;
				--name)
					printf '%s' "$2" | grep -Eq '^[a-z][a-z0-9]*(-[a-z0-9]+)*$' \
						|| gm_refuse "--name $(gm_printable "$2") must be lowercase words joined by dashes"
					case " ${names} " in *" $2 "*) gm_refuse "--name $2 is given twice" ;; *) ;; esac
					names="${names:+${names} }$2" ;;
				*) ;;
			esac
			shift 2 ;;
		*) gm_refuse "unknown argument $1; try --help" ;;
	esac
done
[ -n "${names}" ] || gm_refuse '--name needs a value: a live tree of the effort'
gm_find_self "$0"
gm_find_core
gm_check_effort "${effort}"
live_trees="${gm_skills}/git-worktree/scripts/internal/worktree-trees.sh"
facts="${gm_skills}/git-worktree/scripts/main/worktree-facts.sh"
busy="${gm_skills}/git-worktree/scripts/internal/worktree-busy.sh"
merge="${gm_skills}/git-commit/scripts/internal/commits-merge.sh"
message="${gm_skills}/git-commit/scripts/main/commit-message.sh"
gm_require_files "${live_trees}" "${facts}" "${busy}" "${merge}" "${message}"
state=$(sh "${gm_core_state}" --effort "${gm_effort_given}") || exit 2
[ "${state}" = open ] || gm_refuse "the effort is ${state}; a mount is made only while it's open"
gm_make_work

problems=0
refuse_later() {
	gm_warn "$1"
	problems=$((problems + 1))
}

# Writes gm_work/trees, "<name><TAB><branch><TAB><tip>" per tree, from
# git-worktree's live trees and facts; sets repo from the first tree.
read_trees() {
	sh "${live_trees}" --effort "${gm_effort_given}" >"${gm_work}/live" || gm_fail 'worktree-trees.sh of git-worktree failed'
	first=${names%% *}
	first_path=$(jq -r --arg n "${first}" '.[] | select(.name == $n) | .path' "${gm_work}/live")
	[ -n "${first_path}" ] || gm_refuse "the effort has no live tree named ${first}"
	[ -d "${first_path}" ] || gm_refuse "tree ${first}'s folder ${first_path} is not there"
	sh "${facts}" --repo "${first_path}" --effort "${gm_effort_given}" >"${gm_work}/facts" \
		|| gm_fail 'worktree-facts.sh of git-worktree failed'
	repo=$(jq -r '.repo' "${gm_work}/facts")
	: >"${gm_work}/trees"
	for tree in ${names}; do
		fact=$(jq -c --arg n "${tree}" '.trees[] | select(.name == $n)' "${gm_work}/facts")
		if [ -z "${fact}" ]; then
			if [ -n "$(jq -r --arg n "${tree}" '.[] | select(.name == $n) | .name' "${gm_work}/live")" ]; then
				refuse_later "tree ${tree} is of another repository than ${first}'s ${repo}; expected trees of one repository"
			else
				refuse_later "the effort has no live tree named ${tree}"
			fi
			continue
		fi
		tip=$(printf '%s' "${fact}" | jq -r '.tip // ""')
		[ -n "${tip}" ] || { refuse_later "tree ${tree}'s branch is gone"; continue; }
		changed=$(printf '%s' "${fact}" | jq -r '.uncommitted // 0')
		[ "${changed}" -eq 0 ] \
			|| refuse_later "tree ${tree} has ${changed} uncommitted changes, which a mount would leave out; commit or discard them first"
		printf '%s\t%s\t%s\n' "${tree}" "$(printf '%s' "${fact}" | jq -r '.branch')" "${tip}" >>"${gm_work}/trees"
	done
	[ "${problems}" -eq 0 ] || exit 2
}

require_idle() {
	set --
	for tree in ${names}; do set -- "$@" --name "${tree}"; done
	rc=0
	said=$(sh "${busy}" --effort "${gm_effort_given}" "$@") || rc=$?
	case ${rc} in
		0) ;;
		5) gm_refuse "busy: $(printf '%s' "${said}" | jq -r '.busy | join("; ")')" ;;
		*) gm_fail "worktree-busy.sh failed (exit ${rc})" ;;
	esac
}

# Forgets a finished mount through mount-undo.sh, or refuses the one in place.
check_no_record() {
	rc=0
	sh "${gm_scripts}/internal/mount-record.sh" --repo "${repo}" >"${gm_work}/record" 2>"${gm_work}/stderr" || rc=$?
	case ${rc} in
		5) return 0 ;;
		0) ;;
		2) cat "${gm_work}/stderr" >&2; exit 2 ;;
		*) cat "${gm_work}/stderr" >&2; gm_fail "mount-record.sh failed (exit ${rc})" ;;
	esac
	sh "${gm_scripts}/internal/mount-paths.sh" --repo "${repo}" >"${gm_work}/now" || gm_fail 'mount-paths.sh failed'
	if [ "$(jq -r '.finished' "${gm_work}/now")" = true ]; then
		sh "${gm_scripts}/main/mount-undo.sh" --repo "${repo}" >/dev/null || gm_fail 'mount-undo.sh could not forget the finished mount'
		gm_warn "forgot the finished mount of $(jq -r '[.trees[].name] | join(" ")' "${gm_work}/record"): HEAD holds every mounted path"
		return 0
	fi
	refuse_later "a mount is in place in ${repo}: $(jq -r '"\([.trees[].name] | join(" ")), target \(.target), made by \(.effort)"' "${gm_work}/record"); undo it first (mount-undo.sh)"
}

check_checkout() {
	for under_way in MERGE_HEAD:merge rebase-merge:rebase rebase-apply:rebase CHERRY_PICK_HEAD:cherry-pick \
		REVERT_HEAD:revert sequencer:cherry-pick\ or\ revert BISECT_START:bisect; do
		[ ! -e "${gm_git_dir}/${under_way%%:*}" ] || refuse_later "the checkout ${repo} has a ${under_way#*:} under way; expected none"
	done
	sparse=$(git -C "${repo}" config --type=bool core.sparseCheckout 2>/dev/null) || sparse=false
	[ "${sparse}" != true ] || refuse_later "the checkout ${repo} is sparse; expected a full checkout"
	head=$(git -C "${repo}" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || head=''
	[ -n "${head}" ] || refuse_later "the checkout ${repo} has no HEAD commit"
}

# Sets target to the one tree's tip, or the join of every tip.
find_target() {
	if [ "$(wc -l <"${gm_work}/trees" | tr -d ' ')" -eq 1 ]; then
		target=$(cut -f 3 "${gm_work}/trees")
		return 0
	fi
	jq -n --arg trees "${names}" '{kind: "mount", text: "join the tips of the trees mounted", trailers: {worktree: $trees}}' \
		>"${gm_work}/message-input"
	sh "${message}" --input "${gm_work}/message-input" --out "${gm_work}/message" || gm_fail 'commit-message.sh could not write the message'
	set --
	while IFS= read -r line; do set -- "$@" --commit "${line##*"	"}"; done <"${gm_work}/trees"
	rc=0
	made=$(sh "${merge}" --repo "${repo}" "$@" --message-file "${gm_work}/message" --effort "${gm_effort_given}" \
		2>"${gm_work}/merge-stderr") || rc=$?
	case ${rc} in
		0) cat "${gm_work}/merge-stderr" >&2; target=$(printf '%s' "${made}" | jq -r '.commit') ;;
		3) refuse_later "the tips of ${names} conflict in $(printf '%s' "${made}" | jq -r '.conflicts | join(", ")'); nothing to mount" ;;
		*) cat "${gm_work}/merge-stderr" >&2; exit "${rc}" ;;
	esac
}

# Sets start from effort-commits.sh, whose line is the refusal.
check_range() {
	rc=0
	proof=$(sh "${gm_scripts}/internal/effort-commits.sh" --repo "${repo}" --from "${head}" --to "${target}" \
		--effort "${gm_effort_given}") || rc=$?
	case ${rc} in
		0) start=$(printf '%s' "${proof}" | jq -r '.start') ;;
		5) problems=$((problems + 1)) ;;
		*) gm_fail "effort-commits.sh failed (exit ${rc})" ;;
	esac
}

# Writes the patch and gm_work/spec, one {path, before, after} per line,
# from the same range.
build_patch() {
	# Plumbing diff-tree reads no diff config (prefixes, context, textconv,
	# external drivers), so the patch is the same for every human's setup.
	git -C "${repo}" diff-tree -r -z --no-renames --no-abbrev "${start}" "${target}" >"${gm_work}/raw" 2>"${gm_work}/stderr" \
		|| gm_git_failed 'git diff-tree --raw'
	git -C "${repo}" diff-tree -r -p --binary --full-index --no-renames "${start}" "${target}" >"${gm_work}/patch" 2>"${gm_work}/stderr" \
		|| gm_git_failed 'git diff-tree --binary'
	[ -s "${gm_work}/raw" ] || { refuse_later "the work of ${names} changes nothing since the start ${start}: nothing to mount"; return 0; }
	[ "$(tr -cd '\n' <"${gm_work}/raw" | wc -c | tr -d ' ')" -eq 0 ] \
		|| { refuse_later "the diff of ${names} has a path holding a newline; expected paths without one"; return 0; }
	# Each raw entry is ":<mode> <mode> <sha> <sha> <status>", then its path;
	# a path jq can't read as UTF-8 comes out changed, and is refused.
	tr '\000' '\n' <"${gm_work}/raw" | awk 'NR % 2 == 0' >"${gm_work}/raw-paths"
	jq -Rr . "${gm_work}/raw-paths" 2>/dev/null | cmp -s - "${gm_work}/raw-paths" \
		|| { refuse_later "the diff of ${names} has a path that is not valid UTF-8; expected paths the record can hold"; return 0; }
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -Rsc 'split("\u0000") | . as $f | range(0; (length - 1); 2) | ($f[.] | ltrimstr(":") | split(" ")) as $m
		| {path: $f[. + 1], before: (if $m[0] == "000000" then "absent" else "\($m[0]) \($m[2])" end),
		   after: (if $m[1] == "000000" then "absent" else "\($m[1]) \($m[3])" end)}' "${gm_work}/raw" >"${gm_work}/spec" \
		|| gm_fail 'jq could not read the diff'
	jq -r '.path' "${gm_work}/spec" >"${gm_work}/paths"
	patch_ok=true
}

check_paths_unchanged() {
	sh "${gm_scripts}/internal/mount-states.sh" --repo "${repo}" --paths "${gm_work}/paths" >"${gm_work}/states" || exit $?
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -rs --slurpfile states "${gm_work}/states" '[., $states[0]] | transpose[] | select(.[0].before != .[1].state)
		| "the checkout differs from the start at \(.[0].path): it holds \(.[1].state), the start \(.[0].before)"' \
		"${gm_work}/spec" | head -n 20 >"${gm_work}/changed"
	while IFS= read -r line; do refuse_later "$(gm_printable "${line}")"; done <"${gm_work}/changed"
}

# A staged entry for a mounted path must equal HEAD's or the start's.
check_index() {
	git -C "${repo}" -c core.fsmonitor=false diff-index --cached -z --no-renames --no-abbrev HEAD -- \
		>"${gm_work}/staged" 2>"${gm_work}/stderr" || gm_git_failed 'git diff-index --cached'
	[ -s "${gm_work}/staged" ] || return 0
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -Rsr --slurpfile spec "${gm_work}/spec" '
		($spec | map({key: .path, value: .before}) | from_entries) as $start
		| split("\u0000") as $f
		| range(0; ($f | length) - 1; 2) | {meta: $f[.], path: $f[. + 1]}
		| select($start[.path] != null)
		| (.meta | ltrimstr(":") | split(" ")) as [$head_mode, $index_mode, $head_sha, $index_sha, $change]
		| select($change == "U" or (if $index_mode == "000000" then "absent" else "\($index_mode) \($index_sha)" end) != $start[.path])
		| .path' "${gm_work}/staged" >"${gm_work}/staged-conflicts" 2>"${gm_work}/stderr" || gm_git_failed 'jq reading the staged changes'
	while IFS= read -r staged_path; do
		refuse_later "the checkout's $(gm_printable "${staged_path}") is staged differently from both HEAD and the start; expected its staged entry to match one"
	done <"${gm_work}/staged-conflicts"
}

check_no_submodule() {
	jq -r 'select((.before | startswith("160000")) or (.after | startswith("160000"))) | .path' "${gm_work}/spec" >"${gm_work}/submodules"
	while IFS= read -r path; do
		refuse_later "the diff of ${names} changes the submodule $(gm_printable "${path}"); expected no submodule"
	done <"${gm_work}/submodules"
}

# Writes the patch, the raw copies of each file it replaces or deletes
# (before/<n>, n its index) and the record, before anything is applied.
write_record() {
	mkdir -p -- "${gm_record_dir}" || gm_fail "could not create the record folder ${gm_record_dir}"
	kept=yes
	rm -rf -- "${gm_record_dir}/before"
	mkdir -- "${gm_record_dir}/before" || gm_fail "could not create ${gm_record_dir}/before"
	cp -- "${gm_work}/patch" "${gm_record_dir}/mount.patch" || gm_fail "could not write the patch into ${gm_record_dir}"
	jq -rs 'to_entries[] | select(.value.before | test("^100(644|755) ")) | "\(.key)\t\(.value.path)"' \
		"${gm_work}/spec" >"${gm_work}/to-save"
	while IFS='	' read -r index path; do
		cp -p -- "${repo}/${path}" "${gm_record_dir}/before/${index}" \
			|| gm_fail "could not save $(gm_printable "${path}") into ${gm_record_dir}/before"
	done <"${gm_work}/to-save"
	branch=$(git -C "${repo}" symbolic-ref -q --short HEAD 2>/dev/null) || branch=''
	snapshot=false
	[ "${start}" = "${head}" ] || snapshot=true
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -nc --argjson version "${GM_RECORD_VERSION}" --arg effort "${gm_effort}" --arg repo "${repo}" \
		--rawfile trees "${gm_work}/trees" --arg start "${start}" --argjson snapshot "${snapshot}" --arg target "${target}" \
		--arg head "${head}" --arg branch "${branch}" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --slurpfile spec "${gm_work}/spec" \
		'{version: $version, effort: $effort, repo: $repo,
		  trees: ($trees | rtrimstr("\n") | split("\n") | map(split("\t") | {name: .[0], branch: .[1], tip: .[2]})),
		  start: $start, start_is_snapshot: $snapshot, target: $target, head: $head,
		  branch: (if $branch == "" then null else $branch end), mounted_at: $at,
		  paths: ($spec | map(if .before | test("^100(644|755) ") then .saved = true else . end))}' \
		>"${gm_record_dir}/mount.json.new" || gm_fail "could not write the record into ${gm_record_dir}"
	mv -f -- "${gm_record_dir}/mount.json.new" "${gm_record_dir}/mount.json" || gm_fail "could not write the record into ${gm_record_dir}"
}

apply_patch() {
	applied=yes
	(umask "${caller_umask}" && exec git -C "${repo}" -c core.fsmonitor=false apply --binary --whitespace=nowarn \
		-- "${gm_record_dir}/mount.patch") 2>"${gm_work}/stderr" || gm_git_failed 'git apply in the checkout'
	sh "${gm_scripts}/internal/mount-paths.sh" --repo "${repo}" >"${gm_work}/now" || gm_fail 'mount-paths.sh failed after applying'
	jq -r '.paths[] | select(.now != "mounted") | "after applying, \(.path) is \(.now), not as mounted"' "${gm_work}/now" >"${gm_work}/unverified"
	[ -s "${gm_work}/unverified" ] || return 0
	while IFS= read -r line; do gm_warn "$(gm_printable "${line}")"; done <"${gm_work}/unverified"
	gm_fail 'the applied paths did not verify'
}

# Takes an applied patch out again and removes what this run wrote; when the
# reverse fails, the record stays for the human to reverse by hand.
roll_back() {
	if [ "${applied}" = yes ]; then
		if ! (umask "${caller_umask}" && exec git -C "${repo}" -c core.fsmonitor=false apply -R --binary --whitespace=nowarn \
			-- "${gm_record_dir}/mount.patch") 2>/dev/null; then
			gm_warn "git apply -R could not take the patch out; the record in ${gm_record_dir} stays: reverse it by hand with git apply -R ${gm_record_dir}/mount.patch"
			return 0
		fi
		sh "${gm_scripts}/internal/mount-restore.sh" --repo "${repo}" >/dev/null \
			|| { gm_warn "the saved bytes could not all be put back; the record in ${gm_record_dir} stays"; return 0; }
		gm_warn 'the patch was taken out again; nothing is mounted'
	fi
	rm -rf -- "${gm_record_dir}/mount.json" "${gm_record_dir}/mount.json.new" "${gm_record_dir}/mount.patch" "${gm_record_dir}/before"
	rmdir -- "${gm_record_dir}" 2>/dev/null || :
}

on_exit() {
	[ "${kept}" = no ] || [ "${done}" = yes ] || roll_back
	gm_clean_up
}

count_left_alone() {
	git -C "${repo}" -c core.fsmonitor=false status --porcelain=v1 -z --untracked-files=all --no-renames \
		>"${gm_work}/status" 2>"${gm_work}/stderr" || gm_git_failed 'git status in the checkout'
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -Rr -s --slurpfile spec "${gm_work}/spec" '($spec | map({key: .path, value: true}) | from_entries) as $mounted
		| [split("\u0000")[] | select(length > 3) | .[3:] | select($mounted[.] | not)] | unique | length' "${gm_work}/status"
}

target='' start='' head='' patch_ok=false kept=no applied=no done=no
read_trees
require_idle
gm_set_repo "${repo}"
check_no_record
check_checkout
[ "${problems}" -ne 0 ] || find_target
[ "${problems}" -ne 0 ] || check_range
[ "${problems}" -ne 0 ] || build_patch
if [ "${problems}" -eq 0 ] && [ "${patch_ok}" = true ]; then
	check_paths_unchanged
	check_index
	check_no_submodule
fi
[ "${problems}" -eq 0 ] || exit 2

trap on_exit EXIT
write_record
apply_patch
paths=$(wc -l <"${gm_work}/spec" | tr -d ' ')
jq -n --arg repo "${repo}" --arg names "${names}" --arg target "${target}" --arg start "${start}" --argjson paths "${paths}" \
	'{repo: $repo, names: ($names | split(" ")), target: $target, start: $start, paths: $paths}' >"${gm_work}/body"
# A tree can be dropped while the mount runs; mount.made names live trees
# only, so git-worktree is asked again, and a refusal here takes the patch
# out again.
sh "${live_trees}" --effort "${gm_effort_given}" >"${gm_work}/live-now" || gm_fail 'worktree-trees.sh of git-worktree failed'
for tree in ${names}; do
	[ -n "$(jq -r --arg n "${tree}" '.[] | select(.name == $n) | .name' "${gm_work}/live-now")" ] \
		|| gm_refuse "tree ${tree} was dropped while mount-apply.sh ran; no mount.made was written"
done
rc=0
event=$(sh "${gm_core_writer}" --effort "${gm_effort_given}" --type mount.made --by "${gm_prog}" --body-file "${gm_work}/body") || rc=$?
[ "${rc}" -eq 0 ] || { gm_warn 'mount.made was not written'; exit "${rc}"; }
done=yes
left_alone=$(count_left_alone)
jq -nc --arg event "${event}" --arg target "${target}" --arg start "${start}" --argjson paths "${paths}" --argjson left "${left_alone}" \
	'{event: $event, target: $target, start: $start, paths: $paths, left_alone: $left}'
