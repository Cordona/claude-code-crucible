# shellcheck shell=sh
#
# glab-mr-common.sh — the shared helpers behind procedure-glab-mr's three
#                     command scripts (find-mr.sh, create-mr.sh, update-mr.sh):
#                     process diagnostics, glab's chattiness pins, argument
#                     validation, `glab` preconditions, and comma-list parsing.
#
# SOURCED, NEVER EXECUTED. There is no shebang and no `main` — the three command
# scripts dot-source this file immediately after their own `set -eu`.
#
# READING glab's OUTPUT lives in the SIBLING glab-mr-output.sh, not here. That
# split is deliberate: those three helpers parse an UNTRUSTED external stream and
# carry their own security history (SEC-001/002/003), so they change for reasons
# nothing in this file shares. procedure-gh-pr has no equivalent surface at all
# and therefore has only one lib — do not force the two skills into symmetry.
#
# WHAT THIS FILE DOES NOT DO (its SRP boundary — keep it):
#   * It does NOT define usage() — that text is per-script and stays there.
#   * It does NOT build or run a `glab` command. Building a command's argv IS
#     that command's own responsibility, and POSIX makes the point structurally:
#     a `set --` inside a function rebinds only THAT function's positional
#     parameters, so an argv builder cannot live here even if one wanted it to.
#   * It does NOT know what a merge request is. Nothing here mentions an iid, a
#     source branch, or a description file.
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
# WHY THIS IS NOT SHARED WITH procedure-gh-pr, even though warn/error/need_arg/
# is_positive_int/split_csv_list are BYTE-IDENTICAL to that skill's copies: the
# two skills deploy to the hub INDEPENDENTLY, so a cross-skill `.` source would
# resolve to a path that may simply not be there — and it would fail at RUNTIME,
# invisibly, on the first real MR operation rather than at deploy time. The
# duplication is the cheaper failure mode. It mirrors the existing note at
# update-pr.sh's is_positive_int ("kept byte-identical … so the two siblings
# cannot drift apart") — when you change one of those helpers, change BOTH files.
#

LC_ALL=C
export LC_ALL

# Pin glab's own optional output/behavior so stdout stays deterministic and
# parseable and this non-interactive script can never block on a prompt:
#   GLAB_NO_PROMPT        — glab must never ask this script anything.
#   GLAB_CHECK_UPDATE     — suppresses the "new version available" notice and
#                           the network round-trip that produces it.
#   GLAB_SHOW_WHATS_NEW   — suppresses the one-time post-upgrade banner.
# For the two WRITE scripts, GLAB_NO_PROMPT is a second belt alongside their
# mandatory `--yes`: `--yes` skips the submission confirmation, GLAB_NO_PROMPT
# stops glab asking anything else.
GLAB_NO_PROMPT=true
GLAB_CHECK_UPDATE=false
GLAB_SHOW_WHATS_NEW=false
export GLAB_NO_PROMPT GLAB_CHECK_UPDATE GLAB_SHOW_WHATS_NEW

PROG=${0##*/}

warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# ---------------------------------------------------------------------------
# Argument validators
# ---------------------------------------------------------------------------

# is_valid_gitlab_project_path VALUE — allow-list: letters, digits, '.', '_',
# '-' per segment, and ONE OR MORE '/'-separated segments, with no empty
# segment and no '.'/'..' path segment.
#
# WHY this is NOT procedure-gh-pr's is_valid_repo_slug: a GitHub slug is always
# exactly OWNER/REPO (that validator hard-rejects a second '/'), but GitLab
# supports nested groups, so a real project path can be
# "group/subgroup/project" or deeper. Rejecting the extra segments would make
# every subgroup project unreachable. A LONE segment with no '/' at all is still
# rejected: a bare project name is never a valid full path.
#
# VALUE is interpolated into `glab` arguments, so this rejects both disallowed
# characters and dot-segment path traversal (e.g. "g/..", "../p") before that
# ever happens.
#
# NEVER unify this with the GitHub validator behind one parameterized helper.
# The two look similar and mean opposite things: the arm GitHub needs (reject a
# second '/') is exactly the arm GitLab must not have.
is_valid_gitlab_project_path() {
	case "$1" in
		*[!A-Za-z0-9._/-]*) return 1 ;;   # character allow-list
		*//*) return 1 ;;                 # empty segment
		/*|*/) return 1 ;;                # leading / trailing slash
		..|../*|*/..|*/../*) return 1 ;;  # parent-dir traversal segment
		.|./*|*/.|*/./*) return 1 ;;      # current-dir segment
		*/*) return 0 ;;                  # at least one separator: accept
		*) return 1 ;;                    # a single bare segment: reject
	esac
}

# is_valid_confirmed_host VALUE — allow-list for the host the ACCOUNT GATE
# confirmed, before it becomes this process's GITLAB_HOST: letters, digits, '.',
# '-', '_' and an optional ':port'. Rejects whitespace, shell metacharacters, a
# leading '-', and any empty label. Spelled the way `glab auth status` reports a
# host — and the way manage_glab_accounts.sh's own is_valid_hostname accepts one
# — so the gate's answer can be passed straight through.
#
# A SCHEME-QUALIFIED value ("https://gitlab.com") is rejected on purpose: glab
# accepts both spellings, so allowing them here would let two different strings
# name one host, and the whole point of this flag is a single unambiguous target
# the caller and this script agree on.
#
# ONLY find-mr.sh and update-mr.sh call this. create-mr.sh correctly has NO call
# site — it takes no --confirmed-host at all, because its required --repo-dir
# already pins the host to a local checkout whose remote IS the host (a stronger
# guarantee, which glab itself verifies). Do NOT add a call site there.
is_valid_confirmed_host() {
	case "$1" in
		'') return 1 ;;
		*[!A-Za-z0-9._:-]*) return 1 ;;
		-*) return 1 ;;
		.*|*.|*..*) return 1 ;;
		*) return 0 ;;
	esac
}

# is_positive_int VALUE — 0 only for a canonical positive decimal integer.
# Digits-only is NOT enough: a bare '0' is not positive, and a leading-zero form
# ('007') is not the iid GitLab would echo back. Both used to slip through and
# surface as a confusing `glab` failure (exit 1) instead of the usage error
# (exit 2) they are. Kept byte-identical to procedure-gh-pr's gh-pr-common.sh so
# the two siblings cannot drift apart.
#
# Only update-mr.sh calls this (find/create take no artifact number); it lives
# here for cohesion with the other validators.
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

# require_glab — exit 1 unless the GitLab CLI is on PATH.
require_glab() {
	if ! command -v glab >/dev/null 2>&1; then
		error "GitLab CLI (glab) is not installed"
		warn  "install it from https://gitlab.com/gitlab-org/cli then re-run"
		exit 1
	fi
}

# require_awk REASON — exit 1 unless awk is on PATH. REASON completes the
# sentence "awk is not installed (…)" and is a PARAMETER because each caller
# needs awk for a genuinely different job: find-mr.sh to count results,
# create-mr.sh for the duplicate-MR pre-check, update-mr.sh to read the MR URL
# back.
require_awk() {
	if ! command -v awk >/dev/null 2>&1; then
		error "awk is not installed ($1)"
		exit 1
	fi
}

# require_glab_auth — exit 1 unless `glab` is authenticated ANYWHERE. Always
# called AFTER require_glab, since it invokes glab.
#
# A bare `glab auth status` only checks the instance of the CURRENT CONTEXT, so
# a caller working on a self-managed project from an unrelated cwd could fail it
# spuriously; `--all` covers every configured instance. Try the bare form first
# (it is the cheapest and works on any glab), then --all. Only both failing means
# glab is genuinely not authenticated anywhere.
require_glab_auth() {
	if ! glab auth status >/dev/null 2>&1 && ! glab auth status --all >/dev/null 2>&1; then
		error "glab is installed but not authenticated"
		warn  "authenticate with: glab auth login"
		exit 1
	fi
}

# init_tmp_err PREFIX — create the temp file this script captures glab's stderr
# into, publish it as TMP_ERR, and arm its cleanup traps.
#
# PREFIX is a parameter because the mktemp TEMPLATE differs per script
# (pm-find-mr / pm-create-mr / pm-update-mr), which is what makes a leaked file
# attributable to the script that leaked it.
#
# TMP_ERR is set as a GLOBAL on purpose: a POSIX sh function has no private
# scope, and the callers read $TMP_ERR directly afterwards. The traps likewise
# arm the SHELL's handlers, not the function's.
#
# THE ABSOLUTIZATION IS LOAD-BEARING, not merely defensive — keep it. mktemp
# echoes back the template it was given, so a RELATIVE $TMPDIR yields a relative
# path. create-mr.sh redirects into $TMP_ERR from inside a subshell that has cd'd
# into --repo-dir: with a relative path that would drop a stray file in the
# user's checkout while the cleanup trap unlinked a different (cwd-relative)
# path. find-mr.sh and update-mr.sh never change directory, so for those two it
# IS merely defensive — but it is applied uniformly, from one place, so the three
# siblings cannot drift apart.
#
# INT/TERM as well as EXIT: a Ctrl-C during a slow `glab mr list`/`create`/
# `update` would otherwise leak the temp file (the auth scripts and both test
# harnesses in this body of work already trap all three).
#
# NOTE — procedure-gh-pr's init_tmp_err deliberately has NEITHER the
# absolutization NOR the INT/TERM traps. That is not drift: no gh-pr script ever
# changes directory, and adding them there would be an untested behavior change.
# Do not "sync" the two.
init_tmp_err() {
	TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/$1.err.XXXXXX")
	case $TMP_ERR in
		/*) ;;
		*) TMP_ERR="$PWD/$TMP_ERR" ;;
	esac
	trap 'rm -f "$TMP_ERR"' EXIT
	trap 'rm -f "$TMP_ERR"; exit 130' INT TERM
}

# emit_captured_stderr — re-print whatever glab wrote to $TMP_ERR, indented two
# spaces, on OUR stderr. Always paired with an error() that says which call
# failed, so the indented block reads as that error's detail.
emit_captured_stderr() {
	sed 's/^/  /' "$TMP_ERR" >&2
}

# ---------------------------------------------------------------------------
# Comma-list parsing (POSIX sh has no arrays; a newline-separated string is the
# portable stand-in). Every repeatable list flag across create-mr.sh and
# update-mr.sh — nine of them — needs IDENTICAL comma-split + trim + append
# behavior, so the whole job is these TWO helpers rather than one
# byte-identical-except-for-the-variable-name append function per list.
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
# by a name argument: `ADD_LABELS=$(accumulate "$ADD_LABELS" "$2")` keeps the
# target variable at the call site, where the reader can see it, and needs no
# `eval` and no string-keyed dispatcher — the pattern this codebase's own
# conventions reject.
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
