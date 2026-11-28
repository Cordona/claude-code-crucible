#!/usr/bin/env sh
# Prints what each given path holds in the repository's main checkout, as
# git would store it. Reads only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gm_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh mount-states.sh --repo DIR --paths FILE

Run by mount-apply.sh, mount-paths.sh, mount-restore.sh and mount-undo.sh;
not for main to call. Prints what each path holds in the repository's main
checkout, as git would store it.

Options:
  --repo DIR    DIR, absolute: any folder of the repository or its worktrees
  --paths FILE  one root-relative path per line, each ending in a newline
Writes:   nothing
Stdout:   one JSON array [{path, state}] in FILE's order; state is
          "100644 SHA" (file), "100755 SHA" (executable) or "120000 SHA"
          (symlink), SHA the blob git would store; directory; absent;
          beyond-symlink (a parent folder is a symlink); beyond-file (a
          parent is not a folder); other (a fifo, socket or device)
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
  4  git, jq or readlink failed; the reason is on stderr
USAGE
}

gm_prog='mount-states.sh'
. "$(dirname -- "$0")/../lib/mount.sh"
repo_in='' paths=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--repo | --paths)
			[ $# -ge 2 ] || gm_refuse "$1 needs a value"
			case $1 in --repo) repo_in=$2 ;; --paths) paths=$2 ;; *) ;; esac
			shift 2 ;;
		*) gm_refuse "unknown argument $1; try --help" ;;
	esac
done
gm_find_self "$0"
gm_set_repo "${repo_in}"
[ -f "${paths}" ] || gm_refuse '--paths must be a file of paths'
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
bad=$(jq -Rr 'select(length == 0 or startswith("/") or (split("/") | any(. == "" or . == "." or . == ".." or . == ".git"))) | "\(.)"' "${paths}" | head -n 1) \
	|| gm_fail 'jq could not read --paths'
[ -z "${bad}" ] || gm_refuse "--paths holds $(gm_printable "${bad}"); expected root-relative paths with no empty, ., .. or .git segment"
gm_make_work

# Sets state for checkout path $1; a regular file's is "hash <mode>", its
# path written to fd 3 to be hashed in one git call.
path_state() {
	full=${gm_repo}/$1
	rest=$1 parent=${gm_repo}
	while :; do
		case ${rest} in */*) ;; *) break ;; esac
		parent="${parent}/${rest%%/*}"
		rest=${rest#*/}
		[ ! -L "${parent}" ] || { state='beyond-symlink'; return 0; }
		[ ! -e "${parent}" ] || [ -d "${parent}" ] || { state='beyond-file'; return 0; }
	done
	if [ -L "${full}" ]; then
		target=$(readlink -- "${full}") || gm_fail "readlink failed on $(gm_printable "$1")"
		blob=$(printf '%s' "${target}" | git -C "${gm_repo}" hash-object --stdin) \
			|| gm_fail "git hash-object failed on the symlink $(gm_printable "$1")"
		state="120000 ${blob}"
	elif [ -d "${full}" ]; then
		state='directory'
	elif [ -f "${full}" ]; then
		state='hash 100644'
		[ ! -x "${full}" ] || state='hash 100755'
		printf '%s\n' "$1" >&3
	elif [ -e "${full}" ]; then
		state='other'
	else
		state='absent'
	fi
}

while IFS= read -r path; do
	path_state "${path}"
	printf '%s\n' "${state}"
done <"${paths}" >"${gm_work}/states" 3>"${gm_work}/to-hash"
: >"${gm_work}/hashes"
if [ -s "${gm_work}/to-hash" ]; then
	# hash-object --stdin-paths C-unquotes a line that starts with a quote
	# and drops a trailing CR, so every path goes in C-quoted.
	sed 's/[\\"]/\\&/g; s/^/"/; s/$/"/' "${gm_work}/to-hash" \
		| git -C "${gm_repo}" -c core.fsmonitor=false hash-object --stdin-paths >"${gm_work}/hashes" 2>"${gm_work}/stderr" \
		|| gm_git_failed 'git hash-object of the paths'
fi
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
jq -Rn --rawfile states "${gm_work}/states" --rawfile hashes "${gm_work}/hashes" '
	def lines: rtrimstr("\n") | if . == "" then [] else split("\n") end;
	[inputs] as $paths | ($hashes | lines) as $blobs | ($states | lines) as $kinds
	| reduce range(0; $paths | length) as $i ({out: [], n: 0};
		$kinds[$i] as $s
		| if $s | startswith("hash ") then .out += [{path: $paths[$i], state: "\($s[5:]) \($blobs[.n])"}] | .n += 1
		  else .out += [{path: $paths[$i], state: $s}] end)
	| .out' "${paths}"
