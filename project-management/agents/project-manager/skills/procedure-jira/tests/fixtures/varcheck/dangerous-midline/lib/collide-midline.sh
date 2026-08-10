# shellcheck shell=sh
#
# collide-midline.sh — a FIXTURE for check-variable-collisions.sh's own
#                      self-test, not production code and never sourced by
#                      jira.sh.
#
# The sibling dangerous/ fixture proves the gate sees a LINE-INITIAL write.
# This one proves it sees a MID-LINE one — which for a while it did NOT: Pass 1
# matched `^[ \t]*name=` only, so every `cmd || x=...`, `...; x=...` and
# `then x=...` in skill/lib/ was invisible to it as a write. A live collision of
# exactly that shape was once found by a human reading the code rather than by
# this gate, which is the whole reason this fixture exists.
#
# vcm_inner assigns each of the five names below through a DIFFERENT mid-line
# form and through no other; vcm_outer assigns each line-initially, calls
# vcm_inner, and reads each again afterwards. All five are therefore dangerous
# collisions and all five must be reported. The self-test asserts each BY NAME
# rather than by exit status alone: one fixture exiting 1 would look identical
# whether the gate still sees five forms or only one.
#
# $vcm_case is the newest of the five and the one with the narrowest matcher.
# A case branch's `PATTERN)` prefix went unrecognised for a whole revision after
# the other four forms were closed, which left eleven real writes in skill/
# invisible — $fpa_sep, $fpv_sep and $vid_frac among them had NO recorded write
# at all. Its pattern deliberately carries a `]` and a `|`, the two characters a
# real branch pattern in this engine actually uses, so a matcher narrowed back
# to a bare `*)` would still fail here.

vcm_outer() {
	vcm_semi=$1
	vcm_and=$1
	vcm_or=$1
	vcm_then=$1
	vcm_case=$1
	vcm_inner "clobber"
	printf '%s %s %s %s %s\n' \
		"$vcm_semi" "$vcm_and" "$vcm_or" "$vcm_then" "$vcm_case"
}

vcm_inner() {
	vcm_seen=1; vcm_semi=$1
	[ -z "$1" ] && vcm_and=empty
	[ -n "$1" ] || vcm_or=fallback
	if [ -n "$1" ]; then vcm_then=$1; fi
	case "$1" in
		clobber|clob[0-9]) vcm_case=$1 ;;
	esac
	printf '%s%s%s%s%s%s' \
		"$vcm_seen" "$vcm_semi" "$vcm_and" "$vcm_or" "$vcm_then" "$vcm_case"
}
