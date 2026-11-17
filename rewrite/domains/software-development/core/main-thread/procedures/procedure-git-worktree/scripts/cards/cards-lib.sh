# The card printer of this skill's scripts: human-view's show.sh and its
# lib/render.sh over this skill's views/, and the unsigned line of a commit
# tips-merge.sh or snapshot.sh made unsigned.
# Sourced by a script one folder under scripts/, once own_dir (that folder,
# physical) is set; it sets no shell option; its names start with card_.
# shellcheck shell=sh source-path=SCRIPTDIR/../../../../../../../../framework/core/engine/human-view/scripts/lib
# shellcheck disable=SC2034 # its card_ values are read by the sourcing scripts

# Sets card_show and card_views and sources human-view's lib/render.sh,
# each template "$@" of views/ and show.sh checked by it; returns 1 with
# card_problem naming the first file missing.
card_load_printer() {
	# shellcheck disable=SC2154 # own_dir is the sourcing script's, set before this runs
	card_views="${own_dir}/../../views"
	card_view_scripts="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/human-view/scripts"
	card_render_lib="${card_view_scripts}/lib/render.sh"
	[ -f "${card_render_lib}" ] && [ -r "${card_render_lib}" ] || {
		card_missing=$(printf '%s' "${card_render_lib}" | tr '[:cntrl:]' '?')
		card_problem="${card_missing} not found; expected the procedure-git-worktree and human-view skills installed whole"
		return 1
	}
	# shellcheck source=render.sh
	. "${card_render_lib}"
	# shellcheck disable=SC2310 # its status is the answer; set -e is not relied on inside
	hv_check_printer "${card_view_scripts}" "${card_views}" "$@" || {
		card_problem=${hv_printer_problem}
		return 1
	}
	card_show=${hv_show}
}

# Sets card_effort to $1, a mount record's effort folder, when that is still
# a folder, else "": a missed card is then recorded nowhere.
card_effort_of() {
	card_effort=''
	[ ! -d "$1" ] || card_effort=$1
}

# Sets card_unsigned to the reason on the UNSIGNED: line of tips-merge.sh's
# stderr, saved in file $1 ("" when it has none), and passes its other lines
# on to stderr.
card_read_unsigned() {
	card_unsigned=$(sed -n 's/^UNSIGNED: //p' "$1" | head -n 1) || card_unsigned=''
	grep -v '^UNSIGNED: ' "$1" >&2 || :
}

# Prints the line unsigned for card_unsigned when it is set, recorded as owed
# for effort folder $1 (left out when empty); fails as hv_show_line does.
card_show_unsigned() {
	[ -n "${card_unsigned:-}" ] || return 0
	hv_show_line "${card_show}" "${card_views}" unsigned "$1" --arg reason "${card_unsigned}"
}
