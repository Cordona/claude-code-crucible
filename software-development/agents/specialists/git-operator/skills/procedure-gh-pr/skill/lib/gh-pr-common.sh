# shellcheck shell=sh
#
# gh-pr-common.sh — the shared helpers behind procedure-gh-pr's three command
#                   scripts (find-pr.sh, create-pr.sh, update-pr.sh): process
#                   diagnostics, argument validation, `gh` preconditions, and
#                   comma-list parsing.
#
# SOURCED, NEVER EXECUTED. There is no shebang and no `main` — the three command
# scripts dot-source this file immediately after their own `set -eu`.
#
# WHAT THIS FILE DOES NOT DO (its SRP boundary — keep it):
#   * It does NOT define usage() — that text is per-script and stays there.
#   * It does NOT build or run a `gh` command. Building a command's argv IS that
#     command's own responsibility, and POSIX makes the point structurally: a
#     `set --` inside a function rebinds only THAT function's positional
#     parameters, so an argv builder cannot live here even if one wanted it to.
#   * It does NOT know what a pull request is. Nothing here mentions a PR
#     number, a head branch, or a body file.
#
# WHY `set -eu` IS DELIBERATELY NOT RE-ASSERTED HERE:
#   The caller has already set it, and sourcing must return 0 so it can never
#   trip the caller's own `set -e`. That is also why this file ENDS with a
#   function definition rather than with an expression whose exit status would
#   become the status of the `.` command.
#
# THE ONE DEPENDENCY THAT POINTS BACK AT THE CALLER — need_arg() calls usage(),
# which is defined in the SOURCING SCRIPT, not here. This is deliberate and it
# is safe: POSIX resolves a function name at CALL time, not at definition time,
# and every command script defines usage() before it parses its first argument,
# so usage() is always in scope by the time need_arg() can run. Do not "fix"
# this by moving usage() in here — the help text is per-script by design.
#
# WHY THIS IS NOT SHARED WITH procedure-glab-mr, even though warn/error/
# need_arg/is_positive_int/split_csv_list are BYTE-IDENTICAL to that skill's
# copies: the two skills deploy to the hub INDEPENDENTLY, so a cross-skill
# `.` source would resolve to a path that may simply not be there — and it
# would fail at RUNTIME, invisibly, on the first real PR operation rather than
# at deploy time. The duplication is the cheaper failure mode. This mirrors the
# existing note at update-pr.sh's is_positive_int ("kept byte-identical to
# procedure-glab-mr's update-mr.sh so the two siblings cannot drift apart") —
# when you change one of those helpers, change BOTH files.
#

LC_ALL=C
export LC_ALL

PROG=${0##*/}

warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# ---------------------------------------------------------------------------
# Argument validators
# ---------------------------------------------------------------------------

# is_valid_repo_slug VALUE — allow-list: letters, digits, '.', '_', '-', and
# EXACTLY ONE '/' separating owner/repo, with NO ".." path segment. VALUE is
# interpolated into `gh` arguments, so this rejects both disallowed
# characters and dot-segment path traversal (e.g. "o/..", "../r") before
# that ever happens.
#
# NEVER unify this with procedure-glab-mr's is_valid_gitlab_project_path behind
# one parameterized validator. The `*/*/*` arm below is the whole point: a
# GitHub slug is ALWAYS exactly OWNER/REPO, so a second '/' is rejected — where
# GitLab supports nested subgroups and MUST accept arbitrary depth. The two
# validators look similar and mean opposite things.
is_valid_repo_slug() {
	case "$1" in
		*[!A-Za-z0-9._/-]*) return 1 ;;
		..|../*|*/..|*/../*) return 1 ;;
		*/*/*) return 1 ;;
		*/*) return 0 ;;
		*) return 1 ;;
	esac
}

# is_positive_int VALUE — 0 only for a canonical positive decimal integer.
# Digits-only is NOT enough: a bare '0' is not positive, and a leading-zero form
# ('007') is not the number GitHub would echo back. Both used to slip through and
# surface as a confusing `gh` failure (exit 1) instead of the usage error
# (exit 2) they are. Kept byte-identical to procedure-glab-mr's
# glab-mr-common.sh so the two siblings cannot drift apart.
#
# Only update-pr.sh calls this (find/create take no artifact number); it lives
# here for cohesion with the other validators, and so the glab-mr twin has an
# obvious counterpart file to stay in step with.
is_positive_int() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;   # empty or a non-digit
		0*) return 1 ;;            # a bare '0', and any leading-zero form
		*) return 0 ;;
	esac
}

# ---------------------------------------------------------------------------
# Preconditions — each one EXITS on failure rather than returning non-zero, so
# a call site reads as a bare statement and cannot accidentally continue past a
# missing tool. Every external binary is guarded before it is used.
# ---------------------------------------------------------------------------

# require_gh — exit 1 unless the GitHub CLI is on PATH.
require_gh() {
	if ! command -v gh >/dev/null 2>&1; then
		error "GitHub CLI (gh) is not installed"
		warn  "install it from https://cli.github.com/ then re-run"
		exit 1
	fi
}

# require_awk REASON — exit 1 unless awk is on PATH. REASON completes the
# sentence "awk is not installed (…)" and is a PARAMETER because each caller
# needs awk for a genuinely different job: find-pr.sh to count results,
# create-pr.sh for the duplicate-PR pre-check. update-pr.sh deliberately calls
# this NOT AT ALL — it never runs awk — so do not add a call site there.
require_awk() {
	if ! command -v awk >/dev/null 2>&1; then
		error "awk is not installed ($1)"
		exit 1
	fi
}

# require_gh_auth — exit 1 unless `gh` is authenticated. Always called AFTER
# require_gh, since it invokes gh.
require_gh_auth() {
	if ! gh auth status >/dev/null 2>&1; then
		error "gh is installed but not authenticated"
		warn  "authenticate with: gh auth login"
		exit 1
	fi
}

# init_tmp_err PREFIX — create the temp file this script captures gh's stderr
# into, publish it as TMP_ERR, and arm its cleanup trap.
#
# PREFIX is a parameter because the mktemp TEMPLATE differs per script
# (pm-find-pr / pm-create-pr / pm-update-pr), which is what makes a leaked file
# attributable to the script that leaked it.
#
# TMP_ERR is set as a GLOBAL on purpose: a POSIX sh function has no private
# scope, and the callers read $TMP_ERR directly afterwards. The `trap` likewise
# arms the SHELL's EXIT handler, not the function's.
#
# NOTE — this is deliberately NOT procedure-glab-mr's richer version. That one
# also absolutizes the path and traps INT/TERM, which it genuinely needs
# (create-mr.sh redirects into $TMP_ERR from inside a subshell that has cd'd
# into --repo-dir). No script here ever changes directory, and adding those
# behaviors would be an untested behavior change riding along in a pure
# refactor. Leave this simple version alone.
init_tmp_err() {
	TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/$1.err.XXXXXX")
	trap 'rm -f "$TMP_ERR"' EXIT
}

# emit_captured_stderr — re-print whatever gh wrote to $TMP_ERR, indented two
# spaces, on OUR stderr. Always paired with an error() that says which call
# failed, so the indented block reads as that error's detail.
emit_captured_stderr() {
	sed 's/^/  /' "$TMP_ERR" >&2
}

# ---------------------------------------------------------------------------
# Comma-list parsing (POSIX sh has no arrays; a newline-separated string is the
# portable stand-in). Every repeatable list flag — --reviewer, --label,
# --assignee, --add-label, --remove-label, --add-reviewer, --remove-reviewer —
# needs IDENTICAL comma-split + trim + append behavior, so the whole job is
# these TWO helpers rather than one near-identical append function per list.
# ---------------------------------------------------------------------------

# split_csv_list VALUE — print each comma-separated, trimmed, non-empty token in
# VALUE on its own line (stdout).
#
# `accumulate` below reads this through a HEREDOC, never by piping into its
# `while read`: the loop must stay in accumulate's OWN shell so its `acc`
# variable survives to the final printf. Piping would put the loop in a further
# subshell and lose every appended token.
split_csv_list() {
	value=$1
	old_ifs=$IFS
	IFS=','
	set -f
	# shellcheck disable=SC2086  # deliberate split of a comma-list on IFS=','; -f (above) blocks globbing
	set -- $value
	set +f
	IFS=$old_ifs
	for tok in "$@"; do
		tok=$(printf '%s' "$tok" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		[ -n "$tok" ] || continue
		printf '%s\n' "$tok"
	done
}

# accumulate CURRENT VALUE — print CURRENT with every comma-separated token of
# VALUE appended as its own line. CURRENT may be empty (then the result is just
# the new tokens). VALUE contributing no usable token leaves CURRENT unchanged,
# so an all-separator value (`--label ,,`, `--add-label ,,`) cannot introduce a
# blank entry.
#
# `accumulate` RETURNS the new list on stdout instead of mutating a global chosen
# by a name argument: `LABELS=$(accumulate "$LABELS" "$2")` keeps the target
# variable at the call site, where the reader can see it, and needs no `eval` and
# no string-keyed dispatcher — the pattern this codebase's own conventions reject.
accumulate() {
	acc=$1
	while IFS= read -r tok; do
		[ -n "$tok" ] || continue
		if [ -z "$acc" ]; then acc=$tok
		else acc="$acc
$tok"
		fi
	done <<EOF
$(split_csv_list "$2")
EOF
	printf '%s' "$acc"
}
