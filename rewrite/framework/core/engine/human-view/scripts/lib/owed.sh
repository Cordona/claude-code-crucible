# The owed-card store's shared rules, one copy for show.sh, its Stop hook and
# the approval gate's scripts: where a session's owed records live, how long a
# record or an idle session folder lives, how many times a missing card is
# sent back, and how a record file is replaced.
# Sourced, so it sets no shell option; its names start with hv_.
# Installed at ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/human-view/scripts/lib/.
# shellcheck shell=sh
# shellcheck disable=SC2034 # its hv_ values are read by the sourcing scripts

# 30 min: long enough to read a card or a plan, short enough that a record
# left by a crashed or abandoned turn soon stops holding a question.
hv_stale_seconds=1800
hv_stale_minutes=$((hv_stale_seconds / 60))
# 2 tries: one or two corrections fix a copy slip; a card still missing after
# that won't be shown, so the stop goes through instead of looping.
hv_max_tries=2

# Succeeds when $1 is safe as one folder or file name part: letters, digits,
# ".", "_" and "-", and not "." or "..".
hv_is_safe_id() {
	case $1 in
		'' | . | .. | *[!A-Za-z0-9._-]*) return 1 ;;
		*) return 0 ;;
	esac
}

# Sets hv_root (absolute), the store of every session.
hv_set_root() {
	hv_root="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/human-view"
	case ${hv_root} in
		/*) ;;
		*) hv_root="$(pwd)/${hv_root}" ;;
	esac
}

# Sets hv_root and, for session $1, hv_session_dir and hv_owed_dir. Fails,
# with hv_path_problem set, when one of them is a symbolic link: a linked
# folder would put the records elsewhere.
hv_set_paths() {
	hv_set_root
	hv_session_dir="${hv_root}/$1"
	hv_owed_dir="${hv_session_dir}/owed"
	hv_path_problem=''
	for hv_path in "${hv_root}" "${hv_session_dir}" "${hv_owed_dir}"; do
		[ ! -L "${hv_path}" ] || hv_path_problem="${hv_path} is a symbolic link; expected a plain folder; try removing the link"
	done
	[ -z "${hv_path_problem}" ]
}

# Removes each plain folder directly in $1, other than the one named $2, in
# which nothing (the folder included) changed within hv_stale_minutes; a
# symbolic link is never followed or removed, and a folder find can't read is
# kept. Fails, with hv_sweep_problem naming the folder, when one can't be
# removed; the others are still swept.
hv_sweep_idle() {
	hv_sweep_problem=''
	for hv_entry in "$1"/*; do
		[ ! -L "${hv_entry}" ] && [ -d "${hv_entry}" ] || continue
		[ "${hv_entry##*/}" != "$2" ] || continue
		hv_recent=$(find "${hv_entry}" ! -mmin "+${hv_stale_minutes}" 2>/dev/null) || continue
		[ -z "${hv_recent}" ] || continue
		rm -rf "${hv_entry}" 2>/dev/null || hv_sweep_problem=${hv_entry}
	done
	[ -z "${hv_sweep_problem}" ]
}

# Replaces file $1 with stdin through a temp file beside it, so a reader never
# sees it half written. It runs in a subshell whose own EXIT trap removes the
# temp file on every way out, a signal included, without replacing the
# caller's traps. Fails, leaving $1 as it was, when it can't be written.
hv_replace_file() (
	hv_temp=''
	trap '[ -z "${hv_temp}" ] || rm -f -- "${hv_temp}"' EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	hv_temp=$(mktemp "${1%/*}/.tmp.XXXXXX" 2>/dev/null) || exit 1
	cat >"${hv_temp}" && mv -f "${hv_temp}" "$1" || exit 1
	hv_temp=''
)
