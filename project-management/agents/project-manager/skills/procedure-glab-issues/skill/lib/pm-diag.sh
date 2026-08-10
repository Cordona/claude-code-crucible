# shellcheck shell=sh
#
# pm-diag.sh — process setup, diagnostics, and the tiny output helpers shared by
#              EVERY procedure-glab-issues command.
#
# Sets LC_ALL and PROG, and defines warn/error/need_arg, the captured-stderr pair
# (init_tmp_err/emit_captured_stderr), and two text helpers every command needs
# for glab's output (count_lines, pm_strip_jq_quotes). All diagnostics go to
# STDERR so stdout stays machine-clean for the PM_* keys each command prints —
# that separation is the contract the calling agent parses.
#
# WHY THE TWO TEXT HELPERS LIVE HERE and not in a topic-named lib: this is the
# ONE unit every one of the seven commands already sources, and both helpers are
# generic — count_lines counts records in any string, pm_strip_jq_quotes
# normalizes any `glab --jq` row. Each previously sat in a lib named for ONE of
# its consumers' topics (pm-glab-url.sh, pm-glab-labels.sh), which forced
# find-duplicate.sh to source the LABELS unit — inheriting label-pagination
# constants it never uses — just to reach a jq normalizer. This file is the
# family's shared base, not a junk drawer: what belongs here is a helper with no
# topic of its own that every command needs.
#
# PROG is derived from $0 with a parameter expansion, never `basename`: the test
# harness runs these scripts under a deliberately minimal PATH toolbox that does
# NOT contain basename/dirname/readlink/realpath, so any of those would break
# every command under test.
#
# NOTE ON THE GITHUB SIBLING: procedure-gh-issues has its OWN physically separate
# pm-diag.sh. The two are deliberately NOT shared — the hub deploys each skill
# directory independently (symlinking it), so a cross-family `source` would
# resolve fine in this repo and then fail only at RUNTIME, invisibly past a green
# test suite, for anyone who installs one skill without the other. Duplication
# here is the cheaper failure mode. The two are near-identical but no longer
# byte-identical: the two text helpers below are GitLab-output specific, and this
# family's init_tmp_err additionally arms an INT/TERM trap.

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
# Every command here runs its `glab` calls with `2>"$TMP_ERR"` so glab's own
# diagnostics can be re-printed as the DETAIL of this script's error instead of
# interleaving with the machine-clean stdout the calling agent parses. All seven
# commands used to hand-roll the identical mktemp+trap+indent idiom; it lives
# here now so a fix to it lands once.
# ---------------------------------------------------------------------------

# init_tmp_err PREFIX — create the temp file this script captures glab's stderr
# into, publish it as TMP_ERR, and arm its cleanup traps.
#
# PREFIX is a parameter because the mktemp TEMPLATE differs per script
# (pm-glab-create-issue, pm-glab-update-issue, …), which is what makes a leaked
# file attributable to the script that leaked it.
#
# TMP_ERR is set as a GLOBAL on purpose: a POSIX sh function has no private
# scope, and the callers read $TMP_ERR directly afterwards. The `trap` likewise
# arms the SHELL's EXIT handler, not the function's.
#
# TWO traps, not one combined `EXIT INT TERM`: a Ctrl-C during a slow `glab` call
# would otherwise leak the temp file, but a combined handler would clean up and
# then RESUME the interrupted command's error path, which goes on to read the
# file it just unlinked. The INT/TERM handler therefore terminates the script
# itself (130 = SIGINT's conventional status). The EXIT trap still runs after it,
# and a second `rm -f` on an already-removed path is a no-op.
#
# A script that later mktemps MORE files (link-children.sh) re-arms BOTH of its
# own traps with the full list right after each one — this helper owns only the
# first, and a later `trap ...` simply replaces the handlers armed here.
init_tmp_err() {
	TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/$1.err.XXXXXX")
	trap 'rm -f "$TMP_ERR"' EXIT
	trap 'rm -f "$TMP_ERR"; exit 130' INT TERM
}

# emit_captured_stderr — re-print whatever glab wrote to $TMP_ERR, indented two
# spaces, on OUR stderr. Always paired with an error() naming the call that
# failed, so the indented block reads as that error's detail.
emit_captured_stderr() {
	sed 's/^/  /' "$TMP_ERR" >&2
}

# ---------------------------------------------------------------------------
# glab output text helpers (see this file's header for why they live here)
# ---------------------------------------------------------------------------

# count_lines TEXT — number of lines in TEXT, 0 for the empty string. awk's
# END{print NR} counts RECORDS, so a final line with no trailing newline still
# counts (unlike `wc -l`, which counts newline BYTES), and it always exits 0.
count_lines() {
	[ -n "$1" ] || { printf '0\n'; return 0; }
	printf '%s\n' "$1" | awk 'END { print NR }'
}

# pm_strip_jq_quotes TEXT — normalize glab `--jq` output rows: strip a
# SURROUNDING PAIR of double quotes glab may apply to a string result, and drop
# blank lines. awk always exits 0, so this never trips `set -e`.
#
# A SURROUNDING PAIR ONLY, NEVER `gsub(/"/)`. The global form removed EVERY
# quote anywhere in the value and corrupted legitimate data — the three
# consumers each hit or risked a different face of the same bug:
#   * a label legitimately named `say "hi"` came back as `say hi`, so
#     create-issue.sh failed its exact-match lookup and reported "not found"
#     for a label that exists, while ensure-labels.sh reported it missing and
#     tried to re-create it;
#   * a milestone TITLE may equally contain a double quote;
#   * find-duplicate.sh normalizes web_urls, which cannot contain a quote — so
#     the global form had no live defect THERE, but keeping it while claiming
#     parity with the siblings was simply untrue, and the next reader copying
#     the line into a value that CAN hold a quote would inherit the bug.
# Only the surrounding pair is glab's, so only the surrounding pair is removed —
# and only when BOTH ends carry one (`/^".*"$/` is checked FIRST): stripping the
# two ends independently would eat the closing quote of that same `say "hi"`
# name, which ends with a quote without starting with one.
pm_strip_jq_quotes() {
	printf '%s\n' "$1" | awk '{ if ($0 ~ /^".*"$/) { sub(/^"/, ""); sub(/"$/, "") } if ($0 != "") print }'
}
