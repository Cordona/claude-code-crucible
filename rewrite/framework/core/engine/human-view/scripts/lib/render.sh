# The show.sh calls of a script that prints a gate, a card or a line,
# each with one exit mapping: the reader gone or a signal passed straight
# through, and any other failure handed back for the script to name in its
# own exit contract; and the check that show.sh and the script's templates
# are in place before it does any work.
# Sourced, so it sets no shell option; its names start with hv_.
# Installed at ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/human-view/scripts/lib/.
# shellcheck shell=sh
# shellcheck disable=SC2034 # its hv_ values are read by the sourcing scripts

# Sets hv_show to show.sh in human-view's scripts folder $1 once each
# template after $2 (views folder $2, as <name>.jq) and then show.sh are
# readable files. Otherwise fails with hv_printer_problem naming the first
# one missing and the skill to install, for the script to report under its
# own exit code.
hv_check_printer() {
	hv_show="$1/show.sh"
	hv_printer_views=$2
	shift 2
	for hv_template in "$@"; do
		hv_printer_file="${hv_printer_views}/${hv_template}.jq"
		[ -f "${hv_printer_file}" ] && [ -r "${hv_printer_file}" ] && continue
		hv_views_skill
		hv_printer_fault 'card template' "reinstall ${hv_skill}"
		return 1
	done
	hv_printer_file=${hv_show}
	[ -f "${hv_printer_file}" ] && [ -r "${hv_printer_file}" ] && return 0
	hv_printer_fault 'card printer' 'install the human-view skill'
	return 1
}

# Sets hv_printer_problem: $1 is missing, expected at hv_printer_file (each
# control character as "?"), and $2 is how to get it.
hv_printer_fault() {
	hv_shown_file=$(printf '%s' "${hv_printer_file}" | tr '[:cntrl:]' '?')
	hv_printer_problem="$1 missing; expected ${hv_shown_file}; $2"
}

# Sets hv_skill to "the <skill> skill" for hv_printer_views, the skill
# named as show.sh names it (the folder above views/, links kept), or to
# "its skill" when that folder can't be entered.
hv_views_skill() {
	hv_skill_dir=$(CDPATH='' cd -- "${hv_printer_views%/}/.." 2>/dev/null && pwd) || hv_skill_dir=''
	hv_skill_name=${hv_skill_dir##*/}
	case ${hv_skill_name} in
		'' | *[[:cntrl:]]*) hv_skill='its skill' ;;
		*) hv_skill="the ${hv_skill_name} skill" ;;
	esac
}

# Renders JSON $4 through template $3 of views folder $2 with show.sh $1 to
# stdout; show.sh render records nothing, as open-gate.sh records the gate it
# is piped into. Exits with show.sh's status when it is 4 (stdout closed) or
# 129, 130, 143 (a signal). Otherwise fails with that status in
# hv_render_status and hv_render_problem naming it, show.sh's own stderr
# already above.
hv_render_gate() {
	hv_render_status=0
	printf '%s\n' "$4" | sh "$1" render --views "$2" --name "$3" || hv_render_status=$?
	case ${hv_render_status} in
		0) return 0 ;;
		4 | 129 | 130 | 143) exit "${hv_render_status}" ;;
		*) ;;
	esac
	hv_render_problem="show.sh exited ${hv_render_status} (its stderr is above)"
	return "${hv_render_status}"
}

# Prints JSON $5 as card $3 of views folder $2 with show.sh $1, recorded as
# owed for effort folder $4, and as gate $6 when given; an empty $4 or $6 is
# left out. Ends as hv_end_show does.
hv_show_card() {
	hv_card_data=$5
	hv_card_effort=$4
	hv_card_gate=${6-}
	set -- "$1" view --views "$2" --name "$3"
	[ -z "${hv_card_effort}" ] || set -- "$@" --effort "${hv_card_effort}"
	[ -z "${hv_card_gate}" ] || set -- "$@" --gate "${hv_card_gate}"
	hv_render_status=0
	printf '%s\n' "${hv_card_data}" | sh "$@" || hv_render_status=$?
	hv_end_show
}

# Prints line $3 of views folder $2's lines.jq with show.sh $1; the
# arguments after $3 are the line's --arg FIELD VALUE pairs. Ends as
# hv_end_show does.
hv_show_line() {
	hv_line_show=$1 hv_line_views=$2 hv_line_name=$3
	shift 3
	hv_render_status=0
	sh "${hv_line_show}" line --views "${hv_line_views}" --name "${hv_line_name}" "$@" </dev/null ||
		hv_render_status=$?
	hv_end_show
}

# Maps hv_render_status of a show.sh view or line: exits 4 when show.sh was
# killed by SIGPIPE (the reader was gone before the card was written), and
# with its status on 129, 130, 143 (a signal). Otherwise fails as
# hv_render_gate does.
hv_end_show() {
	case ${hv_render_status} in
		0) return 0 ;;
		129 | 130 | 143) exit "${hv_render_status}" ;;
		141) exit 4 ;;
		*) ;;
	esac
	hv_render_problem="show.sh exited ${hv_render_status} (its stderr is above)"
	return "${hv_render_status}"
}
