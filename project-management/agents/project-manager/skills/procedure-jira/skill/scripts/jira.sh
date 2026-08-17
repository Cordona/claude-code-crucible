#!/usr/bin/env sh
#
# jira.sh — the DISPATCHER of a single CLI (`jira.sh <command> ...`) over Jira
#            Cloud REST v3 + Agile 1.0, using pure `curl` + `jq`. This file
#            itself does five things: source the engine's units, parse argv
#            into OPT_* globals, run the command's validate_*_args() wrapper,
#            enforce the cross-command scope of a flag carrier shared by
#            several commands (see the --priority scoping block below), and
#            call its cmd_*() entry point. Every option it parses is consumed
#            by a sourced unit — except where the dispatcher itself must scope
#            a shared carrier across commands — which is what makes it a
#            dispatcher rather than an implementation.
#
# SHAPE. The engine is one process assembled from 44 sourced-only units in
# ../lib, in two families:
#   lib/<concern>.sh   the shared core, sourced first and in dependency order:
#                      runtime, usage, sitegate, readonlygate, credentials,
#                      http, validate, projectconfig, accounts, jql, adf,
#                      inline-images, fields, refs, search-core, agile-paging,
#                      issue-set, batch-report.
#   lib/cmd-<name>.sh  one file per command, each owning that command's
#                      validate_<name>_args() + cmd_<name>() and its private
#                      helpers. There are 26, listed in the sourcing loop and
#                      in the two `case "$COMMAND"` tables below.
# Both families are SOURCED, never executed: ../scripts holds only the two real
# entry points, this file and md-to-adf.sh (which is invoked as a subprocess by
# path, never sourced). See SKILL.md for the layout convention this follows.
#
# WHY ONE PROCESS, not 26 standalone scripts: every command shares the SAME
# heavy plumbing — auth/credential handoff, host+site gates, the curl
# transport, the JQL builder, the accountId resolver, the project-config
# loader, and (for every WRITE command) the markdown->ADF converter handoff.
# One process means the security-critical plumbing (credential handling, host
# pinning, JQL escaping, ADF-via-file-never-string) is written and reviewed
# ONCE, not 26 times with 26 chances to drift.
#
# WHY EAGERLY SOURCED UNITS, not one 8000-line file: the units are a
# READABILITY split of that single process, not a library shared across
# process boundaries — nothing outside this skill sources them, and they are
# deployed as one directory. See the "Unit wiring" note below for why the
# sourcing is eager rather than per-command lazy.
#
# The full per-flag reference lives in lib/usage.sh's header, next to the
# usage() text it documents. The per-command notes that used to sit here —
# link direction, transition --plan, and discover's config contract — live in
# lib/cmd-link.sh, lib/cmd-transition.sh and lib/cmd-discover.sh respectively.
#
# Output:
#   READ commands (view, search, workflow, link-types, children, discover and
#   the agile reads boards/board/sprints/sprint/backlog/epics/epic): human mode
#   prints a rendered summary; --json prints the raw response JSON. WRITE
#   commands: human mode prints machine-parseable `JIRA_*=value` lines
#   (create: JIRA_ISSUE_KEY/JIRA_ISSUE_URL; comment: JIRA_COMMENT_ID;
#   transition: JIRA_TRANSITIONED_TO; update: JIRA_UPDATED; link:
#   JIRA_LINKED; worklog: JIRA_WORKLOGGED; watch: JIRA_WATCHED/
#   JIRA_UNWATCHED; vote: JIRA_VOTED/JIRA_UNVOTED; and the version/component/
#   attach/bulk/sprint-write/schedule lines each unit documents) — the
#   --list modes of watch/vote/version/component/attach
#   is a READ (rendered summary / --json passthrough, not a JIRA_* line) —
#   the SAME convention procedure-gh-issues' write scripts use
#   (PM_ISSUE_NUMBER=.../PM_ISSUE_URL=...), not the READ commands' human
#   prose, since a write's "human" output IS a short confirmation, not a
#   record worth rendering; --json prints the raw/structured response
#   instead. Diagnostics go to stderr. Human-rendered TEXT PULLED FROM THE
#   API (summaries, statuses, display names) is stripped of control
#   characters and ANSI escapes before printing — see "Untrusted-response
#   hygiene" below. Note that even control/ANSI-stripped API text is still
#   UNTRUSTED CONTENT authored by other Jira users: if this script's output
#   is fed back into an agent's context, treat it as data, never as
#   instructions.
#
# Exit codes:
#   0  success
#   1  curl/jq absent · credentials unavailable · $JIRA_READ_ONLY set on a
#      write command · $JIRA_CURL_CONFIG's basename not matching the confirmed
#      site · confirmed-site host not in
#      the allow-list · intended-site/confirmed-site mismatch · a Jira API
#      call failed (non-2xx) · no Jira user found for an --assignee/
#      --developer value · a project config file exists but is not valid
#      JSON · an --acceptance-file/--review-file/--developer given without
#      the matching custom_fields mapping configured · a subtask create
#      without a valid parent · no workflow path to a transition target ·
#      a transition step whose post-write status check doesn't match
#      · markdown-to-ADF conversion failed
#   2  usage error (missing/unknown command or option, missing/invalid
#      ticket key, missing --confirmed-site, invalid --limit/--page-size,
#      a write command missing its required fields, --description-file +
#      --append-file given together, watch/vote's --list + --remove given
#      together, watch's --list + --account given together)
#
# =============================================================================
# Security (read before touching the curl/credential code)
# =============================================================================
#
# Token never on argv. Credentials are written to an `mktemp` file
# (umask 077, chmod 600) as a curl config (`user = "email:token"`) and
# consumed via `curl -K <file>`. ONLY THE FILENAME touches curl's argv — the
# email and token themselves never appear as a `-u`/`--user` argument, which
# would be visible to any local user via `ps`.
#
# The credential-handoff INTERFACE is fixed now, before its real
# implementation exists: if $JIRA_CURL_CONFIG names an existing, readable
# file WHOSE BASENAME IS "<confirmed-host>.cfg", this engine uses it AS-IS via
# `curl -K` and never asks how it got
# there — that is procedure-jira-auth's job (Phase 3), a seam that precedes
# its consumer. The basename assertion BINDS that file to the confirmed site
# (procedure-jira-auth stores one file per site as <site>.cfg): a stale or
# mis-paired path would otherwise be spent, silently, against the wrong Jira —
# see resolve_credential_config()'s own note. It applies ONLY to an externally
# supplied file, never to the engine's own mktemp fallback below, whose random
# name was never meant to carry a site. Until that skill exists, this engine
# falls back to
# resolving credentials itself from $JIRA_SITE/$JIRA_EMAIL/$JIRA_TOKEN and
# building its OWN curl-config file the same secure way. Env vars are the
# LAST-RESORT tier of the plan's token-at-rest ordering (keychain -> 600
# file -> env) — this fallback exists so Phase 2 is independently testable,
# not as the final answer for how a human authenticates.
#
# Host allow-list + site gate, BOTH enforced IN THIS
# SCRIPT, not left to prose or the calling agent's discipline:
#   1. `--confirmed-site` is REQUIRED on every command. Absent -> exit 2
#      before any network call (fail closed).
#   2. The confirmed site's host must match $JIRA_HOST_ALLOWLIST_PATTERN
#      (default "*.atlassian.net"). A host outside the shape -> exit 1.
#   3. If $JIRA_SITE is set (the intended site, from the Phase-2 fallback
#      credential path — a stand-in for what a real config/session would
#      supply), it must equal the confirmed host exactly, or this refuses
#      to proceed (exit 1) — this is the "a reflexive yes can't send
#      one client's content to another client's Jira" guard.
#   4. Every request URL is built ONLY from the confirmed host
#      ("https://$CONFIRMED_HOST$path") — jira_curl() additionally
#      RE-CHECKS the host of the URL it is about to hit against
#      $CONFIRMED_HOST as a defense-in-depth invariant (fail closed on any
#      mismatch), even though no caller in this script can currently
#      construct a URL that would trip it. This is an assertion against a
#      FUTURE bug in a security-critical sink, the same "fail secure"
#      posture standard-security asks for on an authorization check — not
#      dead code kept "just in case" for its own sake.
#   5. `--proto '=https'` on every curl call, never `-L` (no redirect
#      following — a redirect could silently retarget the request to an
#      unpinned host), never `-k`/`--insecure`.
#   6. The credential file itself is bound to the confirmed site: an
#      externally supplied $JIRA_CURL_CONFIG must be named
#      "<confirmed-host>.cfg" — compared case-insensitively, because
#      hostnames are — or this refuses to use it (exit 1). See the
#      credential-handoff note above.
#
# Read-only mode ($JIRA_READ_ONLY), the third IN-SCRIPT gate. Set it and
# every WRITE command is refused (exit 1) before any network call and before
# a credential is resolved — see lib/readonlygate.sh for the write/read
# classification and for why a scope enforced only by prose is not enforced:
# the caller reading a ticket's live comments and changelog is reading
# UNTRUSTED text while holding a real credential, so "it was told not to
# write" is exactly the assurance an injected instruction attacks. The
# authoritative classification lives in SKILL.md; that unit is its executable
# form. It covers the one LOCAL write too: `discover --write` overwrites the
# per-project config the write commands later read, so it is classified a
# write even though it changes nothing at the Jira site. And like the host
# pin, the gate is re-asserted at the sink: lib/http.sh's curl helpers refuse
# any non-GET request under $JIRA_READ_ONLY (item 4's "assertion against a
# FUTURE bug", applied to this gate).
#
# The JQL builder is NOT "parameterized" (Jira's REST API has no
# bind-variable API for JQL). Safety instead comes from: field names and
# operators are a FIXED, hardcoded allow-list (never built from user input —
# see build_jql()); every user-supplied VALUE is emitted as a quoted JQL
# string literal with backslash escaped FIRST, then the double quote
# (jql_escape_value()); and the literal "me" maps to the JQL function
# currentUser() rather than being quoted as a string (quoting it would
# search for a user literally named "me"). `jq --arg` protects JSON
# emission (e.g. the search request body) — it does NOT protect the JQL
# SINK, which is a string embedded inside that JSON, not JSON structure
# itself; jql_quoted()/jql_escape_value() are the actual JQL-sink control.
# The raw `--jql` passthrough survives unescaped BY DESIGN: it is "the
# caller querying their own Jira instance with their own token" — the same
# trust boundary as a hand-typed SQL client, not an injection surface this
# engine can or should sanitize.
#
# Untrusted-response hygiene. Text pulled from Jira (summaries,
# display names, status names, comment bodies) is AUTHORED BY OTHER USERS
# and treated as data, never instructions. Every human-rendered field passes
# through strip_control_ansi() before printing, which removes ANSI escape
# sequences and C0/DEL control bytes. This is display-safety (a hostile
# summary can't rewrite a terminal or forge output), not a content filter —
# the text is still untrusted once printed, and doubly so if this script's
# stdout is later fed back into an agent's context (see the Output section
# above).
#
# WRITE-COMMAND security (create/comment/transition/update — Phase 2b): the
# SAME sink discipline as the JQL builder, applied to REST `fields{}`
# envelopes instead of JQL:
#   - Markdown content (description/comment/acceptance/review text) is
#     converted to ADF via md-to-adf.sh and merged into the request body
#     ONLY as a FILE, via `jq --slurpfile`/`--argjson` (merge_json_field()) —
#     it is NEVER string-concatenated into a jq program, NEVER built into a
#     curl argv string, and never passed to `curl` except as `--data @file`.
#     A title/description/summary containing `$()`/backticks/quotes stays
#     completely inert end to end — verified directly by a dedicated test
#     (an injection-shaped --title/--description-file that would execute a
#     command if ANY layer here mishandled it, asserted to leave no trace).
#   - Every dynamic OBJECT KEY this script builds (a config-resolved custom
#     field id like "customfield_16102") is STILL only ever a jq *value*
#     (via `--arg` + jq's `{($k): $v}` computed-key syntax) — never program
#     text, so a malicious/malformed custom_fields mapping in a project
#     config cannot inject jq syntax.
#   - assignee/developer values are NEVER sent as raw email/username
#     strings — always resolved to an opaque accountId first (the same
#     resolve_account_id() the READ path's search --assignee already uses).
#   - transition's BFS walk (compute_transition_path/walk_transition_path)
#     re-verifies the issue's status after EVERY step rather than
#     trusting a 2xx/204 as proof a workflow transition actually applied —
#     a workflow condition/validator can reject a transition silently.
#
# Phase-2c WRITE-COMMAND security (link/worklog/watch/vote): the IDENTICAL
# discipline above, not a new one:
#   - link's type/comment reuse merge_ref_field()/merge_json_field() exactly
#     as create/update already do (--link-type -> {type:{name:...}} via
#     merge_ref_field, --comment-file's ADF via merge_json_field's
#     --slurpfile) — never a hand-built jq program string.
#   - worklog's --time-spent/--started are plain string fields merged via
#     merge_string_field() (`--arg`), the same channel --title/--due-date
#     already use; --comment-file follows the identical ADF-via-file path.
#   - watch's bare-accountId-string body is built via a single static
#     `jq -n --arg id ... '$id'` (per the brief) — the account VALUE is
#     still only ever a jq value, never program text; DELETE's `?accountId=`
#     query parameter is urlencode()'d, the same helper the READ path's
#     view/search already use for `?fields=`/`?query=`.
#   - children's `parent = "KEY"` clause is built through jql_quoted() — the
#     SAME JQL-sink control build_jql() itself uses — and then
#     driven through the EXISTING cmd_search()/build_search_request_body()
#     path verbatim; it does not re-implement JQL escaping or the search
#     request/paging engine.
#
# =============================================================================
# Portability
# =============================================================================
# POSIX sh only (no bashisms). Runs identically on macOS (BSD userland /
# Bash 3.2) and Linux (GNU coreutils). `curl` and `jq` are the only
# non-ubiquitous dependencies and are guarded with `command -v`. jq is used
# ONLY for its `@uri`/`@csv`-style builtins and static, hardcoded programs
# fed via `--arg`/`--argjson`/`--rawfile` — never a dynamically built
# program string, and no Oniguruma regex dependency (unlike this skill's
# sibling md-to-adf.sh). The 44 units this file sources are resolved with pure
# parameter expansion, never dirname/readlink/realpath/basename — the engine
# and write-test suites run every command under a minimal PATH toolbox that
# deliberately excludes all four, so any of them would break those suites.
# (The live-test rig's own toolbox keeps dirname — its harness script, not
# jira.sh, genuinely needs it — so it does not double as this backstop.)
#
set -eu

LC_ALL=C
export LC_ALL

# shellcheck disable=SC2034  # read by runtime.sh's warn()/error(); shellcheck cannot follow the dynamic sourcing loop below
PROG=${0##*/}
# SCRIPT_DIR/LIB_DIR/MD_TO_ADF — everything this file reaches for is located
# RELATIVE TO THIS SCRIPT, using only parameter expansion. Never dirname/
# readlink/realpath/basename: the engine and write-test suites run every
# command under a minimal PATH toolbox that deliberately excludes all four,
# so any of them would break those suites — the same rule (and the same
# idiom) every sibling skill's entry points follow. The `*)` branch is unreachable in
# practice (SKILL.md and the harness always invoke this script by an absolute
# path) but exists so `set -u` can never see an unset SCRIPT_DIR.
#
# LIB_DIR holds the 44 sourced-only units; MD_TO_ADF is the markdown->ADF
# converter, a SIBLING script in this same scripts/ dir consumed BY PATH as a
# subprocess — never sourced, never inlined. Both must be resolved from $0
# rather than a bare relative path, which would resolve against the CALLER's
# cwd.
case "$0" in
	*/*) SCRIPT_DIR=${0%/*} ;;
	*)   SCRIPT_DIR=. ;;
esac
LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck disable=SC2034  # read by lib/adf.sh's require_converter(); see the SC2034 note on PROG above
MD_TO_ADF="$SCRIPT_DIR/md-to-adf.sh"

# ---------------------------------------------------------------------------
# Unit wiring
#
# EAGER sourcing, not lazy, and deliberately so: the call graph across these
# units is genuinely cross-command — cmd_children calls cmd_search, bulk's
# verb application reaches cmd_transition/cmd_comment/cmd_update, and
# schedule reaches resolve_bulk_keys_file which reaches cmd_search. A lazy
# "source only the unit for $COMMAND" map would therefore have to encode that
# graph by hand, and a wrong entry would not fail at load: it would fail at
# RUNTIME, on whichever untested path first reached the unsourced function.
# Sourcing everything costs a few milliseconds and cannot be wrong.
#
# Each unit is checked for readability first so a broken/partial deployment
# fails with a named diagnostic instead of a bare "not found" from the shell.
# ---------------------------------------------------------------------------
for _jira_unit in \
	"$LIB_DIR/runtime.sh" "$LIB_DIR/usage.sh" "$LIB_DIR/sitegate.sh" \
	"$LIB_DIR/readonlygate.sh" \
	"$LIB_DIR/credentials.sh" "$LIB_DIR/http.sh" "$LIB_DIR/validate.sh" \
	"$LIB_DIR/projectconfig.sh" "$LIB_DIR/accounts.sh" "$LIB_DIR/jql.sh" \
	"$LIB_DIR/adf.sh" "$LIB_DIR/inline-images.sh" "$LIB_DIR/fields.sh" \
	"$LIB_DIR/refs.sh" "$LIB_DIR/search-core.sh" "$LIB_DIR/agile-paging.sh" \
	"$LIB_DIR/issue-set.sh" "$LIB_DIR/batch-report.sh" \
	"$LIB_DIR/cmd-view.sh" "$LIB_DIR/cmd-workflow.sh" "$LIB_DIR/cmd-search.sh" \
	"$LIB_DIR/cmd-create.sh" "$LIB_DIR/cmd-comment.sh" "$LIB_DIR/cmd-transition.sh" \
	"$LIB_DIR/cmd-update.sh" "$LIB_DIR/cmd-link.sh" "$LIB_DIR/cmd-link-types.sh" \
	"$LIB_DIR/cmd-children.sh" "$LIB_DIR/cmd-discover.sh" "$LIB_DIR/cmd-worklog.sh" \
	"$LIB_DIR/cmd-watch.sh" "$LIB_DIR/cmd-vote.sh" "$LIB_DIR/cmd-version.sh" \
	"$LIB_DIR/cmd-component.sh" "$LIB_DIR/cmd-attach.sh" "$LIB_DIR/cmd-boards.sh" \
	"$LIB_DIR/cmd-board.sh" "$LIB_DIR/cmd-sprints.sh" "$LIB_DIR/cmd-sprint.sh" \
	"$LIB_DIR/cmd-backlog.sh" "$LIB_DIR/cmd-epics.sh" "$LIB_DIR/cmd-epic.sh" \
	"$LIB_DIR/cmd-schedule.sh" "$LIB_DIR/cmd-bulk.sh" ; do
	[ -r "$_jira_unit" ] || {
		printf '%s: error: internal: missing unit: %s\n' "${0##*/}" "$_jira_unit" >&2
		exit 1
	}
	# shellcheck disable=SC1090  # the path is a loop variable by design (see the rationale above); the units are linted individually, each with its own `shellcheck shell=sh` directive
	. "$_jira_unit"
done
unset _jira_unit

# ---------------------------------------------------------------------------
# Command + argument parsing
# ---------------------------------------------------------------------------
COMMAND=${1:-}
case "$COMMAND" in
	-h|--help) usage; exit 0 ;;
	view|search|workflow|create|comment|transition|update|link|link-types|children|discover|worklog|watch|vote|version|component|attach|bulk|boards|board|sprints|sprint|backlog|epics|epic|schedule) shift ;;
	'') usage >&2; error "missing command"; exit 2 ;;
	*) usage >&2; error "unknown command: $COMMAND"; exit 2 ;;
esac

# >>> OPT DEFAULTS BEGIN — STABLE MARKER, DO NOT RENAME OR REMOVE.
# tests/run-engine-tests.sh's P4 driver extracts everything between this marker
# and the matching END marker and sources it, so it replays the REAL defaults
# instead of keeping a hand-written copy that could drift from this file. The
# marker pair is what it brackets on — deliberately, so that renaming or
# reordering any variable below stays a behaviour-preserving edit. The driver
# asserts the extracted block is non-empty, so deleting a marker fails loudly
# rather than silently emptying the range.
OPT_CONFIRMED_SITE=""
OPT_PROJECT=""
OPT_JSON=0
OPT_FIELDS=""
OPT_ASSIGNEE=""
OPT_STATUS=""
OPT_TYPE=""
OPT_LABELS=""
OPT_JQL=""
# bulk: --op selects which single-issue verb to loop; --keys is the explicit
# CSV set selector (the alternative to --jql, which bulk reuses from search).
OPT_OP=""
OPT_KEYS=""
OPT_LIMIT=""
OPT_PAGE_SIZE=""
# When "1", cmd_search paginates a --jql resolve to exhaustion (the FULL
# matching set) instead of stopping at the default 50. bulk --jql toggles it;
# an explicit --limit still overrides it. Not a user-facing flag.
# shellcheck disable=SC2034  # read by cmd-search.sh, set by issue-set.sh; see the SC2034 note on PROG above
SEARCH_UNBOUNDED=0
OPT_PROJECTS_DIR=""
OPT_TITLE=""
OPT_DESCRIPTION_FILE=""
OPT_APPEND_FILE=""
OPT_ACCEPTANCE_FILE=""
OPT_REVIEW_FILE=""
OPT_TEXT_FILE=""
OPT_DUE_DATE=""
OPT_PARENT=""
OPT_PRIORITY=""
OPT_DEVELOPER=""
OPT_RESOLUTION=""
OPT_PLAN=0
OPT_TO=""
OPT_LINK_TYPE=""
OPT_TIME_SPENT=""
OPT_COMMENT_FILE=""
OPT_STARTED=""
OPT_ACCOUNT=""
OPT_REMOVE=0
OPT_LIST=0
OPT_WRITE=0
OPT_FORCE=0
# version / component (Phase-2d) options + mode flags. --list reuses OPT_LIST.
OPT_ID=""
OPT_NAME=""
OPT_DESCRIPTION=""
OPT_RELEASE_DATE=""
OPT_START_DATE=""
OPT_LEAD_ACCOUNT_ID=""
OPT_MOVE_ISSUES_TO=""
# version --delete's two INDEPENDENT reassignment targets (component --delete
# has only the single OPT_MOVE_ISSUES_TO, because a component carries only one
# kind of issue reference; a version carries two — fixVersions and
# affectedVersions — so each gets its own target id).
OPT_MOVE_FIX_ISSUES_TO=""
OPT_MOVE_AFFECTED_ISSUES_TO=""
OPT_RELEASED=0
OPT_CREATE=0
OPT_UPDATE=0
OPT_DELETE=0
OPT_RELEASE=0
OPT_ARCHIVE=0
# Repeatable attach flags (create/update). POSIX sh has no arrays, so each
# --fix-version/--affects-version/--component value is APPENDED as one NL-
# terminated line (names may contain spaces, so line-per-value, never
# space-split); merge_named_refs reads them back line by line.
OPT_FIX_VERSIONS=""
OPT_AFFECTS_VERSIONS=""
OPT_COMPONENTS=""
# attach upload: each --file value APPENDED as one NL-terminated line (paths
# may contain spaces, so line-per-value, never space-split) — same idiom as
# the repeatable --fix-version/--component flags above.
OPT_FILES=""
# Agile reads: --state is the sprint-state CSV filter; --issues is the flag that
# switches sprint/epic from their detail read to their issues read.
OPT_STATE=""
OPT_ISSUES=0
# Sprint WRITE (Cycle-2) options + mode flags. --create/--update reuse the
# shared OPT_CREATE/OPT_UPDATE; --start/--close are sprint-only mode flags.
# --board is the originBoardId for --create; --goal/--end-date are sprint
# fields; --start-date reuses the shared OPT_START_DATE carrier.
OPT_BOARD=""
OPT_GOAL=""
OPT_END_DATE=""
OPT_START=0
OPT_CLOSE=0
# schedule (issue scheduling) target ops — EXACTLY ONE is given. --to-sprint/
# --to-epic carry a value (a numeric sprint id / an epic issue-key); --to-backlog/
# --from-epic are bare flags. --to-backlog additionally REQUIRES --board (reusing
# OPT_BOARD, the same numeric board id --create uses). The issue selector reuses
# OPT_KEYS/OPT_JQL, and --dry-run reuses OPT_PLAN — one idiom across every command.
OPT_TO_SPRINT=""
OPT_TO_BACKLOG=0
OPT_TO_EPIC=""
OPT_FROM_EPIC=0
TICKET_KEY=""
# <<< OPT DEFAULTS END — STABLE MARKER, DO NOT RENAME OR REMOVE.

# Argv -> OPT_*. Every option below is consumed by one of the sourced units,
# never by this file — which is exactly what makes this the dispatcher.
#
# shellcheck disable=SC2034  # block-wide: shellcheck cannot follow the dynamic sourcing loop above, so it sees no reader for ANY of these; the readers are the cmd-*/lib units
while [ $# -gt 0 ]; do
	case "$1" in
		--confirmed-site)          need_arg "$1" "${2:-}"; OPT_CONFIRMED_SITE=$2; shift ;;
		--project)                 need_arg "$1" "${2:-}"; OPT_PROJECT=$2; shift ;;
		--fields)                  need_arg "$1" "${2:-}"; OPT_FIELDS=$2; shift ;;
		--assignee)                need_arg "$1" "${2:-}"; OPT_ASSIGNEE=$2; shift ;;
		--status)                  need_arg "$1" "${2:-}"; OPT_STATUS=$2; shift ;;
		--type)                    need_arg "$1" "${2:-}"; OPT_TYPE=$2; shift ;;
		--labels)                  need_arg "$1" "${2:-}"; OPT_LABELS=$2; shift ;;
		--jql)                     need_arg "$1" "${2:-}"; OPT_JQL=$2; shift ;;
		--op)                      need_arg "$1" "${2:-}"; OPT_OP=$2; shift ;;
		--keys)                    need_arg "$1" "${2:-}"; OPT_KEYS=$2; shift ;;
		--limit)                   need_arg "$1" "${2:-}"; OPT_LIMIT=$2; shift ;;
		--page-size)               need_arg "$1" "${2:-}"; OPT_PAGE_SIZE=$2; shift ;;
		--projects-dir)            need_arg "$1" "${2:-}"; OPT_PROJECTS_DIR=$2; shift ;;
		--title)                   need_arg "$1" "${2:-}"; OPT_TITLE=$2; shift ;;
		--description-file)        need_arg "$1" "${2:-}"; OPT_DESCRIPTION_FILE=$2; shift ;;
		--append-file)             need_arg "$1" "${2:-}"; OPT_APPEND_FILE=$2; shift ;;
		--acceptance-file)         need_arg "$1" "${2:-}"; OPT_ACCEPTANCE_FILE=$2; shift ;;
		--review-file)             need_arg "$1" "${2:-}"; OPT_REVIEW_FILE=$2; shift ;;
		--text-file)               need_arg "$1" "${2:-}"; OPT_TEXT_FILE=$2; shift ;;
		--due-date)                need_arg "$1" "${2:-}"; OPT_DUE_DATE=$2; shift ;;
		--parent)                  need_arg "$1" "${2:-}"; OPT_PARENT=$2; shift ;;
		--priority)                need_arg "$1" "${2:-}"; OPT_PRIORITY=$2; shift ;;
		--developer)               need_arg "$1" "${2:-}"; OPT_DEVELOPER=$2; shift ;;
		--resolution)              need_arg "$1" "${2:-}"; OPT_RESOLUTION=$2; shift ;;
		--plan|--dry-run)          OPT_PLAN=1 ;;
		--to)                      need_arg "$1" "${2:-}"; OPT_TO=$2; shift ;;
		--link-type)               need_arg "$1" "${2:-}"; OPT_LINK_TYPE=$2; shift ;;
		--time-spent)              need_arg "$1" "${2:-}"; OPT_TIME_SPENT=$2; shift ;;
		--comment-file)            need_arg "$1" "${2:-}"; OPT_COMMENT_FILE=$2; shift ;;
		--started)                 need_arg "$1" "${2:-}"; OPT_STARTED=$2; shift ;;
		--account)                 need_arg "$1" "${2:-}"; OPT_ACCOUNT=$2; shift ;;
		--id)                      need_arg "$1" "${2:-}"; OPT_ID=$2; shift ;;
		--name)                    need_arg "$1" "${2:-}"; OPT_NAME=$2; shift ;;
		--description)             need_arg "$1" "${2:-}"; OPT_DESCRIPTION=$2; shift ;;
		--release-date)            need_arg "$1" "${2:-}"; OPT_RELEASE_DATE=$2; shift ;;
		--start-date)              need_arg "$1" "${2:-}"; OPT_START_DATE=$2; shift ;;
		--lead-account-id)         need_arg "$1" "${2:-}"; OPT_LEAD_ACCOUNT_ID=$2; shift ;;
		--move-issues-to)          need_arg "$1" "${2:-}"; OPT_MOVE_ISSUES_TO=$2; shift ;;
		--move-fix-issues-to)      need_arg "$1" "${2:-}"; OPT_MOVE_FIX_ISSUES_TO=$2; shift ;;
		--move-affected-issues-to) need_arg "$1" "${2:-}"; OPT_MOVE_AFFECTED_ISSUES_TO=$2; shift ;;
		--fix-version)             need_arg "$1" "${2:-}"; OPT_FIX_VERSIONS="${OPT_FIX_VERSIONS}${2}${NL}"; shift ;;
		--affects-version)         need_arg "$1" "${2:-}"; OPT_AFFECTS_VERSIONS="${OPT_AFFECTS_VERSIONS}${2}${NL}"; shift ;;
		--component)               need_arg "$1" "${2:-}"; OPT_COMPONENTS="${OPT_COMPONENTS}${2}${NL}"; shift ;;
		--file)                    need_arg "$1" "${2:-}"; OPT_FILES="${OPT_FILES}${2}${NL}"; shift ;;
		--state)                   need_arg "$1" "${2:-}"; OPT_STATE=$2; shift ;;
		--board)                   need_arg "$1" "${2:-}"; OPT_BOARD=$2; shift ;;
		--goal)                    need_arg "$1" "${2:-}"; OPT_GOAL=$2; shift ;;
		--end-date)                need_arg "$1" "${2:-}"; OPT_END_DATE=$2; shift ;;
		--issues)                  OPT_ISSUES=1 ;;
		--start)                   OPT_START=1 ;;
		--close)                   OPT_CLOSE=1 ;;
		--to-sprint)               need_arg "$1" "${2:-}"; OPT_TO_SPRINT=$2; shift ;;
		--to-backlog)              OPT_TO_BACKLOG=1 ;;
		--to-epic)                 need_arg "$1" "${2:-}"; OPT_TO_EPIC=$2; shift ;;
		--from-epic)               OPT_FROM_EPIC=1 ;;
		--released)                OPT_RELEASED=1 ;;
		--create)                  OPT_CREATE=1 ;;
		--update)                  OPT_UPDATE=1 ;;
		--delete)                  OPT_DELETE=1 ;;
		--release)                 OPT_RELEASE=1 ;;
		--archive)                 OPT_ARCHIVE=1 ;;
		--remove)                  OPT_REMOVE=1 ;;
		--list)                    OPT_LIST=1 ;;
		--write)                   OPT_WRITE=1 ;;
		--force)                   OPT_FORCE=1 ;;
		--json)                    OPT_JSON=1 ;;
		-h|--help)                 usage; exit 0 ;;
		--)                        shift; break ;;
		-*)                        usage >&2; error "unknown option: $1"; exit 2 ;;
		*)
			if [ -z "$TICKET_KEY" ]; then TICKET_KEY=$1
			else usage >&2; error "unexpected argument: $1"; exit 2
			fi
			;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

if [ -n "$OPT_LIMIT" ]; then
	case "$OPT_LIMIT" in
		''|*[!0-9]*|0) usage >&2; error "--limit must be a positive integer, got: $OPT_LIMIT"; exit 2 ;;
	esac
fi
if [ -n "$OPT_PAGE_SIZE" ]; then
	case "$OPT_PAGE_SIZE" in
		''|*[!0-9]*|0) usage >&2; error "--page-size must be a positive integer, got: $OPT_PAGE_SIZE"; exit 2 ;;
	esac
fi

JIRA_PROJECTS_DIR=${OPT_PROJECTS_DIR:-${JIRA_PROJECTS_DIR:-$JIRA_PROJECTS_DIR_DEFAULT}}

# ---------------------------------------------------------------------------
# Per-command required-argument validation — BEFORE any tool/site/credential
# check (same ordering as create-issue.sh: your own typo should surface as a
# usage error before this script even asks whether curl/jq are installed).
# ---------------------------------------------------------------------------
assert_confirmed_site_given

case "$COMMAND" in
	view)       validate_view_args ;;
	search)     validate_search_args ;;
	workflow)   validate_workflow_args ;;
	create)     validate_create_args ;;
	comment)    validate_comment_args ;;
	transition) validate_transition_args ;;
	update)     validate_update_args ;;
	link)       validate_link_args ;;
	link-types) validate_link_types_args ;;
	children)   validate_children_args ;;
	discover)   validate_discover_args ;;
	worklog)    validate_worklog_args ;;
	watch)      validate_watch_args ;;
	vote)       validate_vote_args ;;
	version)    validate_version_args ;;
	component)  validate_component_args ;;
	attach)     validate_attach_args ;;
	bulk)       validate_bulk_args ;;
	boards)     validate_boards_args ;;
	board)      validate_board_args ;;
	sprints)    validate_sprints_args ;;
	sprint)     validate_sprint_args ;;
	backlog)    validate_backlog_args ;;
	epics)      validate_epics_args ;;
	epic)       validate_epic_args ;;
	schedule)   validate_schedule_args ;;
esac

# --priority is parsed by the GLOBAL arg loop above (one shared OPT_PRIORITY
# carrier), but only THREE invocations ever read it: create, update, and
# `bulk --op update` — which loops cmd_update and so inherits the field for
# free. On every other command the flag would be accepted and SILENTLY dropped,
# which is the exact failure require_flag_off exists to prevent for --plan and
# worse here: the --plan/consent disclosure never names a flag the engine
# ignored, so the caller believes they set a priority they did not. Before this
# flag existed, `transition K --status Done --priority High` exited 2 ("unknown
# option"); this keeps that refusal loud rather than turning it into a silent
# no-op, using the engine's own foreign-flag guard.
#
# It runs AFTER the per-command validation above, deliberately: a caller whose
# real mistake is `bulk --op frobnicate` must read THAT diagnostic, not this one.
priority_is_supported=0
case "$COMMAND" in
	create|update) priority_is_supported=1 ;;
	bulk)          [ "$OPT_OP" != "update" ] || priority_is_supported=1 ;;
esac
if [ "$priority_is_supported" -eq 0 ]; then
	require_foreign_flag_unset --priority "$OPT_PRIORITY" "create, update, and bulk --op update"
fi

# ---------------------------------------------------------------------------
# Read-only gate ($JIRA_READ_ONLY) — HERE, and deliberately not elsewhere.
#
# AFTER the per-command validation above, because that is what makes the
# classification a single check per command rather than a second, drifting
# re-derivation of each command's mode: "exactly one mode", watch/vote's
# --list-vs---remove exclusivity, and each command's own foreign-flag
# refusals — per-command, not exhaustive; see readonlygate.sh's
# write_mode_flag note on the two cases where a foreign carrier survives —
# have all already fired, so is_write_invocation() reads the same OPT_*
# carriers the command's own validator and cmd_*() read. It also keeps the
# ordering a caller expects — their own typo still surfaces as a usage error
# (exit 2) first.
#
# BEFORE the tool/site/credential preconditions below, because nothing about
# refusing to write depends on curl or jq being installed, on the site
# resolving, or on a credential existing — and refusing here means a read-only
# invocation of a write command never opens a credential file at all, let alone
# reaches lib/http.sh. No network call is possible before this point.
# ---------------------------------------------------------------------------
require_write_allowed

# ---------------------------------------------------------------------------
# Preconditions + dispatch
# ---------------------------------------------------------------------------
command -v curl >/dev/null 2>&1 || { error "curl is not installed"; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
	error "jq is not installed"
	warn  "install it (e.g. https://jqlang.org) then re-run"
	exit 1
fi

require_confirmed_site
resolve_credential_config

case "$COMMAND" in
	view)       cmd_view ;;
	search)     cmd_search ;;
	workflow)   cmd_workflow ;;
	create)     cmd_create ;;
	comment)    cmd_comment ;;
	transition) cmd_transition ;;
	update)     cmd_update ;;
	link)       cmd_link ;;
	link-types) cmd_link_types ;;
	children)   cmd_children ;;
	discover)   cmd_discover ;;
	worklog)    cmd_worklog ;;
	watch)      cmd_watch ;;
	vote)       cmd_vote ;;
	version)    cmd_version ;;
	component)  cmd_component ;;
	attach)     cmd_attach ;;
	bulk)       cmd_bulk ;;
	boards)     cmd_boards ;;
	board)      cmd_board ;;
	sprints)    cmd_sprints ;;
	sprint)     cmd_sprint ;;
	backlog)    cmd_backlog ;;
	epics)      cmd_epics ;;
	epic)       cmd_epic ;;
	schedule)   cmd_schedule ;;
esac
