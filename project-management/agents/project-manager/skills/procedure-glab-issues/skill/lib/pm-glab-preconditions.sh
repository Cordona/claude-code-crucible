# shellcheck shell=sh
#
# pm-glab-preconditions.sh — tooling/auth guards shared by the
#                            procedure-glab-issues commands.
#
# WHY THREE SEPARATE FUNCTIONS AND NOT ONE `require_all`.
# The call ORDER is not uniform across the suite, and it is observable. Six
# commands check glab-present, then AWK, then glab-authenticated — the awk
# guard sits BETWEEN the two halves. close-issue.sh needs no awk at all and
# checks only the two. Collapsing these into one entry point would either
# reorder those diagnostics or force close-issue.sh to demand a tool it never
# uses. Three separate functions let every call site keep its own exact
# sequence, visible in the caller.
#
# require_awk takes its REASON as an ARGUMENT for the same reason: each command
# explains what IT needs awk for ("read the note URL back" vs "page the label
# lookup"), and those messages are part of the user-facing contract. The
# wording is deliberately NOT standardized here.
#
# Each function exits non-zero itself rather than returning a status: these are
# hard preconditions, and every existing call site treated them as fatal.

# require_glab_cli — exit 1 unless the GitLab CLI is on PATH.
require_glab_cli() {
	if ! command -v glab >/dev/null 2>&1; then
		error "GitLab CLI (glab) is not installed"
		warn  "install it from https://gitlab.com/gitlab-org/cli then re-run"
		exit 1
	fi
}

# require_awk REASON — exit 1 unless awk is on PATH. REASON completes the
# sentence "awk is not installed (required to <REASON>)".
require_awk() {
	if ! command -v awk >/dev/null 2>&1; then
		error "awk is not installed (required to $1)"
		exit 1
	fi
}

# require_glab_auth — exit 1 unless glab is authenticated.
#
# The BARE form checks only the CURRENT CONTEXT's instance, so `--all` is the
# fallback before declaring glab unauthenticated (same as procedure-glab-mr):
# an account authenticated against a different configured host than the cwd's
# git remote implies would otherwise be reported as "not authenticated".
require_glab_auth() {
	if ! glab auth status >/dev/null 2>&1 && ! glab auth status --all >/dev/null 2>&1; then
		error "glab is installed but not authenticated"
		warn  "authenticate with: glab auth login"
		exit 1
	fi
}
