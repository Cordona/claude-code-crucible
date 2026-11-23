#!/usr/bin/env sh
# Makes a fresh tree usable: plans what to copy with setup-plan.sh, copies
# it with setup-copy.sh and repoints the virtual envs' launchers with
# setup-repoint.sh, printing one line per thing done.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'EOF'
usage: sh worktree-setup.sh --from CHECKOUT --to TREE

Run by worktree-cut.sh; not for main to call.
Copies what git does not carry into a new tree: node_modules, vendor, Python
venvs, and what CHECKOUT/.worktreeinclude lists (root-relative paths, * within
one segment, a trailing / for a folder), but a listed .env, .env.*, auth.json,
.npmrc or local.properties only if git-ignored.

Options:
  --from CHECKOUT  main checkout's top folder, absolute; not a linked worktree
  --to TREE        the new tree's top folder, absolute
Requires:  TREE already added as a git worktree of CHECKOUT
Writes:    copies into TREE only, never overwriting, and points the copied
           venvs' bin/ launchers at TREE; CHECKOUT is untouched
Stdout:    one line per thing done (detected, method, copied, repointed, flag
           symlink, or skipped: exists|tracked|unignored), paths under TREE
Exit:
  0  done; a warning may be on stderr
  2  refused, nothing changed; the reason is on stderr
  4  git or jq missing or failed, or an item not copied or repointed: remove
     the tree
EOF
}

gw_prog='worktree-setup.sh'
readonly TAB='	'
. "$(dirname -- "$0")/../lib/git-worktree.sh"

usage_error() {
	printf '%s: %s\n' "${gw_prog}" "$1" >&2
	printf "Try 'sh %s --help'.\n" "${gw_prog}" >&2
	exit 2
}

# Sets $option_value from "$1 $2", refusing a repeat or a missing value.
take_value() {
	[ -n "$3" ] || usage_error "$1 needs a value; expected $1 VALUE"
	[ -z "$2" ] || usage_error "$1 given twice; expected one"
	option_value=$3
}

parse_args() {
	from='' to=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--from)
				take_value "$1" "${from}" "${2-}"
				from=${option_value}
				;;
			--to)
				take_value "$1" "${to}" "${2-}"
				to=${option_value}
				;;
			*)
				usage_error "unknown option: $(gw_printable "$1"); expected --from, --to or --help"
				;;
		esac
		shift 2
	done
	[ -n "${from}" ] || usage_error '--from missing; expected --from DIR'
	[ -n "${to}" ] || usage_error '--to missing; expected --to DIR'
}

# Prints a line per thing setup-copy.sh did, and repoints each folder it
# copied for a technology with launchers right after its line.
print_done() {
	jq -r '"method \(.method)"' "${gw_work}/done"
	jq -r '.done[] | "\(.did)\t\(.path)\t\(.technology // .target // "")"' "${gw_work}/done" >"${gw_work}/lines"
	while IFS="${TAB}" read -r did path more; do
		case ${did} in
			flag) printf 'flag symlink %s -> %s\n' "${path}" "${more}" ;;
			copied)
				printf 'copied %s\n' "${path}"
				[ -z "${more}" ] || repoint "${more}" "${path}"
				;;
			*) printf '%s %s\n' "${did}" "${path}" ;;
		esac
	done <"${gw_work}/lines"
}

# Repoints folder $2 copied for technology $1 when the plan names launcher
# subfolders for it, and prints how many launchers changed.
repoint() {
	copied_folder=$2
	jq -r --arg t "$1" '.repoint[$t] // [] | .[]' "${gw_work}/plan" >"${gw_work}/subfolders"
	[ -s "${gw_work}/subfolders" ] || return 0
	set -- --from "${from}" --to "${to}" --folder "${copied_folder}"
	while IFS= read -r subfolder; do set -- "$@" --subfolder "${subfolder}"; done <"${gw_work}/subfolders"
	repointed=''
	repointed=$(sh "${own_dir}/setup-repoint.sh" "$@" 2>>"${gw_work}/stderr") || result=4
	[ -z "${repointed}" ] || printf 'repointed %s %s\n' "$(printf '%s' "${repointed}" | jq -r '.repointed')" "${copied_folder}"
}

parse_args "$@"
own_dir=$(dirname -- "$0")
command -v jq >/dev/null 2>&1 || gw_fail 'jq not found; expected jq 1.6+ on PATH'
gw_make_work
sh "${own_dir}/setup-plan.sh" --from "${from}" --to "${to}" >"${gw_work}/plan" || exit $?
jq -r '.detected[] | "detected \(.)"' "${gw_work}/plan"
result=0
sh "${own_dir}/setup-copy.sh" --plan "${gw_work}/plan" >"${gw_work}/done" 2>"${gw_work}/stderr" || result=$?
case ${result} in
	0 | 4) ;;
	*) cat "${gw_work}/stderr" >&2; exit "${result}" ;;
esac
print_done
# The problems come last, after every line of what was done.
cat "${gw_work}/stderr" >&2
exit "${result}"
