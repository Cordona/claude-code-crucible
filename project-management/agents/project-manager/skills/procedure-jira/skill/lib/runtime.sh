# shellcheck shell=sh
#
# runtime.sh — the engine's process-wide runtime: the tuning//layout constants,
#              every mutable global, the temp workdir, the EXIT/INT/TERM/HUP
#              teardown, and the two diagnostic writers every other unit calls.
#
# Sourced FIRST (see jira.sh's sourcing loop): the globals it declares are the
# state every later unit reads and writes, and its `trap` must be installed
# before any unit can create a temp file. It owns no command logic and makes no
# network call.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.
#
# shellcheck disable=SC2034  # file-wide, deliberately: declaring cross-unit globals IS this file's entire job, and shellcheck lints each unit in isolation so it can never see the readers in the other 42

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout stays machine-clean)
# ---------------------------------------------------------------------------
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
JIRA_HOST_ALLOWLIST_PATTERN=${JIRA_HOST_ALLOWLIST_PATTERN:-'*.atlassian.net'}
JIRA_PROJECTS_DIR_DEFAULT="$HOME/.claude/skills/procedure-jira/projects"
ESC=$(printf '\033')
NL='
'

# ---------------------------------------------------------------------------
# Global state (plain vars — this script is a single short-lived process,
# not a library, and POSIX sh has no `local`; every var below starts empty/0
# so cleanup() can safely check "was this actually created" on any exit path).
#
# CONVENTION for anyone adding or editing a command: every helper function's
# scratch/parameter variables are plain globals scoped ONLY by a name that is
# unique to that function. Because POSIX sh has no `local`, a name reused
# across two functions that can appear in the same call chain (e.g. one helper
# calling another) will silently clobber the caller's copy — and since the
# engine was split into 43 sourced units, the two colliding functions are
# rarely on the same screen any more.
#
# The form that survives that split is a SHORT PER-FUNCTION PREFIX, derived
# from the function's own name: resolve_account_id's `rai_value`/
# `rai_account_id`, build_search_request_body's `bsrb_*`, merge_named_refs'
# `mnr_*`, agile_paginate's `fpa_*`. Never a bare `key`/`value`/`url`/`jql`/
# `config_file` — those read as "any function's scratch", which is exactly
# what makes them collide. tests/check-variable-collisions.sh is the automated
# guard: it fails the build on a name two functions in one call chain share
# across the callee boundary.
# ---------------------------------------------------------------------------
WORKDIR=""
RESP_COUNTER=0
CURL_CONFIG_FILE=""
CURL_CONFIG_IS_OWN=0
CONFIRMED_HOST=""
PROJECT_CONFIG_FILE=""
JIRA_HTTP_BODY_FILE=""
JIRA_HTTP_CODE=""
MERGE_COUNTER=0
ADF_COUNTER=0
TRANS_COUNTER=0
APPEND_COUNTER=0
MEDIA_COUNTER=0
# The truncation verdict issue-set.sh's compute_truncation() publishes and
# both batch commands read back. BATCH_RESOLVED_LIMIT is an integer or the
# bare `null` literal, because batch-report.sh feeds it straight to
# `jq --argjson`.
BATCH_TRUNCATED=false
BATCH_RESOLVED_LIMIT=null

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	ec=$?
	if [ -n "$WORKDIR" ]; then rm -rf "$WORKDIR" 2>/dev/null || true; fi
	if [ "$CURL_CONFIG_IS_OWN" -eq 1 ] && [ -n "$CURL_CONFIG_FILE" ]; then
		rm -f "$CURL_CONFIG_FILE" 2>/dev/null || true
	fi
	exit "$ec"
}
trap cleanup EXIT INT TERM HUP

ensure_workdir() {
	if [ -z "$WORKDIR" ]; then
		WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/jira.work.XXXXXX")
	fi
}

# ---------------------------------------------------------------------------
# Untrusted-response hygiene
# ---------------------------------------------------------------------------

# strip_control_ansi — reads stdin, writes stdout with ANSI CSI sequences
# and C0/DEL control bytes removed. Deliberately implemented with sed/tr
# (not jq regex) so this script has no Oniguruma dependency.
strip_control_ansi() {
	sed "s/${ESC}\\[[0-9;]*[a-zA-Z]//g" | tr -d '\000-\010\013\014\016-\037\177'
}

# ---------------------------------------------------------------------------
# Small generic helpers
# ---------------------------------------------------------------------------

urlencode() {
	jq -rn --arg v "$1" '$v | @uri'
}

# downcase VALUE -> VALUE lowercased. Portable (`tr`, not the bashism
# `${var,,}`) — used to compare a Jira-reported status against a caller's
# possibly differently-cased --status/--resolution value; the
# CANONICAL (API-reported or config-graph) casing is always what gets
# displayed/stored, never the downcased form itself.
downcase() {
	# shellcheck disable=SC2018,SC2019  # deliberately ASCII-only (LC_ALL=C, matches this script's ascii_downcase-based jq comparisons — Jira status names are ASCII), not locale-dependent [:upper:]/[:lower:]
	printf '%s' "$1" | tr 'A-Z' 'a-z'
}
