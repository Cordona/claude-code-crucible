# shellcheck shell=sh
#
# shared-but-safe.sh — a FIXTURE for check-variable-collisions.sh's own
#                      self-test, not production code and never sourced by
#                      jira.sh.
#
# It holds the two shapes the gate must stay QUIET about. Reporting either
# would train the reader to ignore the gate, which is a slower way of having no
# gate at all.
#
# 1. A SHARED NAME WITH NO OVERLAP. vc_outer and vc_inner both write
#    $vc_shared and vc_outer calls vc_inner — but vc_outer CONSUMES its value
#    BEFORE the call and never reads it again, so vc_inner cannot corrupt it.
# 2. A LOOK-ALIKE THAT IS NOT A WRITE. vcs_lookalike contains the text
#    `vcs_type=` after a `)` — but that `)` closes a command substitution, so
#    the text is string content, not an assignment. This is the exact shape the
#    case-branch rule in statement_start() has to steer around: a real branch
#    prefix also ends in `)`, and only the absence of a matching `(` tells the
#    two apart. vcs_caller writes $vcs_type, calls vcs_lookalike and reads
#    $vcs_type afterwards, so the moment that guard is dropped the pair becomes
#    a reported collision and this fixture stops exiting 0.

vc_outer() {
	vc_shared=$1
	printf '%s\n' "$vc_shared"
	vc_inner "independent"
}

vc_inner() {
	vc_shared=$1
	printf '%s' "$vc_shared"
}

vcs_caller() {
	vcs_type=$1
	vcs_lookalike "board"
	printf '%s\n' "$vcs_type"
}

vcs_lookalike() {
	vcs_qs="$(vcs_encode "$1")vcs_type=$1"
	printf '%s' "$vcs_qs"
}

vcs_encode() {
	printf '%s' "$1"
}
