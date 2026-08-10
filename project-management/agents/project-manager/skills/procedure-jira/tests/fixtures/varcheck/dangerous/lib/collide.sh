# shellcheck shell=sh
#
# collide.sh — a FIXTURE for check-variable-collisions.sh's own self-test, not
#              production code and never sourced by jira.sh.
#
# It contains ONE deliberately dangerous collision, in its simplest possible
# form: vc_outer assigns $vc_shared, calls vc_inner (which reassigns the SAME
# name), and then READS $vc_shared again AFTER that call. In POSIX sh there is
# no `local`, so vc_inner's assignment clobbers vc_outer's value across the
# call boundary — exactly the defect the gate exists to find. If the gate ever
# stops reporting this file, the gate is broken.

vc_outer() {
	vc_shared=$1
	vc_inner "clobber"
	printf '%s\n' "$vc_shared"
}

vc_inner() {
	vc_shared=$1
	printf '%s' "$vc_shared"
}
