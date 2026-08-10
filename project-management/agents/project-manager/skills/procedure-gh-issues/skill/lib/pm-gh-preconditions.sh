# shellcheck shell=sh
#
# pm-gh-preconditions.sh — tooling/auth guards shared by the
#                          procedure-gh-issues commands.
#
# WHY THREE SEPARATE FUNCTIONS AND NOT ONE `require_all`.
# The call ORDER is not uniform across the suite, and it is observable. Five
# commands check gh-present then gh-authenticated back to back; but
# find-duplicate.sh and link-children.sh check gh-present, then AWK, then
# gh-authenticated — the awk guard sits BETWEEN the two halves. Collapsing
# these into one entry point would silently reorder those two commands'
# diagnostics (a machine with gh present-but-unauthenticated AND no awk would
# start reporting the other problem first). Three separate functions let every
# call site keep its own exact sequence, visible in the caller.
#
# require_awk takes its REASON as an ARGUMENT for the same reason: each command
# explains what IT needs awk for ("count results" vs "splice the checklist into
# the epic body"), and those messages are part of the user-facing contract. The
# wording is deliberately NOT standardized here.
#
# Each function exits non-zero itself rather than returning a status: these are
# hard preconditions, and every existing call site treated them as fatal.

# require_gh_cli — exit 1 unless the GitHub CLI is on PATH.
require_gh_cli() {
	if ! command -v gh >/dev/null 2>&1; then
		error "GitHub CLI (gh) is not installed"
		warn  "install it from https://cli.github.com/ then re-run"
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

# require_gh_auth — exit 1 unless gh is authenticated.
require_gh_auth() {
	if ! gh auth status >/dev/null 2>&1; then
		error "gh is installed but not authenticated"
		warn  "authenticate with: gh auth login"
		exit 1
	fi
}
