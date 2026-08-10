# shellcheck shell=sh
#
# pm-diag.sh — process setup + diagnostic helpers shared by every
#              procedure-gh-issues command.
#
# Sets LC_ALL and PROG, and defines warn/error/need_arg plus the captured-stderr
# pair (init_tmp_err/emit_captured_stderr). All diagnostics go to STDERR so
# stdout stays machine-clean for the PM_* keys each command prints — that
# separation is the contract the calling agent parses.
#
# PROG is derived from $0 with a parameter expansion, never `basename`: the test
# harness runs these scripts under a deliberately minimal PATH toolbox that does
# NOT contain basename/dirname/readlink/realpath, so any of those would break
# every command under test.
#
# NOTE ON THE GITLAB SIBLING: procedure-glab-issues has its OWN physically
# separate pm-diag.sh. The two are deliberately NOT shared — the hub deploys each
# skill directory independently (symlinking it), so a cross-family `source` would
# resolve fine in this repo and then fail only at RUNTIME, invisibly past a green
# test suite, for anyone who installs one skill without the other. Duplication
# here is the cheaper failure mode. The two files are near-identical but no longer
# byte-identical: that family's init_tmp_err additionally arms an INT/TERM trap
# (its `glab` calls are slow enough that a Ctrl-C would otherwise leak the temp
# file), and it carries two GitLab-output text helpers this family has no use for.

LC_ALL=C
export LC_ALL

PROG=${0##*/}

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout stays machine-clean)
# ---------------------------------------------------------------------------
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

# need_arg FLAG VALUE — exit 2 unless FLAG was given a non-empty VALUE.
#
# Calls usage(), which each command defines FOR ITSELF and which is therefore
# NOT defined in this file. That is deliberate, not an oversight: the help text
# is part of each command's own user-facing contract. POSIX sh resolves a
# function name at CALL time, not at definition time, so need_arg may be defined
# here and still reach the usage() its caller defines further down.
need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# ---------------------------------------------------------------------------
# Captured tool stderr
#
# Every command here runs its `gh` calls with `2>"$TMP_ERR"` so gh's own
# diagnostics can be re-printed as the DETAIL of this script's error instead of
# interleaving with the machine-clean stdout the calling agent parses. All seven
# commands used to hand-roll the identical mktemp+trap+indent idiom; it lives
# here now so a fix to it lands once.
# ---------------------------------------------------------------------------

# init_tmp_err PREFIX — create the temp file this script captures gh's stderr
# into, publish it as TMP_ERR, and arm its cleanup trap.
#
# PREFIX is a parameter because the mktemp TEMPLATE differs per script
# (pm-create-issue, pm-update-issue, …), which is what makes a leaked file
# attributable to the script that leaked it.
#
# TMP_ERR is set as a GLOBAL on purpose: a POSIX sh function has no private
# scope, and the callers read $TMP_ERR directly afterwards. The `trap` likewise
# arms the SHELL's EXIT handler, not the function's.
#
# A script that later mktemps MORE files (link-children.sh) re-arms its own trap
# with the full list right after each one — this helper owns only the first, and
# a later `trap ... EXIT` simply replaces the handler armed here.
init_tmp_err() {
	TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/$1.err.XXXXXX")
	trap 'rm -f "$TMP_ERR"' EXIT
}

# emit_captured_stderr — re-print whatever gh wrote to $TMP_ERR, indented two
# spaces, on OUR stderr. Always paired with an error() naming the call that
# failed, so the indented block reads as that error's detail.
emit_captured_stderr() {
	sed 's/^/  /' "$TMP_ERR" >&2
}
