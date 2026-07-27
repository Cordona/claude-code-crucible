#!/usr/bin/env sh
#
# jira.sh — a single dispatcher CLI (`jira.sh <command> ...`) over Jira Cloud
#            REST v3, using pure `curl` + `jq`. Owns the shared engine core
#            (auth handoff, host/site gates, the secure curl helper, the JQL
#            builder, the accountId resolver, the project-config loader) plus
#            all fourteen commands: the Phase-2a READ trio (view, search,
#            workflow), the Phase-2b WRITE quartet (create, comment,
#            transition, update), and the Phase-2c extension set — three READ
#            additions (link-types, children, discover) and four WRITE additions
#            (link, worklog, watch, vote — watch/vote also expose a --list
#            read-only mode).
#
# WHY one engine script, not fourteen near-duplicate ones (a deliberate
# structure decision — see the build report): all fourteen Jira commands
# share the SAME heavy plumbing — auth/credential handoff, host+site gates,
# the curl transport, the JQL builder, the accountId resolver, the project
# config loader, and (for every WRITE command) the markdown->ADF converter
# handoff. Duplicating that plumbing across fourteen self-contained files
# would violate DRY for zero benefit (crucible's "self-contained, no
# external sourcing" rule is about not SOURCING a shared library file across
# process boundaries — it says nothing against one script implementing
# several related subcommands, and the reference oracle this ports from
# (jira.py) is itself exactly this shape: one CLI, many subcommands). A
# single dispatcher also means the security-critical plumbing (credential
# handling, host pinning, JQL escaping, ADF-via-file-never-string) is
# reviewed and gets its security guarantees checked ONCE, not fourteen
# times with fourteen chances to drift.
#
# Usage (READ commands — the Phase-2a trio (see that build report for the
# full flag reference; unchanged by this build) plus three Phase-2c additions):
#   jira.sh view <KEY> --confirmed-site SITE [--fields LIST] [--json] ...
#   jira.sh search --confirmed-site SITE [--project KEY] [--assignee VALUE]
#            [--status STR] [--type STR] [--labels LIST] [--jql QUERY] ...
#   jira.sh workflow <KEY> --confirmed-site SITE [--json] [-h|--help]
#   jira.sh link-types --confirmed-site SITE [--json] [-h|--help]
#   jira.sh children <KEY> --confirmed-site SITE [--fields LIST]
#            [--limit N] [--page-size N] [--json]
#   jira.sh discover <PROJECT> --confirmed-site SITE [--write] [--force]
#            [--projects-dir DIR]
#
# Usage (WRITE commands — Phase 2b + Phase 2c):
#   jira.sh create --project KEY --title STR --confirmed-site SITE
#            [--description-file PATH] [--acceptance-file PATH]
#            [--review-file PATH] [--type STR] [--assignee VALUE]
#            [--labels LIST] [--due-date YYYY-MM-DD] [--parent KEY] [--json]
#   jira.sh comment <KEY> --text-file PATH --confirmed-site SITE [--json]
#   jira.sh transition <KEY> --status TARGET --confirmed-site SITE
#            [--resolution STR] [--plan|--dry-run] [--json]
#   jira.sh update <KEY> --confirmed-site SITE
#            [--title STR] [--description-file PATH | --append-file PATH]
#            [--acceptance-file PATH] [--review-file PATH]
#            [--assignee VALUE] [--developer VALUE] [--labels LIST]
#            [--due-date YYYY-MM-DD] [--parent KEY] [--json]
#   jira.sh link <FROM> --to TO --link-type NAME --confirmed-site SITE
#            [--comment-file PATH] [--json]
#   jira.sh worklog <KEY> --time-spent STR --confirmed-site SITE
#            [--comment-file PATH] [--started STR] [--json]
#   jira.sh watch <KEY> --confirmed-site SITE
#            [--account VALUE] [--remove] [--list] [--json]
#   jira.sh vote <KEY> --confirmed-site SITE [--remove] [--list] [--json]
#
#   --confirmed-site SITE   REQUIRED on every command. The
#                            human-confirmed Jira Cloud site, e.g.
#                            "mycompany.atlassian.net" (an "https://" prefix
#                            and/or trailing path are stripped). This is NOT
#                            optional and there is no default — a command
#                            given without it fails closed before any
#                            network call. See "Site gate" below.
#   --title STR              (create, update) The issue summary. A plain
#                            scalar flag (not a file) — like --status/--jql
#                            on search, it only ever reaches jq via --arg,
#                            never a shell/jq program string, so it stays
#                            inert even when it contains `$()`/backticks.
#   --description-file PATH  (create, update) Markdown, converted to ADF via
#                            md-to-adf.sh and merged into fields.description.
#                            create: optional. update: REPLACES the existing
#                            description; mutually exclusive with
#                            --append-file.
#   --append-file PATH       (update only) Markdown, converted to ADF and
#                            APPENDED to the issue's EXISTING description
#                            (fetch -> extend -> replace-whole-doc).
#   --acceptance-file PATH   (create, update) Markdown -> ADF, merged under
#                            the project config's custom_fields.
#                            acceptance_criteria field id. Requires that
#                            mapping to exist — see require_custom_field()'s
#                            note on why this fails loud where the oracle
#                            silently dropped the update.
#   --review-file PATH        (create, update) Same as --acceptance-file, for
#                            custom_fields.review_notes.
#   --text-file PATH          (comment only) Markdown, converted to ADF and
#                            posted as the comment body. REQUIRED — there is
#                            deliberately no --text string flag, matching
#                            this repo's own body-is-always-a-file rule
#                            (see procedure-gh-issues) for the same reason:
#                            large/arbitrary content should never be
#                            interpolated into a caller's shell command.
#   --assignee VALUE          (search) "me" -> JQL currentUser(); "@me"/an
#                            email -> resolved accountId. (create, update)
#                            ALWAYS resolved to accountId ("@me" or an
#                            email/username) — {"id": accountId} on the
#                            wire. (search only, additionally) --status STR
#                            (search) JQL `status = "STR"`.
#   --type STR                (search) JQL `type = "STR"`. (create) The
#                            issue type; resolved through the project
#                            config's type_aliases, validated against
#                            issue_types when configured, and — when the
#                            resolved type is a subtask_types entry —
#                            requires --parent and validates the parent's
#                            own type against subtask_parent_types.
#   --labels LIST             (search) JQL OR'd clause. (create, update) A
#                            comma-separated list -> fields.labels — this
#                            REPLACES the whole array on update (a
#                            deliberate divergence from the oracle's
#                            ACLI-only "labelsToAdd" partial-update; see
#                            merge_labels_field()'s call sites).
#   --jql QUERY                (search only) Raw JQL passthrough.
#   --fields LIST              (view, search) Comma-separated field list.
#   --due-date YYYY-MM-DD      (create, update) -> fields.duedate.
#   --parent KEY                (create, update) -> fields.parent.key.
#   --developer VALUE            (update only) Resolved to accountId, merged
#                            under the project config's custom_fields.
#                            developer field id as {"accountId": accountId}
#                            — note the DIFFERENT inner key from --assignee's
#                            {"id": accountId}: this is Jira's own REST
#                            distinction between the built-in assignee
#                            reference and a custom user-picker field.
#   --resolution STR              (transition only) STRICTLY OPT-IN — the
#                            resolution field is set ONLY when this flag is
#                            explicitly given, on ANY target status
#                            (including Closed). There is deliberately NO
#                            auto-default (e.g. no "Closed implies
#                            Resolved") — a workflow whose Closed screen has
#                            no resolution field 400s if this script sets
#                            one unasked; a workflow that genuinely
#                            requires one 400s clearly either way, and the
#                            caller re-runs with --resolution.
#   --plan, --dry-run              (transition only) Computes and PRINTS the
#                            full walked path (+ any resolution/injected
#                            comment) WITHOUT transitioning anything — no
#                            POST is ever issued. See "transition --plan"
#                            below: this is what the orchestrator's P4
#                            consent gate discloses BEFORE authorizing the
#                            real walk.
#   --limit N / --page-size N  (search, children) Pagination bounds.
#   --projects-dir DIR         Overrides the project-config directory.
#   --write                    (discover only) Save the discovered project
#                            config to $JIRA_PROJECTS_DIR/<PROJECT>.json
#                            (path-safety: <PROJECT> is shape-validated
#                            so the path stays pinned under the projects dir)
#                            instead of printing it to stdout. On a FRESH target
#                            it writes the config as-is; on an EXISTING target it
#                            BACKS UP the file first (to <path>.bak-<UTC>) then
#                            MERGES — refreshing the discovered facts
#                            (issue_types/subtask_types) and add/updating
#                            discovered custom_fields entries, while PRESERVING
#                            the human-curated type_aliases/subtask_parent_types/
#                            workflows and any human-added semantic custom_fields
#                            keys. Prints a machine line naming the outcome +
#                            backup: JIRA_DISCOVERED=<PROJECT> -> <path>
#                            (created|merged|replaced[; backup <path>]).
#   --force                    (discover only, with --write) Skip the merge and
#                            write the PURE discovered config (curated slots
#                            empty) — a deliberate full reset — but STILL back
#                            up an existing file first.
#   --to TARGET_KEY              (link only) The link's target ticket key.
#                            See "link direction" below for how the
#                            positional FROM and --to map onto Jira's
#                            inwardIssue/outwardIssue.
#   --link-type NAME              (link only) The issue-link type's NAME
#                            (e.g. "Blocks", "Relates", "Duplicate") — run
#                            `link-types` first to discover the valid names
#                            for your site.
#   --time-spent STR              (worklog only) REQUIRED. Jira duration
#                            format, e.g. "2h", "30m", "1d 4h".
#   --comment-file PATH          (link, worklog) Markdown -> ADF, attached
#                            as the link's or worklog entry's comment.
#                            Optional on both.
#   --started STR                (worklog only) ISO8601 with milliseconds +
#                            offset, e.g. "2026-07-24T10:00:00.000+0000".
#                            Optional — Jira defaults to now when omitted.
#   --account VALUE              (watch only) "me"/"@me" (the default when
#                            omitted) -> self; an email/username -> resolved
#                            to an accountId via the SAME resolver
#                            create/update already use for --assignee.
#   --remove                      (watch, vote) Remove instead of add;
#                            mutually exclusive with --list.
#   --list                          (watch, vote) List instead of add;
#                            mutually exclusive with --remove.
#   --json                     Print raw/structured JSON instead of the
#                            human-readable render (every command supports
#                            this EXCEPT discover, whose default output is
#                            ALREADY the config JSON — --json is a no-op there;
#                            see each command's own section for its exact
#                            --json shape).
#   -h, --help                  Show this help.
#
# link direction (read this before wiring anything that calls `link`):
#   `link FROM --to TO --link-type NAME` models "FROM <verb> TO" in ACTIVE
#   VOICE — e.g. `link PROJ-1 --to PROJ-2 --link-type Blocks` reads as
#   "PROJ-1 blocks PROJ-2". Jira's issueLinkType stores an INWARD phrase and
#   an OUTWARD phrase per type (e.g. type "Blocks": outward "blocks",
#   inward "is blocked by"), and the REST payload names the two ends
#   `outwardIssue`/`inwardIssue`, not "from"/"to". VERIFIED LIVE
#   (2026-07-25, PSWS-958/959): the issue placed in
#   inwardIssue is the one that exhibits the OUTWARD (active-voice) phrase —
#   so FROM (the active subject that "blocks") is sent as inwardIssue and TO
#   (which "is blocked by" FROM) as outwardIssue. cmd_link builds exactly
#   {type:{name:NAME}, inwardIssue:{key:FROM}, outwardIssue:{key:TO}}. This
#   is the REVERSE of the naive "outward phrase => outwardIssue" reading
#   (which shipped first and produced a backwards link — the live test
#   caught it). Use `link-types` to see a type's exact inward/outward wording.
#
# transition --plan (read this before wiring the P4 consent gate):
#   `transition <KEY> --status TARGET --plan` performs EXACTLY ONE network
#   call (fetch the issue's current status/type) and then computes the
#   BFS-shortest walk over the project config's workflow graph LOCALLY —
#   no transition/write endpoint is ever hit in --plan mode, verified by a
#   dedicated test asserting zero POSTs fire. `--plan --json` emits
#   {key, from, to, path, resolution, executed:false} — the SAME shape a
#   real walk's --json emits with executed:true — so the orchestrator can
#   run --plan first, show the human the exact path/resolution/injected
#   comment it discloses, and only THEN (on explicit consent) re-invoke
#   WITHOUT --plan to execute. Never assume the real walk will match the
#   plan byte-for-byte if the two invocations are far apart in time (Jira's
#   own workflow could have changed) — that risk is inherent to any
#   plan/execute split against a live remote system, not specific to this
#   script.
#
# discover (read this before wiring anything that consumes its output):
#   `discover <PROJECT>` INTROSPECTS a Jira project and EMITS the project-config
#   JSON this same engine already consumes (custom_fields/type_aliases/
#   issue_types/subtask_types/subtask_parent_types/workflows — the exact keys
#   read by try_load_project_config & friends). It is a READ command: it only
#   ever GETs, never writes to Jira. It walks the CURRENT split createmeta
#   endpoints (the old `GET /issue/createmeta?projectKeys=...&expand=...` is
#   removed in Jira Cloud): GET /issue/createmeta/<PROJECT>/issuetypes (the
#   project's issue types — paginated), then GET
#   /issue/createmeta/<PROJECT>/issuetypes/<id> per type (that type's
#   create-screen fields — paginated), then GET /field (the global field
#   catalog, a plain array — used to resolve each custom field's id to its
#   display NAME). custom_fields IS POPULATED (a name->id map, keyed by each
#   custom field's display name — the same key resolve_field_name looks up
#   from a --fields token), as are issue_types and subtask_types, all from live
#   data. The human-fill step for custom_fields is DISTINCT from the empty
#   slots: it means ADDING the SEMANTIC keys require_custom_field expects
#   (acceptance_criteria/review_notes/developer) as further ENTRIES into that
#   already-populated map — whereas type_aliases/subtask_parent_types/workflows
#   are emitted genuinely EMPTY because the API cannot infer a client's aliases
#   or workflow graph at all. Every discovered value (field names, ids, type
#   names) enters jq ONLY as data via --slurpfile — never concatenated into a
#   jq program — so an injection-shaped field name authored by another Jira
#   user (e.g. one containing `$()`/backticks/quotes) round-trips completely
#   inert into the config. discover's own output IS the config JSON, so --json
#   is a no-op for it (unlike every other command). Default: prints the config
#   to stdout. --write: saves/MERGES it under the projects dir (see --write
#   above — it preserves human curation and backs up before overwriting).
#
# Output:
#   READ commands (view, search, workflow, link-types, children): human mode
#   prints a rendered summary; --json prints the raw response JSON. WRITE
#   commands: human mode prints machine-parseable `JIRA_*=value` lines
#   (create: JIRA_ISSUE_KEY/JIRA_ISSUE_URL; comment: JIRA_COMMENT_ID;
#   transition: JIRA_TRANSITIONED_TO; update: JIRA_UPDATED; link:
#   JIRA_LINKED; worklog: JIRA_WORKLOGGED; watch: JIRA_WATCHED/
#   JIRA_UNWATCHED; vote: JIRA_VOTED/JIRA_UNVOTED) — watch/vote's --list mode
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
#   1  curl/jq absent · credentials unavailable · confirmed-site host not in
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
# file, this engine uses it AS-IS via `curl -K` and never asks how it got
# there — that is procedure-jira-auth's job (Phase 3), a seam that precedes
# its consumer. Until that skill exists, this engine falls back to
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
# sibling md-to-adf.sh). Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout stays machine-clean)
# ---------------------------------------------------------------------------
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage (READ):
  $PROG view <KEY> --confirmed-site SITE [--fields LIST] [--json]
         [--projects-dir DIR] [-h|--help]
  $PROG search --confirmed-site SITE
         [--project KEY] [--assignee VALUE] [--status STR] [--type STR]
         [--labels LIST] [--jql QUERY] [--fields LIST]
         [--limit N] [--page-size N] [--projects-dir DIR] [--json]
         [-h|--help]
  $PROG workflow <KEY> --confirmed-site SITE [--json] [-h|--help]
  $PROG link-types --confirmed-site SITE [--json] [-h|--help]
  $PROG children <KEY> --confirmed-site SITE [--fields LIST]
         [--limit N] [--page-size N] [--json]
  $PROG discover <PROJECT> --confirmed-site SITE [--write] [--force]
         [--projects-dir DIR] [-h|--help]

Usage (AGILE READ, base /rest/agile/1.0/):
  $PROG boards --confirmed-site SITE [--project KEY]
         [--type scrum|kanban|simple] [--limit N] [--json]
  $PROG board <BOARD_ID> --confirmed-site SITE [--json]
  $PROG sprints <BOARD_ID> --confirmed-site SITE
         [--state active|future|closed] [--limit N] [--json]
  $PROG sprint <SPRINT_ID> --confirmed-site SITE [--issues]
         [--limit N] [--json]
  $PROG backlog <BOARD_ID> --confirmed-site SITE [--limit N] [--json]
  $PROG epics <BOARD_ID> --confirmed-site SITE [--limit N] [--json]
  $PROG epic <EPIC_ID> --issues --confirmed-site SITE [--limit N] [--json]

Usage (WRITE):
  $PROG create --project KEY --title STR --confirmed-site SITE
         [--description-file PATH] [--acceptance-file PATH]
         [--review-file PATH] [--type STR] [--assignee VALUE]
         [--labels LIST] [--due-date YYYY-MM-DD] [--parent KEY]
         [--fix-version NAME]... [--affects-version NAME]...
         [--component NAME]... [--json]
  $PROG comment <KEY> --text-file PATH --confirmed-site SITE [--json]
  $PROG transition <KEY> --status TARGET --confirmed-site SITE
         [--resolution STR] [--plan|--dry-run] [--json]
  $PROG update <KEY> --confirmed-site SITE
         [--title STR] [--description-file PATH | --append-file PATH]
         [--acceptance-file PATH] [--review-file PATH]
         [--assignee VALUE] [--developer VALUE] [--labels LIST]
         [--due-date YYYY-MM-DD] [--parent KEY]
         [--fix-version NAME]... [--affects-version NAME]...
         [--component NAME]... [--json]
  $PROG link <FROM> --to TO --link-type NAME --confirmed-site SITE
         [--comment-file PATH] [--json]
  $PROG worklog <KEY> --time-spent STR --confirmed-site SITE
         [--comment-file PATH] [--started STR] [--json]
  $PROG watch <KEY> --confirmed-site SITE [--account VALUE] [--remove]
         [--list] [--json]
  $PROG vote <KEY> --confirmed-site SITE [--remove] [--list] [--json]
  $PROG version --confirmed-site SITE (--list --project KEY
         | --create --project KEY --name STR [--description STR]
             [--release-date YYYY-MM-DD] [--start-date YYYY-MM-DD] [--released]
         | --update --id N [--name STR] [--description STR]
             [--release-date YYYY-MM-DD] [--start-date YYYY-MM-DD]
         | --release --id N [--release-date YYYY-MM-DD]
         | --archive --id N) [--json]
  $PROG component --confirmed-site SITE (--list --project KEY
         | --create --project KEY --name STR [--description STR]
             [--lead-account-id STR]
         | --update --id N [--name STR] [--description STR] [--lead-account-id STR]
         | --delete --id N [--move-issues-to N2]) [--json]
  $PROG attach --confirmed-site SITE (<KEY> --file PATH [--file PATH]...
         | <KEY> --list
         | --delete --id N) [--json]
  $PROG bulk --op transition|comment|update --confirmed-site SITE
         (--keys "K-1,K-2,..." | --jql QUERY)
         [transition: --status TARGET [--resolution STR]]
         [comment: --text-file PATH]
         [update: --title/--labels/--assignee/--due-date/--parent/... ]
         [--plan|--dry-run] [--json]

Usage (AGILE WRITE — sprint lifecycle, base /rest/agile/1.0/):
  $PROG sprint --create --board BOARD_ID --name STR --confirmed-site SITE
         [--goal STR] [--start-date ISO] [--end-date ISO] [--json]
  $PROG sprint --update <SPRINT_ID> --confirmed-site SITE
         [--name STR] [--goal STR] [--start-date ISO] [--end-date ISO] [--json]
  $PROG sprint --start <SPRINT_ID> --start-date ISO --end-date ISO
         --confirmed-site SITE [--json]   (start REQUIRES both dates)
  $PROG sprint --close <SPRINT_ID> --confirmed-site SITE [--json]
  (ISO = ISO-8601 UTC, e.g. 2026-07-26T10:00:00.000Z)

--confirmed-site SITE is REQUIRED on every command (fails closed if absent
or if it mismatches the intended site — see the script header). See the
script header for the full flag reference and transition --plan's contract.

link direction: \`link FROM --to TO --link-type NAME\` reads "FROM <type>
TO" in active voice (FROM -> inwardIssue, TO -> outwardIssue; verified
live). Run link-types first to see a type's exact inward/outward wording.

Exit codes:
  0  success
  1  curl/jq absent / credentials unavailable / site gate failed / an API
     call failed / no user found for --assignee/--developer/--account /
     invalid project config / an unconfigured custom field required by
     --acceptance-file/--review-file/--developer / no valid transition path /
     a transition step that silently failed to apply
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
JIRA_HOST_ALLOWLIST_PATTERN=${JIRA_HOST_ALLOWLIST_PATTERN:-'*.atlassian.net'}
JIRA_PROJECTS_DIR_DEFAULT="$HOME/.claude/skills/procedure-jira/projects"
ESC=$(printf '\033')
NL='
'
# SCRIPT_DIR/MD_TO_ADF — the markdown->ADF converter is a SIBLING script in
# this same skill's scripts/ dir (Phase 1, reviewed separately), consumed
# BY PATH — never sourced, never inlined. Resolved relative to $0's own
# location (not a bare "scripts/md-to-adf.sh", which would resolve against
# the CALLER's cwd) — correct both when deployed under
# $HOME/.claude/skills/procedure-jira/scripts/ and under this repo's own
# tests/../scripts/ during test runs.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MD_TO_ADF="$SCRIPT_DIR/md-to-adf.sh"

# ---------------------------------------------------------------------------
# Global state (plain vars — this script is a single short-lived process,
# not a library, and POSIX sh has no `local`; every var below starts empty/0
# so cleanup() can safely check "was this actually created" on any exit path).
#
# CONVENTION for anyone adding a Phase-2b (write) command: every helper
# function's scratch/parameter variables (e.g. jira_curl's `method`/`url`/
# `data_file`, resolve_account_id's `value`/`account_id`) are plain globals
# scoped ONLY by a name that is unique to that function. Because POSIX sh has
# no `local`, a name reused across two functions that can appear in the same
# call chain (e.g. one helper calling another) will silently clobber the
# caller's copy. Keep every new function's scratch names unique across the
# whole script — do not reuse a name like `key`/`value`/`url` that another
# function already owns, even if the two never *currently* call each other.
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

# ---------------------------------------------------------------------------
# Site gate
# ---------------------------------------------------------------------------

# normalize_site VALUE -> a bare host: strips an optional "http(s)://"
# prefix and anything from the first "/" onward (a path/query, if given).
normalize_site() {
	raw=$1
	host=$(printf '%s' "$raw" | sed -E 's#^[Hh][Tt][Tt][Pp][Ss]?://##')
	host=${host%%/*}
	printf '%s' "$host"
}

# assert_host_allowed HOST -> 0 if HOST matches the allow-list shape and
# contains only host-safe characters, 1 otherwise. The pattern is matched as
# a shell glob (not a literal string) — that IS the allow-list mechanism.
assert_host_allowed() {
	h=$1
	case "$h" in
		*[!A-Za-z0-9.-]*) return 1 ;;
	esac
	# shellcheck disable=SC2254  # deliberate glob match against the configured allow-list pattern, not a literal
	case "$h" in
		$JIRA_HOST_ALLOWLIST_PATTERN) return 0 ;;
		*) return 1 ;;
	esac
}

# assert_confirmed_site_given — the presence half of the site gate.
# A plain usage error (exit 2), so it is checked early, alongside the other
# per-command required-argument validation — before any tool/network check.
assert_confirmed_site_given() {
	[ -n "$OPT_CONFIRMED_SITE" ] || {
		usage >&2
		error "--confirmed-site is required on every command"
		exit 2
	}
}

# require_confirmed_site — the security half of the site gate: assumes
# assert_confirmed_site_given() already ran. Fails closed (exit 1) if the
# host is outside the allow-list, and fails closed (exit 1) if an intended
# site (JIRA_SITE, from the Phase-2 fallback credential path) disagrees with
# it. Sets $CONFIRMED_HOST.
require_confirmed_site() {
	CONFIRMED_HOST=$(normalize_site "$OPT_CONFIRMED_SITE")
	[ -n "$CONFIRMED_HOST" ] || { error "--confirmed-site is empty after normalization"; exit 2; }

	if ! assert_host_allowed "$CONFIRMED_HOST"; then
		error "confirmed site host is not in the allow-list ($JIRA_HOST_ALLOWLIST_PATTERN): $CONFIRMED_HOST"
		exit 1
	fi

	if [ -n "${JIRA_SITE:-}" ]; then
		intended_host=$(normalize_site "$JIRA_SITE")
		if [ "$intended_host" != "$CONFIRMED_HOST" ]; then
			error "site mismatch: intended site '$intended_host' (from \$JIRA_SITE) != confirmed site '$CONFIRMED_HOST' — refusing to proceed"
			exit 1
		fi
	fi
}

# ---------------------------------------------------------------------------
# Credential handoff
# ---------------------------------------------------------------------------

# curl_config_escape VALUE -> VALUE with backslash escaped FIRST, then the
# double quote — curl's -K config file quoted-string escaping. Order matters
# (same rule as JQL below): escaping the quote first would double-escape a
# backslash that precedes a real quote.
curl_config_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# resolve_credential_config — sets $CURL_CONFIG_FILE to a curl -K config
# file. Prefers the Phase-3 contract ($JIRA_CURL_CONFIG, produced elsewhere
# and never deleted by this script — it treats an externally-supplied file as
# "not its own"); falls back to building
# its OWN 600 mktemp file from $JIRA_EMAIL/$JIRA_TOKEN (the Phase-2
# stand-in). Fails closed (exit 1) if neither is available.
resolve_credential_config() {
	if [ -n "${JIRA_CURL_CONFIG:-}" ]; then
		if [ ! -f "$JIRA_CURL_CONFIG" ] || [ ! -r "$JIRA_CURL_CONFIG" ]; then
			error "\$JIRA_CURL_CONFIG points to a missing/unreadable file: $JIRA_CURL_CONFIG"
			exit 1
		fi
		CURL_CONFIG_FILE=$JIRA_CURL_CONFIG
		CURL_CONFIG_IS_OWN=0
		return 0
	fi

	if [ -z "${JIRA_EMAIL:-}" ] || [ -z "${JIRA_TOKEN:-}" ]; then
		error "no credentials available: set \$JIRA_CURL_CONFIG (preferred, from procedure-jira-auth) or both \$JIRA_EMAIL and \$JIRA_TOKEN"
		exit 1
	fi

	case "$JIRA_EMAIL" in *"$NL"*) error "\$JIRA_EMAIL must not contain a newline"; exit 1 ;; esac
	case "$JIRA_TOKEN" in *"$NL"*) error "\$JIRA_TOKEN must not contain a newline"; exit 1 ;; esac

	esc_email=$(curl_config_escape "$JIRA_EMAIL")
	esc_token=$(curl_config_escape "$JIRA_TOKEN")

	old_umask=$(umask)
	umask 077
	CURL_CONFIG_FILE=$(mktemp "${TMPDIR:-/tmp}/jira.curlconfig.XXXXXX")
	umask "$old_umask"
	chmod 600 "$CURL_CONFIG_FILE"
	printf 'user = "%s:%s"\n' "$esc_email" "$esc_token" >"$CURL_CONFIG_FILE"
	CURL_CONFIG_IS_OWN=1
}

# ---------------------------------------------------------------------------
# The secure curl helper (takes a full URL + method, does not
# assume a JSON body, so a later multipart/attachments caller is a new
# argument, not a transport reshape)
# ---------------------------------------------------------------------------

ensure_workdir() {
	if [ -z "$WORKDIR" ]; then
		WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/jira.work.XXXXXX")
	fi
}

# jira_curl METHOD URL [DATA_FILE] [CONTENT_TYPE]
# Sets $JIRA_HTTP_BODY_FILE (the response body, always a FRESH file — never
# reused across calls, so a caller holding an earlier response's path stays
# valid after a later call) and $JIRA_HTTP_CODE (the numeric HTTP status).
jira_curl() {
	method=$1
	url=$2
	data_file=${3:-}
	content_type=${4:-application/json}

	req_host=$(printf '%s' "$url" | sed -E 's#^https://##; s#/.*##')
	if [ "$req_host" != "$CONFIRMED_HOST" ]; then
		error "internal: refusing to send a request to '$req_host' — it does not match the confirmed site '$CONFIRMED_HOST' (fail closed)"
		exit 1
	fi
	case "$url" in
		https://*) : ;;
		*) error "internal: refusing a non-https URL: $url"; exit 1 ;;
	esac

	ensure_workdir
	RESP_COUNTER=$((RESP_COUNTER + 1))
	JIRA_HTTP_BODY_FILE="$WORKDIR/resp-$RESP_COUNTER.json"

	set -- curl -sS --proto '=https' -K "$CURL_CONFIG_FILE" \
		-H 'Accept: application/json' \
		-X "$method" \
		-o "$JIRA_HTTP_BODY_FILE" \
		-w '%{http_code}'

	if [ -n "$data_file" ]; then
		set -- "$@" -H "Content-Type: $content_type" --data "@$data_file"
	fi

	set -- "$@" "$url"

	if ! JIRA_HTTP_CODE=$("$@"); then
		error "curl request failed (network/TLS error) for $method $url"
		exit 1
	fi
}

# jira_curl_multipart METHOD URL FILES_NL — the multipart/form-data sibling
# of jira_curl(), for attachment upload. Sends one `-F file=@PATH` part per
# newline-terminated path in FILES_NL, with NO JSON content-type (curl builds
# the multipart body + its own boundary). Preserves EVERY security property of
# jira_curl: the auth token stays in the `-K` config file (NEVER on argv, so
# it can't leak via `ps`), the host is pinned to $CONFIRMED_HOST (fail closed),
# `--proto '=https'` forbids a plaintext downgrade, and no redirect is followed.
# Sets $JIRA_HTTP_BODY_FILE + $JIRA_HTTP_CODE identically to jira_curl, so
# handle_http_status / require_json_body work against it unchanged. Adds Jira's
# `X-Atlassian-Token: no-check` XSRF opt-out (required by the attachments API).
jira_curl_multipart() {
	mp_method=$1
	mp_url=$2
	mp_files=$3

	mp_req_host=$(printf '%s' "$mp_url" | sed -E 's#^https://##; s#/.*##')
	if [ "$mp_req_host" != "$CONFIRMED_HOST" ]; then
		error "internal: refusing to send a request to '$mp_req_host' — it does not match the confirmed site '$CONFIRMED_HOST' (fail closed)"
		exit 1
	fi
	case "$mp_url" in
		https://*) : ;;
		*) error "internal: refusing a non-https URL: $mp_url"; exit 1 ;;
	esac

	ensure_workdir
	RESP_COUNTER=$((RESP_COUNTER + 1))
	JIRA_HTTP_BODY_FILE="$WORKDIR/resp-$RESP_COUNTER.json"

	set -- curl -sS --proto '=https' -K "$CURL_CONFIG_FILE" \
		-H 'Accept: application/json' \
		-H 'X-Atlassian-Token: no-check' \
		-X "$mp_method" \
		-o "$JIRA_HTTP_BODY_FILE" \
		-w '%{http_code}'

	# Append one `-F file=@PATH` part per path. POSIX sh has no arrays, so the
	# paths arrive as one NL-terminated line each; a here-doc while-read runs in
	# THIS shell (no subshell, so the `set --` accumulation survives) and never
	# word-splits/globs the path (unlike `for p in $mp_files`).
	#
	# SECURITY — the path is ESCAPED, then wrapped in DOUBLE QUOTES inside the
	# -F value (file=@"PATH"): curl parses an unquoted `-F` @-path's `;` and `,`
	# as parameter separators (`;type=`, `;filename=`, and `,` starting the next
	# part), so a crafted path like `/tmp/a;type=text/html` could otherwise
	# inject a form parameter / override the declared mime. Double-quoting the
	# @-path makes curl treat those bytes literally as the filename — BUT a `"`
	# or `\` embedded in the path is itself special INSIDE curl's quoted value:
	# `/tmp/a";type=text/html` would break out of the quotes and inject a mime
	# override, and `/tmp/a",/etc/passwd` a second `@`-file part. So we escape
	# backslash FIRST, then the double quote (same order + helper shape as
	# curl_config_escape), before wrapping — closing the breakout.
	while IFS= read -r mp_path; do
		[ -n "$mp_path" ] || continue
		mp_esc=$(printf '%s' "$mp_path" | sed 's/\\/\\\\/g; s/"/\\"/g')
		set -- "$@" -F "file=@\"$mp_esc\""
	done <<-MULTIPART_FILES_EOF
	$mp_files
	MULTIPART_FILES_EOF

	set -- "$@" "$mp_url"

	if ! JIRA_HTTP_CODE=$("$@"); then
		error "curl request failed (network/TLS error) for $mp_method $mp_url"
		exit 1
	fi
}

# handle_http_status CODE ACTION_DESC — exits 1 with Jira's own error
# message (if any, stripped of control/ANSI) on a non-2xx response.
handle_http_status() {
	code=$1
	action=$2
	case "$code" in
		2??) return 0 ;;
	esac
	error "$action failed (HTTP $code)"
	if [ -s "$JIRA_HTTP_BODY_FILE" ]; then
		jq -r '(.errorMessages // [])[], (.errors // {} | to_entries[] | "\(.key): \(.value)")' \
			"$JIRA_HTTP_BODY_FILE" 2>/dev/null | strip_control_ansi >&2 || true
	fi
	exit 1
}

# require_json_body ACTION_DESC — call right after a 2xx handle_http_status
# passes, for any endpoint whose success response this script expects to be
# JSON (every call site in this phase). Without this, a 2xx response with a
# malformed body (e.g. an intermediary proxy's HTML error page) would reach
# an unguarded jq call further downstream and abort with JQ'S OWN exit code
# (2) under `set -e` — colliding with this script's documented "2 = usage
# error" contract for a failure that has nothing to do with usage. Reported
# the same way as any other API failure: exit 1.
require_json_body() {
	action=$1
	if ! jq -e . "$JIRA_HTTP_BODY_FILE" >/dev/null 2>&1; then
		error "$action failed: response body was not valid JSON"
		exit 1
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

# validate_ticket_key KEY -> 0 if KEY looks like PROJECT-123 (a fixed shape,
# checked BEFORE the value is interpolated into any REST URL path segment).
# Hardening: pure `case`/parameter-expansion string matching, NOT
# `grep -Eq '^...$'` piped through printf — grep's `^`/`$` are LINE anchors,
# so a value with an EMBEDDED newline (e.g. "PROJ-1\nfoo") would let grep
# match just the first line and report success even though the whole value
# is malformed. `case` matches the ENTIRE parameter as one opaque string —
# an embedded newline included — so this closes that bypass while accepting
# exactly the same shape as before (rejecting anything outside A-Z/0-9/"-"
# up front makes the later shape check's `?`/`*` wildcards safe to use).
validate_ticket_key() {
	ticket_key_candidate=$1
	case "$ticket_key_candidate" in
		''|*[!A-Z0-9-]*) return 1 ;;
	esac
	ticket_key_prefix=${ticket_key_candidate%%-*}
	ticket_key_suffix=${ticket_key_candidate#*-}
	case "$ticket_key_prefix" in
		[A-Z]?*) : ;;
		*) return 1 ;;
	esac
	case "$ticket_key_suffix" in
		''|*[!0-9]*) return 1 ;;
	esac
}

# validate_project_key KEY -> 0 if KEY looks like a bare project key (e.g.
# "PROJ" — no "-NNN" suffix, unlike a ticket key). Checked BEFORE the value
# is used to build a project-config file PATH (try_load_project_config's
# "$JIRA_PROJECTS_DIR/${key}.json") — an unvalidated "../../etc/passwd"
# -shaped --project would otherwise let the config loader read an arbitrary
# readable *.json outside the projects directory. Uses `case` (not
# `grep -Eq '^...$'`) so an EMBEDDED newline can't slip past a line-anchored
# match: grep's `^`/`$` anchor per line, so a multi-line value could match on
# its first line while the whole string is malformed; `case` matches the
# entire value as one opaque string. Accepted grammar is unchanged: first
# char A-Z, rest A-Z/0-9, length >= 2.
validate_project_key() {
	case "$1" in
		''|*[!A-Z0-9]*) return 1 ;;
	esac
	case "$1" in
		[A-Z]?*) return 0 ;;
		*) return 1 ;;
	esac
}

# extract_project_from_key KEY -> the leading project-key part of KEY (e.g.
# "ONW-123" -> "ONW"). Caller is expected to have already validated KEY.
extract_project_from_key() {
	printf '%s' "$1" | sed -E 's/^([A-Z][A-Z0-9]+)-[0-9]+$/\1/'
}

# validate_numeric_id VALUE -> 0 if VALUE is a non-empty run of ASCII digits
# with NO leading zero (Jira's version/component/board/sprint ids — `^[1-9][0-9]*$`,
# plus the bare "0"). Checked BEFORE the value becomes a REST URL path segment
# (/version/<id>, /component/<id>) or a query value (?moveIssuesTo=<id>), the SAME
# rule ticket/project keys follow. Uses `case` (not `grep -Eq '^...$'`) so an
# EMBEDDED newline can't slip past a line-anchored match — identical reasoning to
# validate_ticket_key.
#
# The leading-zero rejection is not cosmetic: a numeric id validated here can
# flow to merge_int_field, which feeds it to `jq --argjson`. JSON forbids a
# leading-zero integer literal, so an id like "0826" makes jq ABORT mid-body
# with a raw parse error (colliding with the documented exit-code contract) long
# after this clean usage gate could have rejected it. Real Jira ids never carry
# a leading zero, so refusing one here is a clean usage error (exit 2 at the
# caller), not a lost capability.
validate_numeric_id() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
	esac
	# Reject a leading zero on a multi-digit id ("0", a single zero, still passes).
	case "$1" in
		0?*) return 1 ;;
	esac
}

# validate_iso_datetime VALUE -> 0 if VALUE is an ISO-8601 UTC/offset datetime
# of the shape Jira's Agile sprint API returns and accepts:
#   YYYY-MM-DDTHH:MM:SS[.sss]<Z | +HH:MM | -HH:MM>
# (e.g. 2026-07-26T10:00:00.000Z). This is an ALLOW-SHAPE check run BEFORE the
# value is placed into a request body — it validates the FORMAT only (not that
# the calendar date is real); the server is the authority on semantic validity,
# and surfaces its own error via handle_http_status. A zone is REQUIRED (the
# sprint window is an absolute instant, never a floating local time).
#
# Uses `case`/parameter-expansion string matching (NOT `grep -Eq '^...$'`) for
# the SAME reason validate_ticket_key/validate_numeric_id do: grep's `^`/`$`
# anchor per LINE, so a value with an embedded newline could match on its first
# line while the whole string is malformed; `case` matches the entire value as
# one opaque string. The leading alphabet guard also rejects any byte outside
# the ISO-8601 datetime set up front, so the wildcard tail below cannot smuggle
# an unexpected character (an embedded newline included).
validate_iso_datetime() {
	vid_value=$1
	case "$vid_value" in
		''|*[!0-9T:.+Z-]*) return 1 ;;
	esac
	# Fixed prefix: YYYY-MM-DDTHH:MM:SS (19 chars).
	case "$vid_value" in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) : ;;
		*) return 1 ;;
	esac
	# Strip the exact matched prefix, leaving only the fraction + zone tail.
	vid_tail=${vid_value#[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]}
	# Split off the REQUIRED zone (Z or ±HH:MM), leaving the OPTIONAL fraction.
	case "$vid_tail" in
		*Z)                          vid_frac=${vid_tail%Z} ;;
		*[+-][0-9][0-9]:[0-9][0-9])  vid_frac=${vid_tail%[+-][0-9][0-9]:[0-9][0-9]} ;;
		*) return 1 ;;
	esac
	# The fraction is either absent, or a dot followed by one-or-more digits.
	case "$vid_frac" in
		'') return 0 ;;
		.*)
			vid_digits=${vid_frac#.}
			case "$vid_digits" in
				''|*[!0-9]*) return 1 ;;
			esac
			;;
		*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# Project config loader (mirrors the jira.py oracle's ProjectConfig). The
# SCHEMA is generic; config INSTANCES (one JSON file per project key) live
# under $JIRA_PROJECTS_DIR, which defaults to a conventional path but is
# fully overridable (env or --projects-dir) since real instances belong to
# the private client layer, never this generic skill.
# ---------------------------------------------------------------------------

# try_load_project_config KEY — sets $PROJECT_CONFIG_FILE if
# $JIRA_PROJECTS_DIR/KEY.json exists and is valid JSON. Absence is NOT an
# error (most projects have no config; callers fall back to literal values).
# Malformed JSON in an EXISTING file IS an error — a broken config should
# never be silently ignored. KEY is shape-validated FIRST — this
# is the one place a project key becomes a file path, so the guard lives
# here rather than duplicated at every caller (--project on create/search,
# and the ticket-key-derived project on view/workflow/transition/update,
# which is already shape-guaranteed by validate_ticket_key upstream but
# costs nothing to re-check at the actual sink).
try_load_project_config() {
	key=$1
	[ -n "$key" ] || return 0
	if ! validate_project_key "$key"; then
		error "invalid project key: $key"
		exit 1
	fi
	candidate="$JIRA_PROJECTS_DIR/${key}.json"
	[ -f "$candidate" ] && [ -r "$candidate" ] || return 0
	if ! jq -e . "$candidate" >/dev/null 2>&1; then
		error "project config is not valid JSON: $candidate"
		exit 1
	fi
	PROJECT_CONFIG_FILE=$candidate
}

# resolve_type_alias CONFIG_FILE VALUE -> config's type_aliases[VALUE], or
# VALUE unchanged if there is no such alias / no config was loaded.
resolve_type_alias() {
	config_file=$1
	value=$2
	[ -n "$config_file" ] || { printf '%s' "$value"; return 0; }
	jq -r --arg v "$value" '.type_aliases[$v] // $v' "$config_file"
}

# resolve_field_name CONFIG_FILE NAME -> config's custom_fields[NAME] (a
# semantic name like "acceptance_criteria" -> "customfield_16102"), or NAME
# unchanged when there's no such mapping / no config.
resolve_field_name() {
	config_file=$1
	name=$2
	[ -n "$config_file" ] || { printf '%s' "$name"; return 0; }
	jq -r --arg n "$name" '.custom_fields[$n] // $n' "$config_file"
}

# resolve_fields_csv CONFIG_FILE CSV -> CSV with each token passed through
# resolve_field_name (empty CONFIG_FILE = passthrough unchanged).
resolve_fields_csv() {
	config_file=$1
	csv=$2
	[ -n "$config_file" ] || { printf '%s' "$csv"; return 0; }
	old_ifs=$IFS
	IFS=','
	set -f
	# shellcheck disable=SC2086  # deliberate comma-split; -f (above) blocks globbing
	set -- $csv
	set +f
	IFS=$old_ifs
	out=""
	for tok in "$@"; do
		trimmed=$(printf '%s' "$tok" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		[ -n "$trimmed" ] || continue
		resolved=$(resolve_field_name "$config_file" "$trimmed")
		if [ -z "$out" ]; then out=$resolved; else out="$out,$resolved"; fi
	done
	printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# accountId resolver
# ---------------------------------------------------------------------------

# resolve_account_id VALUE -> prints the resolved accountId. VALUE "@me"
# (the oracle's own convention for a direct field value, distinct from the
# JQL-only "me" shortcut below) resolves via GET /myself; anything else
# resolves via GET /user/search?query=VALUE. Exits 1 if no user is found.
resolve_account_id() {
	value=$1
	if [ "$value" = "@me" ]; then
		url="https://${CONFIRMED_HOST}/rest/api/3/myself"
		jira_curl GET "$url"
		handle_http_status "$JIRA_HTTP_CODE" "resolve @me via /myself"
		require_json_body "resolve @me via /myself"
		account_id=$(jq -r '.accountId // empty' "$JIRA_HTTP_BODY_FILE")
		[ -n "$account_id" ] || { error "GET /myself returned no accountId"; exit 1; }
		printf '%s' "$account_id"
		return 0
	fi

	encoded=$(urlencode "$value")
	url="https://${CONFIRMED_HOST}/rest/api/3/user/search?query=${encoded}"
	jira_curl GET "$url"
	handle_http_status "$JIRA_HTTP_CODE" "resolve accountId for '$value' via /user/search"
	require_json_body "resolve accountId for '$value' via /user/search"
	account_id=$(jq -r '.[0].accountId // empty' "$JIRA_HTTP_BODY_FILE")
	[ -n "$account_id" ] || { error "no Jira user found for '$value'"; exit 1; }
	printf '%s' "$account_id"
}

# ---------------------------------------------------------------------------
# The JQL builder (see the header's Security note)
# ---------------------------------------------------------------------------

# jql_escape_value VALUE -> VALUE with backslash escaped FIRST, then the
# double quote (Atlassian's documented JQL string-literal escape order).
jql_escape_value() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# jql_quoted VALUE -> a properly escaped, double-quoted JQL string literal.
# This — NOT `jq --arg` — is the actual control on the JQL sink (see header).
jql_quoted() {
	esc=$(jql_escape_value "$1")
	printf '"%s"' "$esc"
}

JQL_CLAUSES=""

# add_jql_clause CLAUSE — appends CLAUSE to the module-global $JQL_CLAUSES,
# AND-joined. Only ever called with a clause this script itself constructed
# from the fixed field/operator allow-list below — never with a raw user string.
add_jql_clause() {
	if [ -z "$JQL_CLAUSES" ]; then JQL_CLAUSES=$1
	else JQL_CLAUSES="$JQL_CLAUSES AND $1"
	fi
}

# build_jql — reads the search command's OPT_* globals, returns the final
# JQL string on stdout. Field names/operators below are a FIXED, hardcoded
# allow-list; the only thing that varies with user input is the escaped,
# quoted VALUE on the right-hand side of each "=".
build_jql() {
	if [ -n "$OPT_JQL" ]; then
		# Raw passthrough — see the header's Security note: this is the
		# caller querying their OWN instance with their OWN token, not
		# something this builder's escaping applies to.
		printf '%s' "$OPT_JQL"
		return 0
	fi

	JQL_CLAUSES=""

	if [ -n "$OPT_PROJECT" ]; then
		add_jql_clause "project = $(jql_quoted "$OPT_PROJECT")"
	fi

	if [ -n "$OPT_ASSIGNEE" ]; then
		case "$OPT_ASSIGNEE" in
			[Mm][Ee])
				add_jql_clause "assignee = currentUser()"
				;;
			*)
				resolved_account_id=$(resolve_account_id "$OPT_ASSIGNEE")
				add_jql_clause "assignee = $(jql_quoted "$resolved_account_id")"
				;;
		esac
	fi

	if [ -n "$OPT_STATUS" ]; then
		add_jql_clause "status = $(jql_quoted "$OPT_STATUS")"
	fi

	if [ -n "$OPT_TYPE" ]; then
		resolved_type=$(resolve_type_alias "$PROJECT_CONFIG_FILE" "$OPT_TYPE")
		add_jql_clause "type = $(jql_quoted "$resolved_type")"
	fi

	if [ -n "$OPT_LABELS" ]; then
		label_clauses=""
		old_ifs=$IFS
		IFS=','
		set -f
		# shellcheck disable=SC2086  # deliberate comma-split; -f (above) blocks globbing
		set -- $OPT_LABELS
		set +f
		IFS=$old_ifs
		for lbl in "$@"; do
			trimmed=$(printf '%s' "$lbl" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
			[ -n "$trimmed" ] || continue
			one="labels = $(jql_quoted "$trimmed")"
			if [ -z "$label_clauses" ]; then label_clauses=$one
			else label_clauses="$label_clauses OR $one"
			fi
		done
		[ -z "$label_clauses" ] || add_jql_clause "($label_clauses)"
	fi

	[ -n "$JQL_CLAUSES" ] || {
		usage >&2
		error "search requires at least one filter: --project/--assignee/--status/--type/--labels/--jql"
		exit 2
	}
	printf '%s' "$JQL_CLAUSES"
}

# ---------------------------------------------------------------------------
# Write-command shared helpers (Phase 2b: create/comment/transition/update)
#
# Every field value below reaches `curl` only inside a FILE built by a
# static, hardcoded jq program fed via --arg/--argjson/--slurpfile — the
# same discipline as the JQL builder and build_search_request_body() above,
# just applied to REST `fields{}` envelopes instead of JQL/search bodies.
# Nothing here ever string-concatenates a value into a jq PROGRAM, and
# nothing here ever passes a value to `curl` as a bare argv string — nested
# object shapes accumulate into a WORKDIR file via merge_*_field(), the same
# "the accumulator IS the file" pattern md-to-adf.sh uses for ADF nodes.
# ---------------------------------------------------------------------------

# require_readable_file PATH FLAG_NAME — a usage-error guard (exit 2) shared
# by every --*-file flag across create/comment/update.
require_readable_file() {
	file_path=$1
	flag_name=$2
	if [ ! -f "$file_path" ] || [ ! -r "$file_path" ]; then
		usage >&2
		error "$flag_name does not exist or is not readable: $file_path"
		exit 2
	fi
}

# require_converter — fails closed (exit 1) if md-to-adf.sh isn't sitting
# next to this script where it's expected (see SCRIPT_DIR/MD_TO_ADF above).
require_converter() {
	if [ ! -f "$MD_TO_ADF" ] || [ ! -r "$MD_TO_ADF" ]; then
		error "internal: md-to-adf.sh not found next to jira.sh: $MD_TO_ADF"
		exit 1
	fi
}

# convert_markdown_file_to_adf MARKDOWN_FILE -> prints the path to a NEW ADF
# JSON file under WORKDIR. The markdown content NEVER touches a shell
# variable or a jq program string here — it flows MARKDOWN_FILE -> (consumed
# by md-to-adf.sh via its own --file flag) -> ADF JSON written straight to a
# file, satisfying "stays inert" even for a description/summary containing
# `$()`/backticks/quotes: none of those bytes are ever interpreted, only
# ever read as file content or passed as --data @file to curl.
# An optional SECOND argument is a media-map file (localPath -> mediaUUID,
# built by resolve_inline_images below): when non-empty it is passed to the
# converter as --media-map, so own-line local `![alt](PATH)` images become ADF
# mediaSingle blocks. Existing single-argument callers are unaffected (no map).
convert_markdown_file_to_adf() {
	source_markdown_file=$1
	source_media_map=${2:-}
	require_converter
	ensure_workdir
	ADF_COUNTER=$((ADF_COUNTER + 1))
	adf_out_file="$WORKDIR/adf-$ADF_COUNTER.json"
	adf_err_file="$WORKDIR/adf-$ADF_COUNTER.err"
	if [ -n "$source_media_map" ]; then
		set -- --file "$source_markdown_file" --media-map "$source_media_map"
	else
		set -- --file "$source_markdown_file"
	fi
	if ! sh "$MD_TO_ADF" "$@" >"$adf_out_file" 2>"$adf_err_file"; then
		error "markdown-to-ADF conversion failed for: $source_markdown_file"
		sed 's/^/  /' "$adf_err_file" >&2 2>/dev/null || true
		exit 1
	fi
	printf '%s' "$adf_out_file"
}

# ---------------------------------------------------------------------------
# Inline images (Cycle B): local `![alt](PATH)` own-line images embedded in a
# description/comment body. The mechanism (probed live) is: upload the local
# file as an attachment (Cycle A), resolve its media UUID from the 303 the
# attachment/content endpoint returns, then reference that UUID from a
# mediaSingle ADF block (md-to-adf.sh emits the block from a media map this
# layer builds). This layer does the network; md-to-adf.sh does the transform.
# ---------------------------------------------------------------------------

# trim_ws VALUE -> VALUE with leading/trailing ASCII whitespace removed. Used
# by scan_inline_image_paths to classify a line the SAME way md-to-adf.sh's
# block parser does (it trims before matching), so the two agree on exactly
# which lines are own-line images.
trim_ws() {
	printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# validate_media_uuid VALUE -> 0 iff VALUE is exactly 36 chars of [a-f0-9-]
# (a v4 media UUID). The UUID is about to become an ADF attribute value and a
# map key's value, so it is validated at the boundary (standard-security):
# anything else is rejected before it can travel further.
validate_media_uuid() {
	case "$1" in
		''|*[!a-f0-9-]*) return 1 ;;
	esac
	[ "${#1}" -eq 36 ]
}

# resolve_media_uuid ATTACHMENT_ID -> prints ONLY the 36-char media UUID for
# the attachment. GETs /attachment/content/<id>, which returns a 303 whose
# Location is https://api.media.atlassian.com/file/<UUID>/binary?token=<JWT>.
#
# SECURITY (the whole point of this helper): the Location carries a short-lived
# JWT and MUST NEVER leave this function. So the request:
#   * does NOT follow the redirect (NO -L) — never hits api.media.atlassian.com,
#     never downloads the binary, never puts the token-bearing URL on the wire;
#   * dumps headers to a WORKDIR file (-D, trap-cleaned) with the body -> /dev/null;
#   * extracts ONLY the UUID via a `sed -n s///p` capture — on a match it prints
#     the captured group and NOTHING else, so the Location/JWT is never emitted;
#     on no match it prints nothing (the header line never reaches stdout/stderr).
# The token stays off argv (in the -K config file), the host is pinned (the URL
# is built from CONFIRMED_HOST), and the transport is https-only.
resolve_media_uuid() {
	rmu_attachment_id=$1
	validate_numeric_id "$rmu_attachment_id" || {
		error "internal: resolve_media_uuid received a non-numeric attachment id"
		exit 1
	}
	ensure_workdir
	RESP_COUNTER=$((RESP_COUNTER + 1))
	rmu_header_file="$WORKDIR/media-headers-$RESP_COUNTER.txt"
	rmu_url="https://${CONFIRMED_HOST}/rest/api/3/attachment/content/${rmu_attachment_id}"

	# Host-pin re-check — the SAME fail-closed invariant jira_curl/
	# jira_curl_multipart apply before every send: this is the one egress that
	# uses a raw `curl` (to hold the redirect), so it re-verifies the URL's host
	# against $CONFIRMED_HOST here rather than inheriting the sibling helpers'
	# check. Safe today (rmu_url is CONFIRMED_HOST-built), an assertion against
	# a future bug in a security-critical sink (standard-security "fail secure").
	rmu_req_host=$(printf '%s' "$rmu_url" | sed -E 's#^https://##; s#/.*##')
	if [ "$rmu_req_host" != "$CONFIRMED_HOST" ]; then
		error "internal: refusing to send a request to '$rmu_req_host' — it does not match the confirmed site '$CONFIRMED_HOST' (fail closed)"
		exit 1
	fi

	if ! rmu_code=$(curl -sS --proto '=https' -K "$CURL_CONFIG_FILE" \
		-H 'Accept: application/json' \
		-X GET \
		-D "$rmu_header_file" \
		-o /dev/null \
		-w '%{http_code}' \
		"$rmu_url"); then
		error "resolve media uuid: curl request failed (network/TLS error) for attachment $rmu_attachment_id"
		exit 1
	fi

	case "$rmu_code" in
		3??) : ;;
		*)
			error "resolve media uuid for attachment $rmu_attachment_id: expected a 3xx redirect, got HTTP $rmu_code"
			exit 1 ;;
	esac

	# Case-insensitive header name (HTTP/2 lowercases). The sed capture emits
	# ONLY the UUID — never the surrounding token-bearing URL.
	rmu_uuid=$(grep -i '^location:' "$rmu_header_file" 2>/dev/null \
		| sed -n 's#.*/file/\([a-f0-9-]\{36\}\)/binary.*#\1#p' \
		| sed -n '1p')
	if ! validate_media_uuid "$rmu_uuid"; then
		# Deliberately does NOT echo the header/Location (short-lived JWT).
		error "resolve media uuid for attachment $rmu_attachment_id: no media UUID found in the redirect Location"
		exit 1
	fi
	printf '%s' "$rmu_uuid"
}

# scan_inline_image_paths MARKDOWN_FILE -> prints one own-line LOCAL image PATH
# per line (in document order; duplicates allowed — the caller dedups against
# the map). Matches md-to-adf.sh's block parser: a line that trims to SOLELY
# `![alt](PATH)` with a non-http(s) PATH. Lines inside a ``` fence are skipped
# (fence content is literal in md-to-adf.sh, so it is not a media line here).
scan_inline_image_paths() {
	sip_markdown_file=$1
	sip_fence=0
	while IFS= read -r sip_line || [ -n "$sip_line" ]; do
		sip_trimmed=$(trim_ws "$sip_line")
		# Fence FSM — mirror md-to-adf.sh's block parser EXACTLY (asymmetric,
		# never a blind toggle): while a fence is OPEN every line is literal
		# fence body and is skipped, and ONLY a line that trims to exactly
		# ``` closes it (a body line like ```foo is content, not a close);
		# while CLOSED, a line starting with ``` opens one. A blind toggle
		# would desync from md-to-adf and could treat an `![](local)` shown
		# as example code inside a fence as a real image to upload.
		if [ "$sip_fence" = "1" ]; then
			if [ "$sip_trimmed" = '```' ]; then sip_fence=0; fi
			continue
		fi
		case "$sip_trimmed" in
			'```'*) sip_fence=1; continue ;;
		esac
		case "$sip_trimmed" in
			'!['*']('*')')
				# Same glob + extraction md-to-adf.sh's image branch uses
				# (#'![', #*'](', %')'), then accept ONLY a line that is
				# EXACTLY one image and nothing else — md-to-adf turns solely
				# such a line into a mediaSingle. `%')'` strips just the FINAL
				# paren, so a SECOND image leaves an interior `](` and any
				# trailing text after the image's real close leaves an interior
				# `)`; either telltale means NOT-solely, so skip it (it degrades
				# to paragraph text downstream, exactly as md-to-adf renders it)
				# instead of extracting a garbled non-path that would then abort
				# the whole command at require_readable_file.
				sip_rest=${sip_trimmed#'!['}
				sip_after_alt=${sip_rest#*']('}
				sip_path=${sip_after_alt%')'}
				case "$sip_path" in
					*']('*|*')'*) continue ;;
				esac
				case "$sip_path" in
					http://*|https://*|'') : ;;
					*) printf '%s\n' "$sip_path" ;;
				esac
				;;
		esac
	done <"$sip_markdown_file"
}

# merge_media_map MAP_FILE PATH UUID — folds {PATH: UUID} into MAP_FILE in
# place. PATH + UUID reach jq only as --arg VALUES in a static program (never
# concatenated into jq source) — the same discipline as merge_*_field.
merge_media_map() {
	mmm_map_file=$1
	mmm_path=$2
	mmm_uuid=$3
	MEDIA_COUNTER=$((MEDIA_COUNTER + 1))
	mmm_tmp_file="$WORKDIR/media-map-$MEDIA_COUNTER.json"
	jq -c --arg p "$mmm_path" --arg u "$mmm_uuid" \
		'. + {($p): $u}' "$mmm_map_file" >"$mmm_tmp_file"
	cp "$mmm_tmp_file" "$mmm_map_file"
}

# media_map_has_entries MAP_FILE -> 0 iff the map has at least one entry.
media_map_has_entries() {
	mmh_map_file=$1
	[ -n "$mmh_map_file" ] && [ -f "$mmh_map_file" ] || return 1
	mmh_count=$(jq -r 'length' "$mmh_map_file" 2>/dev/null || printf '0')
	[ "$mmh_count" -gt 0 ]
}

# lookup_path_in_map MAP_FILE PATH -> prints the mapped UUID or nothing. PATH
# via --arg into a static program (never concatenated into jq source). Defined
# above its sole caller resolve_inline_images (define-before-use), matching the
# ordering of the other Cycle B helpers.
lookup_path_in_map() {
	lpm_map_file=$1
	lpm_path=$2
	jq -rn --slurpfile m "$lpm_map_file" --arg p "$lpm_path" '($m[0][$p]) // ""'
}

# resolve_inline_images KEY MARKDOWN_FILE -> prints the path to a media-map
# file {localPath: mediaUUID} for every UNIQUE own-line local image in
# MARKDOWN_FILE. For each: require_readable_file -> upload to KEY (Cycle A
# multipart) -> attachment id -> resolve_media_uuid -> UUID -> merge into map.
# An empty `{}` map is returned when there are no inline images (behavior is
# then exactly as before this feature: convert with an empty map == no media).
# KEY is a shape-validated ticket key (safe URL path segment) at every call site.
resolve_inline_images() {
	rii_key=$1
	rii_markdown_file=$2
	ensure_workdir
	MEDIA_COUNTER=$((MEDIA_COUNTER + 1))
	rii_paths_file="$WORKDIR/inline-images-$MEDIA_COUNTER.paths"
	rii_map_file="$WORKDIR/inline-images-$MEDIA_COUNTER.map.json"

	scan_inline_image_paths "$rii_markdown_file" >"$rii_paths_file"
	printf '{}' >"$rii_map_file"

	# No inline images -> empty map, no uploads (identical to pre-feature).
	if [ ! -s "$rii_paths_file" ]; then
		printf '%s' "$rii_map_file"
		return 0
	fi

	rii_upload_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${rii_key}/attachments"
	# Read from a FILE (not a pipe) so this loop runs in THIS shell and the
	# map accumulation survives (subshell-scope-loss trap).
	while IFS= read -r rii_path; do
		[ -n "$rii_path" ] || continue
		# Dedup: a path already in the map was uploaded on an earlier line.
		rii_existing=$(lookup_path_in_map "$rii_map_file" "$rii_path")
		[ -z "$rii_existing" ] || continue

		require_readable_file "$rii_path" "inline image"
		jira_curl_multipart POST "$rii_upload_url" "$(printf '%s\n' "$rii_path")"
		handle_http_status "$JIRA_HTTP_CODE" "upload inline image '$rii_path' to $rii_key"
		require_json_body "upload inline image '$rii_path' to $rii_key"
		if ! jq -e 'type == "array" and length >= 1' "$JIRA_HTTP_BODY_FILE" >/dev/null 2>&1; then
			error "upload inline image '$rii_path' to $rii_key: response was not a non-empty JSON array"
			exit 1
		fi
		rii_attach_id=$(jq -r '.[0].id // ""' "$JIRA_HTTP_BODY_FILE")
		validate_numeric_id "$rii_attach_id" || {
			error "upload inline image '$rii_path' to $rii_key: attachment id was not numeric"
			exit 1
		}
		rii_uuid=$(resolve_media_uuid "$rii_attach_id")
		merge_media_map "$rii_map_file" "$rii_path" "$rii_uuid"
	done <"$rii_paths_file"

	printf '%s' "$rii_map_file"
}

# init_fields_accumulator OUT_FILE — creates an empty `{}` accumulator that
# merge_*_field() below fold new keys into, one call at a time.
init_fields_accumulator() {
	out_file=$1
	printf '{}' >"$out_file"
}

# merge_string_field ACC_FILE JSON_KEY VALUE — merges {JSON_KEY: VALUE} (a
# plain string field: summary, duedate, ...) into ACC_FILE in place.
merge_string_field() {
	target_acc_file=$1
	json_key=$2
	string_value=$3
	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	merge_tmp_file="$WORKDIR/merge-$MERGE_COUNTER.json"
	jq -c --arg k "$json_key" --arg v "$string_value" \
		'. + {($k): $v}' "$target_acc_file" >"$merge_tmp_file"
	cp "$merge_tmp_file" "$target_acc_file"
}

# merge_ref_field ACC_FILE JSON_FIELD INNER_KEY INNER_VALUE — merges
# {JSON_FIELD: {INNER_KEY: INNER_VALUE}} into ACC_FILE in place. This is the
# ONE shape Jira uses for every "reference by X" field: project/parent by
# "key", issuetype by "name", assignee by "id", a custom user-picker field
# (e.g. "developer") by "accountId" — one helper, four real call sites,
# genuinely the same structural pattern (not a premature abstraction).
merge_ref_field() {
	target_acc_file=$1
	json_field=$2
	inner_key=$3
	inner_value=$4
	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	merge_tmp_file="$WORKDIR/merge-$MERGE_COUNTER.json"
	jq -c --arg f "$json_field" --arg ik "$inner_key" --arg iv "$inner_value" \
		'. + {($f): {($ik): $iv}}' "$target_acc_file" >"$merge_tmp_file"
	cp "$merge_tmp_file" "$target_acc_file"
}

# merge_json_field ACC_FILE JSON_KEY VALUE_FILE — merges {JSON_KEY: <value
# parsed from VALUE_FILE>} into ACC_FILE in place, via --slurpfile (per the
# brief: read the ADF file with --slurpfile/--argjson, never string-concat).
# JSON_KEY may be a config-resolved custom field id ("customfield_16102") —
# it is still only ever a jq *value* (via --arg), never program text.
merge_json_field() {
	target_acc_file=$1
	json_key=$2
	value_file=$3
	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	merge_tmp_file="$WORKDIR/merge-$MERGE_COUNTER.json"
	jq -c --arg k "$json_key" --slurpfile v "$value_file" \
		'. + {($k): $v[0]}' "$target_acc_file" >"$merge_tmp_file"
	cp "$merge_tmp_file" "$target_acc_file"
}

# merge_labels_field ACC_FILE CSV — merges {labels: [...]} into ACC_FILE in
# place, splitting/trimming CSV the same way build_search_request_body()
# already does for --fields (consistent idiom, not a new one).
merge_labels_field() {
	target_acc_file=$1
	labels_csv=$2
	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	merge_tmp_file="$WORKDIR/merge-$MERGE_COUNTER.json"
	jq -c --arg csv "$labels_csv" \
		'. + {labels: ($csv | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$";"")) | map(select(length > 0)))}' \
		"$target_acc_file" >"$merge_tmp_file"
	cp "$merge_tmp_file" "$target_acc_file"
}

# merge_bool_field ACC_FILE JSON_KEY BOOL — merges {JSON_KEY: <true|false>}
# into ACC_FILE in place. BOOL is a bare `true`/`false` literal read via
# --argjson (so it lands as a JSON boolean, not the string "true"). Used by the
# FLAT /version bodies (released/archived), the one place this engine writes a
# boolean field — the same static-program/--argjson discipline as merge_*_field
# above, just for a scalar boolean instead of a string/object.
merge_bool_field() {
	target_acc_file=$1
	json_key=$2
	bool_value=$3
	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	merge_tmp_file="$WORKDIR/merge-$MERGE_COUNTER.json"
	jq -c --arg k "$json_key" --argjson v "$bool_value" \
		'. + {($k): $v}' "$target_acc_file" >"$merge_tmp_file"
	cp "$merge_tmp_file" "$target_acc_file"
}

# merge_int_field ACC_FILE JSON_KEY INT — merges {JSON_KEY: <INT as a JSON
# number>} into ACC_FILE in place. INT is fed via --argjson so it lands as a
# JSON integer, not the string "826" — the Agile sprint API expects
# originBoardId as a NUMBER (ground-truth-verified). The CALLER must guarantee
# INT is a bare run of digits (validate_numeric_id upstream) so --argjson never
# sees a non-numeric literal; same static-program/--argjson discipline as
# merge_bool_field, just for an integer scalar.
merge_int_field() {
	target_acc_file=$1
	json_key=$2
	int_value=$3
	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	merge_tmp_file="$WORKDIR/merge-$MERGE_COUNTER.json"
	jq -c --arg k "$json_key" --argjson v "$int_value" \
		'. + {($k): $v}' "$target_acc_file" >"$merge_tmp_file"
	cp "$merge_tmp_file" "$target_acc_file"
}

# require_custom_field CONFIG_FILE SEMANTIC_NAME FLAG_NAME -> prints the
# config's custom_fields[SEMANTIC_NAME] field id, or fails closed (exit 1)
# if there is no config or no such mapping. DELIBERATE DIVERGENCE from the
# jira.py oracle: the oracle SILENTLY DROPS an --acceptance/--review update
# when the field isn't configured (no field id -> the whole block is
# skipped, no error, no write, no warning) — a user-requested update that
# silently does nothing is a defect (build-core: don't copy an anti-pattern
# to "stay consistent"), so this fails loud instead, naming exactly what's
# missing.
require_custom_field() {
	config_file=$1
	semantic_field_name=$2
	flag_name=$3
	if [ -z "$config_file" ]; then
		error "$flag_name requires a project config with custom_fields.$semantic_field_name mapped, but no project config was found"
		exit 1
	fi
	resolved_field_id=$(jq -r --arg n "$semantic_field_name" '.custom_fields[$n] // empty' "$config_file")
	if [ -z "$resolved_field_id" ]; then
		error "$flag_name requires custom_fields.$semantic_field_name to be mapped in the project config, but it is not"
		exit 1
	fi
	printf '%s' "$resolved_field_id"
}

# resolve_issue_type_of TICKET_KEY -> the issue's current issuetype name, via
# GET. Used only for subtask-parent-type validation on create.
resolve_issue_type_of() {
	lookup_ticket_key=$1
	lookup_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${lookup_ticket_key}?fields=issuetype"
	jira_curl GET "$lookup_url"
	handle_http_status "$JIRA_HTTP_CODE" "look up issue type for $lookup_ticket_key"
	require_json_body "look up issue type for $lookup_ticket_key"
	jq -r '.fields.issuetype.name // ""' "$JIRA_HTTP_BODY_FILE"
}

# fetch_project_collection PROJECT COLLECTION -> prints the path to a WORKDIR
# file holding the collection's PLAIN JSON ARRAY. COLLECTION is "versions" or
# "components". Fetched ONCE per data axis (see merge_named_refs /
# merge_attach_flags below): --fix-version and --affects-version are two FIELDS but
# ONE axis (versions), so the versions list is fetched a single time and shared
# — never once per field, never once per name. Both endpoints return a PLAIN
# array (NOT a paginated {values:[...]} envelope) — verified against live Jira.
# PROJECT is already shape-validated by the caller before it reaches this URL.
fetch_project_collection() {
	fpc_project=$1
	fpc_collection=$2
	fpc_url="https://${CONFIRMED_HOST}/rest/api/3/project/${fpc_project}/${fpc_collection}"
	jira_curl GET "$fpc_url"
	handle_http_status "$JIRA_HTTP_CODE" "list $fpc_collection for $fpc_project"
	require_json_body "list $fpc_collection for $fpc_project"
	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	fpc_array_file="$WORKDIR/attach-$fpc_collection-$MERGE_COUNTER.array.json"
	cp "$JIRA_HTTP_BODY_FILE" "$fpc_array_file"
	printf '%s' "$fpc_array_file"
}

# merge_named_refs ACC_FILE NAMES_NL ARRAY_FILE JSON_KEY LABEL PROJECT —
# resolves each caller-given NAME to its id against the already-fetched
# ARRAY_FILE and merges {JSON_KEY: [{"id":"..."}, ...]} into ACC_FILE. Used for
# create/update's --fix-version (fixVersions) / --affects-version (versions) /
# --component (components) flags.
#
#   NAMES_NL   newline-delimited names (repeatable flag accumulation); EMPTY is
#              a no-op (the flag was never given).
#   ARRAY_FILE the collection array from fetch_project_collection (resolved
#              LOCALLY, so NO extra network call per name).
#   JSON_KEY   "fixVersions" | "versions" | "components" — the fields{} key.
#   LABEL      human noun for diagnostics, e.g. "fix version" / "component".
#
# EXACT name match. Zero matches -> fail loud (exit 1). >1 match (duplicate
# display names DO occur in Jira) -> fail loud as ambiguous, never a silent
# last-wins pick.
#
# Each NAME enters jq ONLY as an --arg VALUE in a static program, and
# each resolved id is emitted as a jq-built {id: .} object — no name or id is
# ever concatenated into a jq program or a URL. The name-reading loop reads from
# a FILE redirect (never a `... | while` pipe), so it runs in THIS shell — its
# `exit 1` on a bad name actually terminates the script (a pipe subshell's
# would not) and no resolved id is lost to subshell scope.
merge_named_refs() {
	mnr_acc_file=$1
	mnr_names=$2
	mnr_array_file=$3
	mnr_json_key=$4
	mnr_label=$5
	mnr_project=$6

	[ -n "$mnr_names" ] || return 0

	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	mnr_names_file="$WORKDIR/attach-$mnr_json_key-$MERGE_COUNTER.names.txt"
	printf '%s' "$mnr_names" >"$mnr_names_file"
	mnr_ids_file="$WORKDIR/attach-$mnr_json_key-$MERGE_COUNTER.ids.txt"
	: >"$mnr_ids_file"

	while IFS= read -r mnr_name; do
		[ -n "$mnr_name" ] || continue
		mnr_match_count=$(jq --arg n "$mnr_name" \
			'[.[] | select(.name == $n)] | length' "$mnr_array_file")
		if [ "$mnr_match_count" -eq 0 ]; then
			error "$mnr_label '$mnr_name' not found in project $mnr_project"
			exit 1
		fi
		if [ "$mnr_match_count" -gt 1 ]; then
			error "$mnr_label '$mnr_name' is ambiguous in project $mnr_project ($mnr_match_count with that exact name) — resolve by picking a unique name"
			exit 1
		fi
		jq -r --arg n "$mnr_name" \
			'first(.[] | select(.name == $n) | .id)' "$mnr_array_file" >>"$mnr_ids_file"
	done <"$mnr_names_file"

	mnr_ref_file="$WORKDIR/attach-$mnr_json_key-$MERGE_COUNTER.ref.json"
	jq -R -n '[inputs | {id: .}]' <"$mnr_ids_file" >"$mnr_ref_file"
	merge_json_field "$mnr_acc_file" "$mnr_json_key" "$mnr_ref_file"
}

# merge_attach_flags ACC_FILE PROJECT — the shared create/update attach step:
# resolves --fix-version/--affects-version/--component names to id-refs and
# merges them into ACC_FILE's fields{} accumulator. The versions list is
# fetched ONCE and shared by fixVersions + versions; components once — so a
# create/update carrying all three flags makes at most TWO extra GETs, never
# one-per-flag or one-per-name. PROJECT is already shape-validated by the
# caller (create: OPT_PROJECT via try_load_project_config; update: the ticket
# key's extracted prefix) before it reaches fetch_project_collection's URL.
merge_attach_flags() {
	maf_acc_file=$1
	maf_project=$2

	if [ -n "$OPT_FIX_VERSIONS" ] || [ -n "$OPT_AFFECTS_VERSIONS" ]; then
		maf_versions_file=$(fetch_project_collection "$maf_project" versions)
		merge_named_refs "$maf_acc_file" "$OPT_FIX_VERSIONS"     "$maf_versions_file" fixVersions "fix version"     "$maf_project"
		merge_named_refs "$maf_acc_file" "$OPT_AFFECTS_VERSIONS" "$maf_versions_file" versions    "affects version" "$maf_project"
	fi
	if [ -n "$OPT_COMPONENTS" ]; then
		maf_components_file=$(fetch_project_collection "$maf_project" components)
		merge_named_refs "$maf_acc_file" "$OPT_COMPONENTS" "$maf_components_file" components "component" "$maf_project"
	fi
}

# ---------------------------------------------------------------------------
# view <KEY>
# ---------------------------------------------------------------------------

render_view_human() {
	body_file=$1
	key=$(jq -r '.key // ""' "$body_file" | strip_control_ansi)
	summary=$(jq -r '.fields.summary // ""' "$body_file" | strip_control_ansi)
	status=$(jq -r '.fields.status.name // "N/A"' "$body_file" | strip_control_ansi)
	itype=$(jq -r '.fields.issuetype.name // "N/A"' "$body_file" | strip_control_ansi)
	assignee=$(jq -r '.fields.assignee.displayName // "Unassigned"' "$body_file" | strip_control_ansi)
	printf 'Key:      %s\n' "$key"
	printf 'Summary:  %s\n' "$summary"
	printf 'Status:   %s\n' "$status"
	printf 'Type:     %s\n' "$itype"
	printf 'Assignee: %s\n' "$assignee"
}

cmd_view() {
	# TICKET_KEY presence/shape is validated up front, before any dep/site
	# gate check — see the main dispatch section's validate_command_args().
	PROJECT_CONFIG_FILE=""
	try_load_project_config "$(extract_project_from_key "$TICKET_KEY")"

	path="/rest/api/3/issue/$TICKET_KEY"
	if [ -n "$OPT_FIELDS" ]; then
		resolved_fields=$(resolve_fields_csv "$PROJECT_CONFIG_FILE" "$OPT_FIELDS")
		encoded=$(urlencode "$resolved_fields")
		path="${path}?fields=${encoded}"
	fi
	url="https://${CONFIRMED_HOST}${path}"

	jira_curl GET "$url"
	handle_http_status "$JIRA_HTTP_CODE" "view $TICKET_KEY"
	require_json_body "view $TICKET_KEY"

	if [ "$OPT_JSON" -eq 1 ]; then
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	render_view_human "$JIRA_HTTP_BODY_FILE"
}

# ---------------------------------------------------------------------------
# workflow <KEY>
# ---------------------------------------------------------------------------

render_workflow_human() {
	key=$1
	status_file=$2
	transitions_file=$3

	current_status=$(jq -r '.fields.status.name // "N/A"' "$status_file" | strip_control_ansi)
	issue_type=$(jq -r '.fields.issuetype.name // "N/A"' "$status_file" | strip_control_ansi)
	printf 'Ticket: %s\n' "$key"
	printf 'Type:   %s\n' "$issue_type"
	printf 'Status: %s\n\n' "$current_status"

	count=$(jq '.transitions | length' "$transitions_file")
	if [ "$count" -eq 0 ]; then
		printf 'No transitions available (ticket may be in a final state).\n'
		return 0
	fi

	printf 'Available transitions:\n'
	jq -r '.transitions[] | "\(.id)\t\(.to.name)"' "$transitions_file" | while IFS="$(printf '\t')" read -r tid tname; do
		clean_id=$(printf '%s' "$tid" | strip_control_ansi)
		clean_name=$(printf '%s' "$tname" | strip_control_ansi)
		printf '  -> %s (id %s)\n' "$clean_name" "$clean_id"
	done
}

cmd_workflow() {
	# TICKET_KEY presence/shape is validated up front — see cmd_view's note.
	trans_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/transitions"
	jira_curl GET "$trans_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch transitions for $TICKET_KEY"
	require_json_body "fetch transitions for $TICKET_KEY"
	transitions_body=$JIRA_HTTP_BODY_FILE

	if [ "$OPT_JSON" -eq 1 ]; then
		cat "$transitions_body"
		return 0
	fi

	status_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}?fields=status,issuetype"
	jira_curl GET "$status_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch status for $TICKET_KEY"
	require_json_body "fetch status for $TICKET_KEY"

	render_workflow_human "$TICKET_KEY" "$JIRA_HTTP_BODY_FILE" "$transitions_body"
}

# ---------------------------------------------------------------------------
# search
# ---------------------------------------------------------------------------

# Live-testing defect: the real /rest/api/3/search/jql, given NO
# explicit `fields`, returns each issue holding ONLY `id` — no `key`, no
# `fields` object at all — so render_search_human/--json show nulls
# (verified live: passing --fields "key,summary,status" works correctly).
# This is the real API's own default-fields behavior, not something this
# script can leave unset — DEFAULT_SEARCH_FIELDS is what --fields falls
# back to when the caller doesn't give one; `key` is always first since
# every downstream consumer (render_search_human, jq '.key') depends on it.
DEFAULT_SEARCH_FIELDS="key,summary,status,assignee,issuetype"

# build_search_request_body OUT_FILE JQL MAX_RESULTS TOKEN — writes ONE
# compact JSON object via a single static jq program (fields/nextPageToken
# included only when present) fed entirely via --arg/--argjson. JQL is
# passed as DATA into JSON structure here — the JQL-sink escaping already
# happened in build_jql(); this step only has to be JSON-safe, which --arg
# guarantees.
build_search_request_body() {
	out_file=$1
	jql=$2
	max_results=$3
	token=$4

	fields_csv=${OPT_FIELDS:-$DEFAULT_SEARCH_FIELDS}
	fields_json=$(printf '%s' "$fields_csv" | jq -R -c \
		'split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$";"")) | map(select(length > 0))')

	jq -n -c \
		--arg jql "$jql" \
		--argjson maxResults "$max_results" \
		--argjson fields "$fields_json" \
		--arg token "$token" \
		'{jql:$jql, maxResults:$maxResults, fields:$fields}
		 + (if ($token|length) > 0 then {nextPageToken:$token} else {} end)' \
		>"$out_file"
}

render_search_human() {
	issues_file=$1
	total=$2
	if [ "$total" -eq 0 ]; then
		printf 'No matching issues.\n'
		return 0
	fi
	printf '%s issue(s):\n\n' "$total"
	while IFS= read -r issue_line; do
		key=$(printf '%s' "$issue_line" | jq -r '.key' | strip_control_ansi)
		summary=$(printf '%s' "$issue_line" | jq -r '.fields.summary // ""' | strip_control_ansi)
		status=$(printf '%s' "$issue_line" | jq -r '.fields.status.name // "N/A"' | strip_control_ansi)
		printf '  %-12s [%s] %s\n' "$key" "$status" "$summary"
	done <"$issues_file"
}

cmd_search() {
	PROJECT_CONFIG_FILE=""
	[ -z "$OPT_PROJECT" ] || try_load_project_config "$OPT_PROJECT"

	# ensure_workdir MUST run here, in the MAIN shell, before
	# build_jql() — build_jql()'s --assignee path can call resolve_account_id()
	# -> jira_curl() -> ensure_workdir() from INSIDE the `jql=$(...)` command
	# substitution below, which is a SUBSHELL: a WORKDIR created only in that
	# subshell is discarded the instant the substitution ends (the EXIT trap
	# runs in the MAIN shell, where $WORKDIR would still be empty), orphaning
	# a jira.work.XXXXXX directory in TMPDIR every such search. Calling it
	# here first means jira_curl()'s own ensure_workdir() call is a no-op —
	# the subshell inherits an already-tracked, already-cleaned-up WORKDIR.
	ensure_workdir

	jql=$(build_jql)

	# page_limit caps the TOTAL fetched. 0 is the "unbounded" sentinel — paginate
	# to exhaustion (driven purely by isLast/nextPageToken) — which bulk --jql
	# sets via SEARCH_UNBOUNDED so it resolves the FULL matching set instead of
	# silently stopping at the 50 default. A user-supplied --limit is an explicit,
	# intentional cap and always wins over the unbounded mode (see resolve_bulk_keys_file).
	if [ "${SEARCH_UNBOUNDED:-0}" = "1" ] && [ -z "$OPT_LIMIT" ]; then
		page_limit=0
	else
		page_limit=${OPT_LIMIT:-50}
	fi
	page_size=${OPT_PAGE_SIZE:-50}
	[ "$page_size" -le 100 ] || { warn "--page-size capped at Jira's own 100-per-request ceiling"; page_size=100; }

	all_issues_file="$WORKDIR/search-issues.jsonl"
	: >"$all_issues_file"

	page_token=""
	total_fetched=0
	while :; do
		if [ "$page_limit" -gt 0 ]; then
			remaining=$((page_limit - total_fetched))
			[ "$remaining" -gt 0 ] || break
			this_page_size=$page_size
			[ "$remaining" -ge "$this_page_size" ] || this_page_size=$remaining
		else
			this_page_size=$page_size
		fi

		req_body_file="$WORKDIR/search-req-$((total_fetched + 1)).json"
		build_search_request_body "$req_body_file" "$jql" "$this_page_size" "$page_token"

		url="https://${CONFIRMED_HOST}/rest/api/3/search/jql"
		jira_curl POST "$url" "$req_body_file"
		handle_http_status "$JIRA_HTTP_CODE" "search"
		require_json_body "search"

		jq -c '.issues[]?' "$JIRA_HTTP_BODY_FILE" >>"$all_issues_file"
		page_count=$(jq '.issues | length' "$JIRA_HTTP_BODY_FILE")
		total_fetched=$((total_fetched + page_count))

		# NOTE: deliberately NOT `.isLast // true` — jq's `//` treats a JSON
		# `false` as falsy too (not just null/missing), so that idiom would
		# silently turn a real `isLast:false` into `true` and truncate
		# pagination after page one. An explicit null-check avoids it.
		is_last=$(jq -r 'if .isLast == null then true else .isLast end' "$JIRA_HTTP_BODY_FILE")
		[ "$is_last" != "true" ] && [ "$page_count" -gt 0 ] || break

		page_token=$(jq -r '.nextPageToken // empty' "$JIRA_HTTP_BODY_FILE")
		[ -n "$page_token" ] || break
	done

	if [ "$OPT_JSON" -eq 1 ]; then
		jq -s '{issues: .}' "$all_issues_file"
	else
		render_search_human "$all_issues_file" "$total_fetched"
	fi
}

# ---------------------------------------------------------------------------
# create — POST /rest/api/3/issue
# ---------------------------------------------------------------------------

# validate_issue_type_if_configured TYPE — a no-op when no project config
# was loaded, or when the config declares no issue_types at all (matches the
# oracle: an empty/absent list means "skip validation", not "reject everything").
validate_issue_type_if_configured() {
	candidate_type=$1
	[ -n "$PROJECT_CONFIG_FILE" ] || return 0
	jq -e --arg t "$candidate_type" \
		'(.issue_types // []) as $types | ($types | length) == 0 or (($types | index($t)) != null)' \
		"$PROJECT_CONFIG_FILE" >/dev/null 2>&1 || {
		error "invalid type '$candidate_type' for this project (see the project config's issue_types)"
		exit 1
	}
}

# is_subtask_type CONFIG_FILE TYPE -> 0 if TYPE is in the config's
# subtask_types list.
is_subtask_type() {
	config_file_for_check=$1
	candidate_type=$2
	jq -e --arg t "$candidate_type" '(.subtask_types // []) | index($t) != null' \
		"$config_file_for_check" >/dev/null 2>&1
}

# validate_subtask_parent_type CONFIG_FILE PARENT_TYPE — fails closed (exit
# 1) if the config declares subtask_parent_types and PARENT_TYPE isn't one
# of them (an empty/absent list means "no constraint configured").
validate_subtask_parent_type() {
	config_file_for_check=$1
	candidate_parent_type=$2
	jq -e --arg pt "$candidate_parent_type" \
		'(.subtask_parent_types // []) as $allowed | ($allowed | length) == 0 or (($allowed | index($pt)) != null)' \
		"$config_file_for_check" >/dev/null 2>&1 || {
		error "a subtask may only be created under one of the project config's subtask_parent_types (parent's type is: $candidate_parent_type)"
		exit 1
	}
}

cmd_create() {
	# --project/--title presence is validated up front — see the main
	# dispatch section's per-command required-argument validation.
	#
	# ensure_workdir MUST run here, in the MAIN shell, before ANY
	# call that might reach jira_curl() from inside a `$(...)` command
	# substitution (resolve_issue_type_of() below, for a subtask create, is
	# exactly such a call) — the same orphan-WORKDIR leak already fixed once
	# in cmd_search; see that function's own comment for the full mechanism.
	ensure_workdir

	PROJECT_CONFIG_FILE=""
	try_load_project_config "$OPT_PROJECT"

	resolved_issue_type=$(resolve_type_alias "$PROJECT_CONFIG_FILE" "${OPT_TYPE:-Task}")
	validate_issue_type_if_configured "$resolved_issue_type"

	if [ -n "$PROJECT_CONFIG_FILE" ] && is_subtask_type "$PROJECT_CONFIG_FILE" "$resolved_issue_type"; then
		if [ -z "$OPT_PARENT" ]; then
			error "issue type '$resolved_issue_type' requires --parent (a subtask type per the project config)"
			exit 1
		fi
		# --parent becomes a URL path segment in resolve_issue_type_of
		# below — shape-validate it FIRST, the same rule ticket keys already
		# follow everywhere else they reach a URL.
		validate_ticket_key "$OPT_PARENT" || { error "invalid parent ticket key: $OPT_PARENT"; exit 1; }
		parent_issue_type=$(resolve_issue_type_of "$OPT_PARENT")
		validate_subtask_parent_type "$PROJECT_CONFIG_FILE" "$parent_issue_type"
	fi

	create_fields_acc="$WORKDIR/create-fields.json"
	init_fields_accumulator "$create_fields_acc"

	merge_ref_field "$create_fields_acc" project key "$OPT_PROJECT"
	merge_ref_field "$create_fields_acc" issuetype name "$resolved_issue_type"
	merge_string_field "$create_fields_acc" summary "$OPT_TITLE"

	if [ -n "$OPT_DESCRIPTION_FILE" ]; then
		require_readable_file "$OPT_DESCRIPTION_FILE" "--description-file"
		description_adf_file=$(convert_markdown_file_to_adf "$OPT_DESCRIPTION_FILE")
		merge_json_field "$create_fields_acc" description "$description_adf_file"
	fi

	if [ -n "$OPT_ACCEPTANCE_FILE" ]; then
		# the usage-error (require_readable_file, exit 2) runs
		# BEFORE the precondition check (require_custom_field, exit 1) — a
		# bad file path is a caller typo and should surface first, same
		# ordering rule as the rest of this script (usage before preconditions).
		require_readable_file "$OPT_ACCEPTANCE_FILE" "--acceptance-file"
		acceptance_field_id=$(require_custom_field "$PROJECT_CONFIG_FILE" acceptance_criteria "--acceptance-file")
		acceptance_adf_file=$(convert_markdown_file_to_adf "$OPT_ACCEPTANCE_FILE")
		merge_json_field "$create_fields_acc" "$acceptance_field_id" "$acceptance_adf_file"
	fi

	if [ -n "$OPT_REVIEW_FILE" ]; then
		require_readable_file "$OPT_REVIEW_FILE" "--review-file"
		review_field_id=$(require_custom_field "$PROJECT_CONFIG_FILE" review_notes "--review-file")
		review_adf_file=$(convert_markdown_file_to_adf "$OPT_REVIEW_FILE")
		merge_json_field "$create_fields_acc" "$review_field_id" "$review_adf_file"
	fi

	if [ -n "$OPT_ASSIGNEE" ]; then
		assignee_account_id=$(resolve_account_id "$OPT_ASSIGNEE")
		merge_ref_field "$create_fields_acc" assignee id "$assignee_account_id"
	fi

	[ -z "$OPT_LABELS" ]   || merge_labels_field "$create_fields_acc" "$OPT_LABELS"
	[ -z "$OPT_DUE_DATE" ] || merge_string_field "$create_fields_acc" duedate "$OPT_DUE_DATE"
	[ -z "$OPT_PARENT" ]   || merge_ref_field "$create_fields_acc" parent key "$OPT_PARENT"

	# Attach flags resolve NAME -> id against the project's live version/
	# component lists (versions fetched once, components once) and merge
	# fixVersions/versions/components:[{id}]. OPT_PROJECT is the create target —
	# already shape-validated by try_load_project_config above before it reaches
	# a URL.
	merge_attach_flags "$create_fields_acc" "$OPT_PROJECT"

	create_request_file="$WORKDIR/create-request.json"
	jq -n --slurpfile fields "$create_fields_acc" '{fields: $fields[0]}' >"$create_request_file"

	create_url="https://${CONFIRMED_HOST}/rest/api/3/issue"
	jira_curl POST "$create_url" "$create_request_file"
	handle_http_status "$JIRA_HTTP_CODE" "create issue"
	require_json_body "create issue"
	# Hold onto the create's OWN 201 body (key/id/self) — jira_curl writes a
	# fresh file per call, so this path stays valid across the follow-up calls
	# below; the --json passthrough must return THIS body, not a later one.
	create_response_body=$JIRA_HTTP_BODY_FILE
	created_key=$(jq -r '.key // ""' "$create_response_body" | strip_control_ansi)
	# created_key becomes a URL path segment in EVERY use below (the inline-image
	# upload URL inside resolve_inline_images, the description-update URL, and the
	# browse URL) — shape-validate it HERE, right after it is extracted from the
	# 201 body and BEFORE the first such use, the same validate-before-URL
	# invariant the comment/update call sites enforce on their up-front TICKET_KEY.
	validate_ticket_key "$created_key" || {
		error "internal: created issue key is not a valid ticket key: $created_key"
		exit 1
	}

	# --- Inline images: the 2-STEP ordering. An attachment upload needs a live
	# issue, so the description above was converted and sent WITHOUT media (an
	# empty map). Now the issue EXISTS: run the pre-pass against the new key
	# and, only if it found inline images, re-convert the description WITH the
	# media map and PUT it back. Net effect: one create + (only when inline
	# images are present) exactly one follow-up description update. With no
	# inline images this block makes ZERO extra calls — identical to before. ---
	if [ -n "$OPT_DESCRIPTION_FILE" ]; then
		create_media_map=$(resolve_inline_images "$created_key" "$OPT_DESCRIPTION_FILE")
		if media_map_has_entries "$create_media_map"; then
			create_media_desc_file=$(convert_markdown_file_to_adf "$OPT_DESCRIPTION_FILE" "$create_media_map")
			create_desc_update_acc="$WORKDIR/create-desc-update-fields.json"
			init_fields_accumulator "$create_desc_update_acc"
			merge_json_field "$create_desc_update_acc" description "$create_media_desc_file"
			create_desc_update_req="$WORKDIR/create-desc-update-request.json"
			jq -n --slurpfile fields "$create_desc_update_acc" '{fields: $fields[0]}' >"$create_desc_update_req"
			create_desc_update_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${created_key}"
			jira_curl PUT "$create_desc_update_url" "$create_desc_update_req"
			handle_http_status "$JIRA_HTTP_CODE" "update description with inline images on $created_key"
			# PUT /issue returns 204 No Content — no require_json_body here.
		fi
	fi

	if [ "$OPT_JSON" -eq 1 ]; then
		# PASSTHROUGH, not synthesized — Jira's own 201 response
		# body (key/id/self) IS the answer; there is nothing this script
		# could usefully re-derive, unlike update's --json (see cmd_update).
		cat "$create_response_body"
		return 0
	fi
	printf 'JIRA_ISSUE_KEY=%s\n' "$created_key"
	printf 'JIRA_ISSUE_URL=https://%s/browse/%s\n' "$CONFIRMED_HOST" "$created_key"
}

# ---------------------------------------------------------------------------
# comment — POST /rest/api/3/issue/<KEY>/comment
# ---------------------------------------------------------------------------

cmd_comment() {
	# TICKET_KEY/--text-file presence is validated up front — see the main
	# dispatch section's per-command required-argument validation.
	#
	# ensure_workdir MUST run here, in the MAIN shell, before
	# convert_markdown_file_to_adf() below — that call reaches jira_curl()
	# from INSIDE its own `$(...)` command substitution at the call site
	# two lines down, which is a subshell (same class of leak already fixed
	# in cmd_search; see that function's comment for the full mechanism).
	ensure_workdir

	require_readable_file "$OPT_TEXT_FILE" "--text-file"
	# Inline-image pre-pass: upload each own-line local image to the issue and
	# build a media map, then convert WITH that map so the images become
	# mediaSingle blocks. An upload to a nonexistent KEY fails loud here (the
	# attachments POST 404s), so the issue's existence is enforced before the
	# comment is posted. No inline images -> empty map -> unchanged behavior.
	comment_media_map=$(resolve_inline_images "$TICKET_KEY" "$OPT_TEXT_FILE")
	comment_adf_file=$(convert_markdown_file_to_adf "$OPT_TEXT_FILE" "$comment_media_map")

	comment_request_file="$WORKDIR/comment-request.json"
	jq -n --slurpfile body "$comment_adf_file" '{body: $body[0]}' >"$comment_request_file"

	comment_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/comment"
	jira_curl POST "$comment_url" "$comment_request_file"
	handle_http_status "$JIRA_HTTP_CODE" "comment on $TICKET_KEY"
	require_json_body "comment on $TICKET_KEY"

	if [ "$OPT_JSON" -eq 1 ]; then
		# PASSTHROUGH, not synthesized — same reasoning as create's
		# --json (see cmd_create): Jira's 201 body IS the answer.
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	new_comment_id=$(jq -r '.id // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
	printf 'JIRA_COMMENT_ID=%s\n' "$new_comment_id"
}

# ---------------------------------------------------------------------------
# transition — POST /rest/api/3/issue/<KEY>/transitions, BFS auto-walk
# ---------------------------------------------------------------------------

# BFS_PROGRAM — a single static jq program (never built from data) computing
# the shortest path from $start to $goal over a GRAPH object shaped
# {status: [reachable, statuses, ...], ...} — the same shape as a project
# config's workflows.<issuetype> entry. Returns a JSON array of statuses
# EXCLUDING $start (path[-1] matches $goal), or `null` if unreachable. A
# plain queue+visited-set BFS; workflow graphs are a handful of nodes, so
# recursion depth here is trivial.
#
# the goal comparison is CASE-INSENSITIVE (`ascii_downcase` both
# sides) — a caller's `--status closed` must match a graph node literally
# spelled "Closed", or a spurious "no valid workflow path" results. The
# stored/returned path element is still $n — the GRAPH's own (canonically
# cased) node name — never $goal, so the walked path always displays in
# the config's own casing regardless of how the caller spelled --status.
# shellcheck disable=SC2016  # single-quoted on purpose: $graph/$start/etc below are jq syntax, not shell expansions
BFS_PROGRAM='
def bfs($graph; $start; $goal):
  {frontier: [{node: $start, path: []}], visited: {($start): true}} as $init
  | (
      def step(state):
        if (state.frontier | length) == 0 then null
        else
          (state.frontier[0]) as $cur
          | (state.frontier[1:]) as $rest
          | ($graph[$cur.node] // []) as $neighbors
          | (reduce $neighbors[] as $n
              ({frontier: $rest, visited: state.visited, found: null};
                if .found != null then .
                elif ($n | ascii_downcase) == ($goal | ascii_downcase) then .found = ($cur.path + [$n])
                elif (.visited[$n] // false) then .
                else
                  .visited = (.visited + {($n): true})
                  | .frontier = (.frontier + [{node: $n, path: ($cur.path + [$n])}])
                end
              )
            ) as $next
          | if $next.found != null then $next.found
            else step({frontier: $next.frontier, visited: $next.visited})
            end
        end;
      step($init)
    );
bfs($graph; $start; $goal)
'

# compute_transition_path OUT_FILE CONFIG_FILE ISSUE_TYPE CURRENT TARGET —
# writes a newline-separated walk path (CURRENT excluded, TARGET last) to
# OUT_FILE. No config, no workflow entry for ISSUE_TYPE, or an explicit
# `null` config value (a deliberately "flexible" workflow, e.g. Epic) all
# mean a DIRECT one-step transition (matches the oracle's fallback) — OUT_FILE
# is left EMPTY only when a real graph exists but no path was found.
compute_transition_path() {
	path_out_file=$1
	config_file_for_path=$2
	issue_type_for_path=$3
	current_status_for_path=$4
	target_status_for_path=$5

	workflow_graph_json="null"
	if [ -n "$config_file_for_path" ]; then
		workflow_graph_json=$(jq -c --arg t "$issue_type_for_path" '.workflows[$t] // null' "$config_file_for_path" 2>/dev/null || printf 'null')
		# One level of "@Alias" workflow-reference resolution (e.g. a config's
		# "Story": "@Task" — see the oracle's ProjectConfig._resolve_workflows).
		case "$workflow_graph_json" in
			'"@'*'"')
				alias_issue_type=$(printf '%s' "$workflow_graph_json" | jq -r '.[1:]')
				workflow_graph_json=$(jq -c --arg t "$alias_issue_type" '.workflows[$t] // null' "$config_file_for_path" 2>/dev/null || printf 'null')
				;;
		esac
	fi

	if [ "$workflow_graph_json" = "null" ]; then
		printf '%s\n' "$target_status_for_path" >"$path_out_file"
		return 0
	fi

	# -n is REQUIRED here: with no input filename/redirect, a `jq` invocation
	# without -n blocks reading stdin (it has no input of its own — every
	# value it needs travels via --argjson/--arg) instead of just running the
	# filter once and exiting.
	bfs_result_json=$(jq -nc --argjson graph "$workflow_graph_json" \
		--arg start "$current_status_for_path" --arg goal "$target_status_for_path" \
		"$BFS_PROGRAM" 2>/dev/null || printf 'null')
	if [ -z "$bfs_result_json" ] || [ "$bfs_result_json" = "null" ]; then
		: >"$path_out_file"
		return 0
	fi
	printf '%s' "$bfs_result_json" | jq -r '.[]' >"$path_out_file"
}

# split_tab_pair LINE — sets $TAB_PAIR_FIRST/$TAB_PAIR_SECOND from a
# "FIRST<TAB>SECOND" line (the shape find_transition_id_and_name emits) —
# the same tab-per-field idiom render_workflow_human already reads with
# `IFS="$(printf '\t')" read -r`, applied here to a captured variable
# instead of a piped stream.
split_tab_pair() {
	old_ifs=$IFS
	IFS="$(printf '\t')"
	set -f
	# shellcheck disable=SC2086  # deliberate tab-split; -f (above) blocks globbing
	set -- $1
	set +f
	IFS=$old_ifs
	TAB_PAIR_FIRST=$1
	TAB_PAIR_SECOND=${2:-}
}

# find_transition_id_and_name TICKET_KEY TARGET_STATUS_NAME -> prints
# "ID<TAB>CANONICAL_NAME" for the transition whose .to.name matches
# TARGET_STATUS_NAME case-insensitively (matches the oracle's
# `t['to']['name'].lower() == target_status.lower()`), or nothing if none
# match. Returning Jira's OWN canonically-cased .to.name — not the caller's
# possibly differently-cased TARGET_STATUS_NAME — lets verify_status_is
# compare against the exact string the API will report back after the
# write, so a caller's `--status closed` verifies correctly against the
# API's actual "Closed".
#
# F3 (live-testing note): a real workflow can legitimately offer TWO
# transitions with the SAME .to.name (seen live: two distinct "In
# Progress" transitions on one status). The match is DETERMINISTIC — the
# FIRST one in Jira's own `.transitions[]` response order, via jq's `[0]`
# over that array's original order, never re-sorted — but a silent pick
# between two same-named-but-different transitions is worth surfacing, so
# an ambiguous match gets a one-line stderr note naming the count.
find_transition_id_and_name() {
	transition_lookup_key=$1
	transition_target_name=$2
	transitions_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${transition_lookup_key}/transitions"
	jira_curl GET "$transitions_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch transitions for $transition_lookup_key"
	require_json_body "fetch transitions for $transition_lookup_key"

	matching_transition_count=$(jq -r --arg t "$transition_target_name" \
		'[.transitions[] | select((.to.name // "") | ascii_downcase == ($t | ascii_downcase))] | length' \
		"$JIRA_HTTP_BODY_FILE")
	if [ "$matching_transition_count" -gt 1 ]; then
		warn "$matching_transition_count transitions on $transition_lookup_key are named '$transition_target_name' — picking the first"
	fi

	jq -r --arg t "$transition_target_name" \
		'[.transitions[] | select((.to.name // "") | ascii_downcase == ($t | ascii_downcase))][0]
		 | if . == null then empty else "\(.id)\t\(.to.name)" end' \
		"$JIRA_HTTP_BODY_FILE"
}

# execute_plain_transition TICKET_KEY TRANSITION_ID — a step with no
# resolution attached. Jira returns 204 No Content on success — deliberately
# NO require_json_body call here (an empty body IS the correct success shape).
execute_plain_transition() {
	exec_ticket_key=$1
	exec_transition_id=$2
	ensure_workdir
	TRANS_COUNTER=$((TRANS_COUNTER + 1))
	transition_body_file="$WORKDIR/transition-body-$TRANS_COUNTER.json"
	jq -n --arg id "$exec_transition_id" '{transition: {id: $id}}' >"$transition_body_file"
	step_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${exec_ticket_key}/transitions"
	jira_curl POST "$step_url" "$transition_body_file"
	handle_http_status "$JIRA_HTTP_CODE" "transition $exec_ticket_key (id $exec_transition_id)"
}

# execute_transition_with_resolution TICKET_KEY TRANSITION_ID RESOLUTION —
# the FINAL-step variant (matches the oracle's _transition_with_resolution):
# sets fields.resolution AND appends a system-generated closing comment in
# the SAME request, via REST fields{}/update{} — not the oracle's acli shape.
execute_transition_with_resolution() {
	exec_ticket_key=$1
	exec_transition_id=$2
	exec_resolution=$3
	ensure_workdir
	TRANS_COUNTER=$((TRANS_COUNTER + 1))
	transition_body_file="$WORKDIR/transition-body-$TRANS_COUNTER.json"
	jq -n --arg id "$exec_transition_id" --arg resolution "$exec_resolution" \
		--arg comment_text "Closed with resolution: $exec_resolution" \
		'{transition: {id: $id},
		  fields: {resolution: {name: $resolution}},
		  update: {comment: [{add: {body: {type: "doc", version: 1,
		    content: [{type: "paragraph", content: [{type: "text", text: $comment_text}]}]}}}]}}' \
		>"$transition_body_file"
	step_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${exec_ticket_key}/transitions"
	jira_curl POST "$step_url" "$transition_body_file"
	handle_http_status "$JIRA_HTTP_CODE" "transition $exec_ticket_key with resolution '$exec_resolution'"
}

# verify_status_is TICKET_KEY EXPECTED_STATUS — re-fetches the
# issue's CURRENT status after every write step and fails loud (exit 1) if
# it does not match, instead of trusting a 2xx/204 as proof the transition
# actually applied (a workflow condition/validator can reject silently).
verify_status_is() {
	verify_ticket_key=$1
	verify_expected_status=$2
	verify_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${verify_ticket_key}?fields=status"
	jira_curl GET "$verify_url"
	handle_http_status "$JIRA_HTTP_CODE" "verify status for $verify_ticket_key"
	require_json_body "verify status for $verify_ticket_key"
	verify_actual_status=$(jq -r '.fields.status.name // ""' "$JIRA_HTTP_BODY_FILE")
	if [ "$verify_actual_status" != "$verify_expected_status" ]; then
		error "transition to '$verify_expected_status' for $verify_ticket_key did not apply (status is still '$verify_actual_status')"
		exit 1
	fi
}

# walk_transition_path TICKET_KEY PATH_FILE RESOLUTION — walks each step of
# PATH_FILE in order, verifying status after EACH step. The LAST
# step, when RESOLUTION is non-empty, is submitted WITH the resolution (see
# execute_transition_with_resolution); every other step is a plain
# transition. Reads PATH_FILE via redirection (not a pipe) so the loop runs
# in THIS shell, not a subshell — matching md-to-adf.sh's own read-loop
# idiom — since `exit` inside a piped subshell would not reliably read as
# "this whole script failed" to every reader of this code.
walk_transition_path() {
	walk_ticket_key=$1
	walk_path_file=$2
	walk_resolution=$3

	walk_last_step=$(tail -n 1 "$walk_path_file")

	while IFS= read -r walk_step; do
		[ -n "$walk_step" ] || continue
		walk_id_and_name=$(find_transition_id_and_name "$walk_ticket_key" "$walk_step")
		if [ -z "$walk_id_and_name" ]; then
			error "no transition to '$walk_step' available for $walk_ticket_key"
			exit 1
		fi
		split_tab_pair "$walk_id_and_name"
		walk_transition_id=$TAB_PAIR_FIRST
		# verify against Jira's OWN canonical name for this step
		# (not $walk_step, which may carry the caller's original casing) —
		# see find_transition_id_and_name's header note.
		walk_canonical_name=$TAB_PAIR_SECOND

		if [ "$walk_step" = "$walk_last_step" ] && [ -n "$walk_resolution" ]; then
			execute_transition_with_resolution "$walk_ticket_key" "$walk_transition_id" "$walk_resolution"
		else
			execute_plain_transition "$walk_ticket_key" "$walk_transition_id"
		fi

		verify_status_is "$walk_ticket_key" "$walk_canonical_name"
	done <"$walk_path_file"
}

# render_transition_summary_json KEY FROM TO PATH_FILE RESOLUTION EXECUTED
# [ALREADY_AT_TARGET] — the ONE --json shape for --plan (EXECUTED=false), a
# real walk (EXECUTED=true), AND the already-at-target no-op — all
# three routed through this single renderer so they can never
# drift into three different ad-hoc object shapes. ALREADY_AT_TARGET
# defaults to "false" when the caller omits it (--plan / a real walk always
# have a genuine path to walk, so they never need to pass it explicitly).
render_transition_summary_json() {
	summary_key=$1
	summary_from=$2
	summary_to=$3
	summary_path_file=$4
	summary_resolution=$5
	summary_executed=$6
	summary_already_at_target=${7:-false}
	jq -n --arg key "$summary_key" --arg from "$summary_from" --arg to "$summary_to" \
		--arg resolution "$summary_resolution" --rawfile path_raw "$summary_path_file" \
		--argjson executed "$summary_executed" --argjson alreadyAtTarget "$summary_already_at_target" \
		'{key: $key, from: $from, to: $to,
		  path: ($path_raw | split("\n") | map(select(length > 0))),
		  resolution: (if ($resolution | length) > 0 then $resolution else null end),
		  executed: $executed,
		  alreadyAtTarget: $alreadyAtTarget}'
}

# render_transition_plan_human KEY FROM TO PATH_FILE RESOLUTION — the
# --plan human render: the FULL walked path + any injected resolution,
# WITHOUT writing anything (what the P4 consent gate discloses).
render_transition_plan_human() {
	plan_key=$1
	plan_from=$2
	plan_to=$3
	plan_path_file=$4
	plan_resolution=$5
	printf 'PLAN for %s: %s -> %s\n' "$plan_key" "$plan_from" "$plan_to"
	plan_step_num=0
	while IFS= read -r plan_step; do
		[ -n "$plan_step" ] || continue
		plan_step_num=$((plan_step_num + 1))
		printf '  step %d: -> %s\n' "$plan_step_num" "$plan_step"
	done <"$plan_path_file"
	if [ -n "$plan_resolution" ]; then
		printf 'Will set resolution: %s\n' "$plan_resolution"
		printf 'Will add a system comment: "Closed with resolution: %s"\n' "$plan_resolution"
	fi
	printf 'NOTHING WAS WRITTEN (dry-run / --plan).\n'
}

cmd_transition() {
	# TICKET_KEY/--status presence is validated up front — see the main
	# dispatch section's per-command required-argument validation.
	#
	# ensure_workdir runs FIRST, unconditionally — every branch below
	# (including the already-at-target no-op) needs a WORKDIR file at some
	# point, and calling it once here (rather than deep in one branch only)
	# is what the fix pattern in cmd_create/cmd_comment establishes:
	# have it ready before any subshell call could reach jira_curl() first.
	ensure_workdir

	PROJECT_CONFIG_FILE=""
	try_load_project_config "$(extract_project_from_key "$TICKET_KEY")"

	current_status_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}?fields=status,issuetype"
	jira_curl GET "$current_status_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch current status for $TICKET_KEY"
	require_json_body "fetch current status for $TICKET_KEY"
	current_status=$(jq -r '.fields.status.name // ""' "$JIRA_HTTP_BODY_FILE")
	current_issue_type=$(jq -r '.fields.issuetype.name // ""' "$JIRA_HTTP_BODY_FILE")
	if [ -z "$current_status" ]; then
		error "could not determine current status for $TICKET_KEY"
		exit 1
	fi

	target_status=$OPT_STATUS
	# Live-testing defect: resolution is STRICTLY OPT-IN — set ONLY
	# when the caller explicitly passes --resolution. This engine used to
	# auto-default resolution="Resolved" whenever the target was (case-
	# insensitively) "Closed", but a workflow whose Closed screen has NO
	# resolution field then gets a live HTTP 400 ("Field 'resolution'
	# cannot be set. It is not on the appropriate screen, or unknown.") —
	# confirmed against a real Jira site. A workflow that genuinely
	# REQUIRES a resolution still 400s clearly and the caller re-runs with
	# --resolution; this engine no longer guesses on the caller's behalf.
	transition_resolution=$OPT_RESOLUTION

	# compare case-insensitively — current_status is Jira's own
	# canonical casing; target_status is whatever the caller typed
	# (`--status closed` is exactly as valid as `--status Closed`). Display
	# uses current_status (the authoritative value) for both from/to, so
	# the message never shows two different spellings of the same status.
	if [ "$(downcase "$current_status")" = "$(downcase "$target_status")" ]; then
		already_at_target_path_file="$WORKDIR/transition-empty-path.txt"
		: >"$already_at_target_path_file"
		if [ "$OPT_JSON" -eq 1 ]; then
			# routed through the SAME shared renderer
			# --plan and a real walk use — see render_transition_summary_json's
			# header note on why a third hand-built shape is a defect.
			render_transition_summary_json "$TICKET_KEY" "$current_status" "$current_status" \
				"$already_at_target_path_file" "" false true
		else
			printf '%s is already "%s"\n' "$TICKET_KEY" "$current_status"
		fi
		return 0
	fi

	transition_path_file="$WORKDIR/transition-path.txt"
	compute_transition_path "$transition_path_file" "$PROJECT_CONFIG_FILE" "$current_issue_type" "$current_status" "$target_status"

	if [ ! -s "$transition_path_file" ]; then
		error "no valid workflow path from '$current_status' to '$target_status' for issue type '$current_issue_type'"
		exit 1
	fi

	if [ "$OPT_PLAN" -eq 1 ]; then
		if [ "$OPT_JSON" -eq 1 ]; then
			# SYNTHESIZED, not passthrough — --plan never calls the
			# transitions-write endpoint at all (that is the whole point of
			# --plan), so there is no Jira response to pass through; this is
			# the locally-computed disclosure the P4 consent gate shows.
			render_transition_summary_json "$TICKET_KEY" "$current_status" "$target_status" "$transition_path_file" "$transition_resolution" false
		else
			render_transition_plan_human "$TICKET_KEY" "$current_status" "$target_status" "$transition_path_file" "$transition_resolution"
		fi
		return 0
	fi

	walk_transition_path "$TICKET_KEY" "$transition_path_file" "$transition_resolution"

	if [ "$OPT_JSON" -eq 1 ]; then
		# SYNTHESIZED — each individual transition POST in the walk
		# returns 204 No Content (nothing to pass through); this summarizes
		# the whole multi-step walk this script just performed.
		render_transition_summary_json "$TICKET_KEY" "$current_status" "$target_status" "$transition_path_file" "$transition_resolution" true
	else
		printf 'JIRA_TRANSITIONED_TO=%s\n' "$target_status"
	fi
}

# ---------------------------------------------------------------------------
# update — PUT /rest/api/3/issue/<KEY>
# ---------------------------------------------------------------------------

# build_appended_description TICKET_KEY APPEND_MARKDOWN_FILE -> prints the
# path to a NEW ADF file whose content is the issue's EXISTING description's
# content array with the newly-converted markdown's blocks appended after it
# (matches the oracle's fetch-existing -> extend -> replace-whole-doc
# behavior for --append-file).
build_appended_description() {
	append_ticket_key=$1
	append_markdown_file=$2
	append_media_map=${3:-}

	existing_desc_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${append_ticket_key}?fields=description"
	jira_curl GET "$existing_desc_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch existing description for $append_ticket_key"
	require_json_body "fetch existing description for $append_ticket_key"
	existing_description_file=$JIRA_HTTP_BODY_FILE

	appended_adf_file=$(convert_markdown_file_to_adf "$append_markdown_file" "$append_media_map")

	ensure_workdir
	APPEND_COUNTER=$((APPEND_COUNTER + 1))
	merged_description_file="$WORKDIR/appended-description-$APPEND_COUNTER.json"
	append_err_file="$WORKDIR/appended-description-$APPEND_COUNTER.err"
	# Guard: if the existing description's .content isn't an array (an
	# unexpected Jira response shape), `.content += [...]` would otherwise
	# fail OPAQUELY under set -e with a raw jq type error. jq's own error()
	# turns that into a clean, named failure this script reports itself.
	if ! jq -c --slurpfile new_content "$appended_adf_file" \
		'(.fields.description // {type: "doc", version: 1, content: []}) as $existing
		 | if ($existing.content | type) != "array" then
		     error("existing description.content is not an array")
		   else
		     $existing | .content += $new_content[0].content
		   end' \
		"$existing_description_file" >"$merged_description_file" 2>"$append_err_file"; then
		error "could not append to the existing description for $append_ticket_key: unexpected response shape"
		sed 's/^/  /' "$append_err_file" >&2 2>/dev/null || true
		exit 1
	fi
	printf '%s' "$merged_description_file"
}

cmd_update() {
	# TICKET_KEY presence, the --description-file/--append-file mutual
	# exclusivity, and "at least one field" are validated up front — see the
	# main dispatch section's per-command required-argument validation.
	PROJECT_CONFIG_FILE=""
	try_load_project_config "$(extract_project_from_key "$TICKET_KEY")"

	ensure_workdir
	update_fields_acc="$WORKDIR/update-fields.json"
	init_fields_accumulator "$update_fields_acc"

	[ -z "$OPT_TITLE" ] || merge_string_field "$update_fields_acc" summary "$OPT_TITLE"

	if [ -n "$OPT_APPEND_FILE" ]; then
		require_readable_file "$OPT_APPEND_FILE" "--append-file"
		# Inline images in the appended markdown are uploaded + resolved, then
		# their media blocks append into the built description.
		append_media_map=$(resolve_inline_images "$TICKET_KEY" "$OPT_APPEND_FILE")
		appended_description_file=$(build_appended_description "$TICKET_KEY" "$OPT_APPEND_FILE" "$append_media_map")
		merge_json_field "$update_fields_acc" description "$appended_description_file"
	elif [ -n "$OPT_DESCRIPTION_FILE" ]; then
		require_readable_file "$OPT_DESCRIPTION_FILE" "--description-file"
		description_media_map=$(resolve_inline_images "$TICKET_KEY" "$OPT_DESCRIPTION_FILE")
		description_adf_file=$(convert_markdown_file_to_adf "$OPT_DESCRIPTION_FILE" "$description_media_map")
		merge_json_field "$update_fields_acc" description "$description_adf_file"
	fi

	if [ -n "$OPT_ACCEPTANCE_FILE" ]; then
		# usage error (require_readable_file, exit 2) before the
		# precondition check (require_custom_field, exit 1) — same ordering
		# fix as cmd_create's identical pair.
		require_readable_file "$OPT_ACCEPTANCE_FILE" "--acceptance-file"
		acceptance_field_id=$(require_custom_field "$PROJECT_CONFIG_FILE" acceptance_criteria "--acceptance-file")
		acceptance_adf_file=$(convert_markdown_file_to_adf "$OPT_ACCEPTANCE_FILE")
		merge_json_field "$update_fields_acc" "$acceptance_field_id" "$acceptance_adf_file"
	fi

	if [ -n "$OPT_REVIEW_FILE" ]; then
		require_readable_file "$OPT_REVIEW_FILE" "--review-file"
		review_field_id=$(require_custom_field "$PROJECT_CONFIG_FILE" review_notes "--review-file")
		review_adf_file=$(convert_markdown_file_to_adf "$OPT_REVIEW_FILE")
		merge_json_field "$update_fields_acc" "$review_field_id" "$review_adf_file"
	fi

	if [ -n "$OPT_ASSIGNEE" ]; then
		assignee_account_id=$(resolve_account_id "$OPT_ASSIGNEE")
		merge_ref_field "$update_fields_acc" assignee id "$assignee_account_id"
	fi

	if [ -n "$OPT_DEVELOPER" ]; then
		developer_field_id=$(require_custom_field "$PROJECT_CONFIG_FILE" developer "--developer")
		developer_account_id=$(resolve_account_id "$OPT_DEVELOPER")
		merge_ref_field "$update_fields_acc" "$developer_field_id" accountId "$developer_account_id"
	fi

	if [ -n "$OPT_LABELS" ]; then
		# Data-loss surprise guard: REST v3's fields.labels REPLACES the
		# whole array (the correct semantics — see merge_labels_field's own
		# header note on why this deliberately diverges from the oracle's
		# ACLI-only partial "labelsToAdd"), so a caller updating one
		# unrelated field who also happens to pass --labels would otherwise
		# silently drop every existing label not repeated here.
		warn "--labels replaces ALL labels on $TICKET_KEY; existing labels not listed here will be removed"
		merge_labels_field "$update_fields_acc" "$OPT_LABELS"
	fi
	[ -z "$OPT_DUE_DATE" ] || merge_string_field "$update_fields_acc" duedate "$OPT_DUE_DATE"
	if [ -n "$OPT_PARENT" ]; then
		# --parent is a ticket-key reference; shape-validate it
		# the same as everywhere else a ticket key is used (this one never
		# reaches a URL — only a JSON value via merge_ref_field — but is
		# validated for consistency with create's identical flag, and to
		# reject a nonsensical value before spending a round-trip on it).
		validate_ticket_key "$OPT_PARENT" || { error "invalid parent ticket key: $OPT_PARENT"; exit 1; }
		merge_ref_field "$update_fields_acc" parent key "$OPT_PARENT"
	fi

	# Attach flags — same NAME -> id resolution as create, but the project is
	# derived from the ticket key being updated (TICKET_KEY is shape-validated
	# up front, so its extracted project prefix is a safe URL path segment).
	if [ -n "$OPT_FIX_VERSIONS" ] || [ -n "$OPT_AFFECTS_VERSIONS" ] || [ -n "$OPT_COMPONENTS" ]; then
		update_project=$(extract_project_from_key "$TICKET_KEY")
		merge_attach_flags "$update_fields_acc" "$update_project"
	fi

	update_request_file="$WORKDIR/update-request.json"
	jq -n --slurpfile fields "$update_fields_acc" '{fields: $fields[0]}' >"$update_request_file"

	update_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}"
	jira_curl PUT "$update_url" "$update_request_file"
	handle_http_status "$JIRA_HTTP_CODE" "update $TICKET_KEY"
	# PUT /issue returns 204 No Content on success — deliberately NO
	# require_json_body call here, same reasoning as execute_plain_transition.

	if [ "$OPT_JSON" -eq 1 ]; then
		# SYNTHESIZED, not passthrough — the PUT response has no
		# body (204) to pass through, so --json here summarizes the fields
		# THIS invocation just sent, not anything Jira returned.
		jq -n --slurpfile fields "$update_fields_acc" --arg key "$TICKET_KEY" \
			'{key: $key, updatedFields: ($fields[0] | keys)}'
	else
		printf 'JIRA_UPDATED=%s\n' "$TICKET_KEY"
	fi
}

# ---------------------------------------------------------------------------
# link — POST /rest/api/3/issueLink · link-types — GET /rest/api/3/issueLinkType
# ---------------------------------------------------------------------------

cmd_link() {
	# TICKET_KEY (FROM) / --to / --link-type presence & shape are validated
	# up front — see the main dispatch section's per-command validation.
	#
	# Direction (read this before touching this function): `link A --to B
	# --link-type "Blocks"` models "A blocks B". Jira's issueLinkType stores
	# an INWARD and an OUTWARD phrase per type (e.g. type "Blocks": outward
	# "blocks", inward "is blocked by"). VERIFIED LIVE against a real Jira
	# site (2026-07-25, PSWS-958/959): the issue placed in
	# inwardIssue is the one that exhibits the OUTWARD (active-voice) phrase.
	# So for "A blocks B", A (the active subject that "blocks") must be the
	# inwardIssue and B (which "is blocked by" A) must be the outwardIssue.
	# This is the REVERSE of the naive "outward phrase => outwardIssue"
	# reading, which shipped first and produced a backwards link — hence the
	# live check. Do NOT swap these back without re-verifying against Jira.
	#
	# ensure_workdir MUST run here, in the MAIN shell, before
	# convert_markdown_file_to_adf() below (reached only when --comment-file
	# is given) — that call reaches jira_curl() from INSIDE its own `$(...)`
	# command substitution, a subshell (the same class of leak already fixed
	# in cmd_comment; see that function's own comment for the full mechanism).
	ensure_workdir

	link_request_file="$WORKDIR/link-request.json"
	init_fields_accumulator "$link_request_file"
	merge_ref_field "$link_request_file" type name "$OPT_LINK_TYPE"
	# FROM -> inwardIssue, TO -> outwardIssue (verified live; see the
	# direction note above — inwardIssue exhibits the outward/active phrase).
	merge_ref_field "$link_request_file" inwardIssue key "$TICKET_KEY"
	merge_ref_field "$link_request_file" outwardIssue key "$OPT_TO"

	if [ -n "$OPT_COMMENT_FILE" ]; then
		require_readable_file "$OPT_COMMENT_FILE" "--comment-file"
		link_comment_adf_file=$(convert_markdown_file_to_adf "$OPT_COMMENT_FILE")
		link_comment_body_file="$WORKDIR/link-comment-body.json"
		jq -n --slurpfile body "$link_comment_adf_file" '{body: $body[0]}' >"$link_comment_body_file"
		merge_json_field "$link_request_file" comment "$link_comment_body_file"
	fi

	link_url="https://${CONFIRMED_HOST}/rest/api/3/issueLink"
	jira_curl POST "$link_url" "$link_request_file"
	handle_http_status "$JIRA_HTTP_CODE" "link $TICKET_KEY -> $OPT_TO ($OPT_LINK_TYPE)"
	# issueLink POST returns 201 Created with an EMPTY body — deliberately
	# NO require_json_body call here, same reasoning as execute_plain_transition.

	if [ "$OPT_JSON" -eq 1 ]; then
		# SYNTHESIZED, not passthrough — there is no response body
		# to pass through (see above); same reasoning as cmd_update's --json.
		jq -n --arg from "$TICKET_KEY" --arg to "$OPT_TO" --arg type "$OPT_LINK_TYPE" \
			'{from: $from, to: $to, type: $type}'
	else
		printf 'JIRA_LINKED=%s->%s (%s)\n' "$TICKET_KEY" "$OPT_TO" "$OPT_LINK_TYPE"
	fi
}

# render_link_types_human BODY_FILE — lists each link type's name plus its
# inward/outward wording, so a caller can discover valid --link-type values
# and confirm which end (inward/outward) reads which way before calling
# `link` for real.
render_link_types_human() {
	link_types_body_file=$1
	printf 'Available link types:\n'
	jq -r '.issueLinkTypes[] | "\(.name)\t\(.inward)\t\(.outward)"' "$link_types_body_file" \
		| while IFS="$(printf '\t')" read -r lt_name lt_inward lt_outward; do
			clean_lt_name=$(printf '%s' "$lt_name" | strip_control_ansi)
			clean_lt_inward=$(printf '%s' "$lt_inward" | strip_control_ansi)
			clean_lt_outward=$(printf '%s' "$lt_outward" | strip_control_ansi)
			printf '  %s\n    outward: %s\n    inward:  %s\n' "$clean_lt_name" "$clean_lt_outward" "$clean_lt_inward"
		done
}

cmd_link_types() {
	# No positional/required flags — validated up front (rejects a stray
	# positional the same way `search` does).
	link_types_url="https://${CONFIRMED_HOST}/rest/api/3/issueLinkType"
	jira_curl GET "$link_types_url"
	handle_http_status "$JIRA_HTTP_CODE" "list issue link types"
	require_json_body "list issue link types"

	if [ "$OPT_JSON" -eq 1 ]; then
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	render_link_types_human "$JIRA_HTTP_BODY_FILE"
}

# ---------------------------------------------------------------------------
# children <KEY> — an epic's/parent's children, via the EXISTING search
# engine (never a duplicated request/paging/render path)
# ---------------------------------------------------------------------------

cmd_children() {
	# TICKET_KEY presence/shape is validated up front — see cmd_view's note.
	#
	# `parent = "KEY"` is a BOUNDED query (never unfiltered), so — unlike a
	# raw --jql passthrough, which is the caller's own responsibility — no
	# fallback/guard against an unbounded read is needed here. The key is
	# escaped through jql_quoted() — the SAME JQL-sink control build_jql()
	# itself uses — even though TICKET_KEY is already
	# shape-validated to ^[A-Z][A-Z0-9]+-[0-9]+$ and therefore cannot carry a
	# quote/backslash; escaping it anyway costs nothing and keeps this call
	# site correct even if that upstream guarantee ever changes. Setting
	# $OPT_JQL and calling cmd_search() directly reuses its ENTIRE request
	# build / pagination / render / --json path verbatim (build_jql()'s raw
	# passthrough branch fires since $OPT_JQL is now non-empty) — respecting
	# whatever --fields/--limit/--page-size the caller also gave.
	OPT_JQL="parent = $(jql_quoted "$TICKET_KEY")"
	cmd_search
}

# ---------------------------------------------------------------------------
# discover <PROJECT> — introspect a project's issue types + create-screen
# fields and EMIT the project-config JSON this engine already consumes. A READ
# command (only GETs); see the header's "discover" note for the endpoints and
# the config shape. Uses the CURRENT split createmeta endpoints (the old
# combined `createmeta?projectKeys=...&expand=...` is removed in Jira Cloud).
# ---------------------------------------------------------------------------

# DISCOVER_PAGE_SIZE — Jira's per-request bean size for the createmeta
# endpoints (startAt/maxResults paging). 50 is Jira's own default page size.
DISCOVER_PAGE_SIZE=50

# fetch_paginated_values OUT_FILE URL_BASE ARRAY_KEY ACTION — pages the
# createmeta split endpoints, whose CURRENT Jira Cloud shape is a plain
# OFFSET-paginated bean: `{ "<ARRAY_KEY>": [ ... ], "startAt": N,
# "maxResults": M, "total": T }`. ARRAY_KEY is the page's array field —
# "issueTypes" for the issuetypes call, "fields" for the per-type call — NOT
# ".values" (that key does not exist on these endpoints; reading it returned
# an EMPTY config against real Jira). There is NO "isLast" field here, so
# pagination is by OFFSET: start at 0, GET a page, append it, advance startAt
# by the number of rows returned, and STOP when a page comes back empty (the
# infinite-loop guard) OR startAt has reached `total`. Each row is appended to
# OUT_FILE as one compact JSON object per line; OUT_FILE is never truncated
# (the caller resets it with `: >file` before the first call), so several
# types' field pages accumulate into one aggregate file.
fetch_paginated_values() {
	fpv_out_file=$1
	fpv_url_base=$2
	fpv_array_key=$3
	fpv_action=$4
	fpv_start=0
	while :; do
		case "$fpv_url_base" in
			*\?*) fpv_sep='&' ;;
			*)    fpv_sep='?' ;;
		esac
		fpv_url="${fpv_url_base}${fpv_sep}startAt=${fpv_start}&maxResults=${DISCOVER_PAGE_SIZE}"
		jira_curl GET "$fpv_url"
		handle_http_status "$JIRA_HTTP_CODE" "$fpv_action"
		require_json_body "$fpv_action"
		jq -c --arg k "$fpv_array_key" '.[$k][]?' "$JIRA_HTTP_BODY_FILE" >>"$fpv_out_file"
		fpv_page_count=$(jq --arg k "$fpv_array_key" '(.[$k] // []) | length' "$JIRA_HTTP_BODY_FILE")
		fpv_total=$(jq '.total // 0' "$JIRA_HTTP_BODY_FILE")
		fpv_start=$((fpv_start + fpv_page_count))
		# Stop on an empty page (guards against a missing/short `total`) OR once
		# startAt has caught up to the reported total (all rows collected).
		if [ "$fpv_page_count" -eq 0 ] || [ "$fpv_start" -ge "$fpv_total" ]; then
			break
		fi
	done
}

# DISCOVER_CUSTOM_ENTRIES_PROGRAM — a single STATIC jq program (never built
# from data) that derives the deduped-by-id custom-field (id, name) entries
# ONCE, so both the config assembler AND the duplicate-name detector consume
# the SAME derivation (no drift). $fields is the array of createmeta value
# objects; $catalog is [<the /field array>], so $catalog[0] is that array.
# Every field name/id enters ONLY as one of these slurped values — never as
# program text — so an injection-shaped field name stays inert data. A field is
# "custom" when its schema.custom is set OR its fieldId starts with
# "customfield_"; its display NAME is taken from the /field catalog
# (authoritative), falling back to the createmeta name. Output: an array of
# {id, name}, one per distinct custom field id.
# shellcheck disable=SC2016  # single-quoted on purpose: $fields/$catalog below are jq syntax, not shell expansions
DISCOVER_CUSTOM_ENTRIES_PROGRAM='
($catalog[0] // [])
  | map(select(.id != null))
  | map({key: .id, value: (.name // .id)})
  | from_entries
  as $id_to_name
| $fields
  | map(select(((.schema.custom // null) != null)
               or (((.fieldId // "") | startswith("customfield_")))))
  | map({id: (.fieldId // ""), name: (($id_to_name[.fieldId]) // .name // .fieldId)})
  | map(select((.id | length) > 0))
  | unique_by(.id)
'

# DISCOVER_COLLISIONS_PROGRAM — the flat custom_fields name->id map can
# hold only ONE id per display name, so two distinct ids sharing a name would
# collapse (last-wins) silently. Given the {id,name} entries array, this emits
# a readable "<name> -> [id, id]" line per colliding name (empty when none), so
# discover can WARN which mapping was dropped rather than hide the collision.
# shellcheck disable=SC2016  # single-quoted on purpose: the jq body below is jq syntax, not shell expansions
DISCOVER_COLLISIONS_PROGRAM='
group_by(.name)
| map(select(length > 1))
| map("\"" + .[0].name + "\" -> [" + ([.[].id] | join(", ")) + "]")
| join("; ")
'

# DISCOVER_CONFIG_PROGRAM — assembles the consumed config shape from the
# pre-derived custom-field $entries (see above) and the $types array. $entries
# is [<the entries array>], so $entries[0] is that array.
# type_aliases/subtask_parent_types/workflows are emitted as EMPTY slots the
# human fills — the API cannot infer them (see the header note); custom_fields
# IS populated (keyed by display name).
# shellcheck disable=SC2016  # single-quoted on purpose: $entries/$types below are jq syntax, not shell expansions
DISCOVER_CONFIG_PROGRAM='
{
  custom_fields: ($entries[0] | map({key: .name, value: .id}) | from_entries),
  type_aliases: {},
  issue_types: ($types | map(.name // empty) | unique),
  subtask_types: ($types | map(select(.subtask == true) | .name // empty) | unique),
  subtask_parent_types: [],
  workflows: {}
}
'

# DISCOVER_MERGE_PROGRAM — fold a freshly-DISCOVERED config into a
# human-CURATED existing one without clobbering curation. $existing/$discovered
# are each [<the config object>]. Rules: REPLACE issue_types/subtask_types with
# the discovered facts; MERGE custom_fields (existing first, then discovered
# display-name entries add/refresh — preserving human-added semantic keys like
# acceptance_criteria/review_notes/developer); PRESERVE the existing
# type_aliases/subtask_parent_types/workflows (discovery emits these empty, so
# `//` keeps a present existing value — even an empty one — over the discovered
# empty). Starting from `$old + {...}` also preserves any EXTRA keys a human
# added (e.g. a "key" field) that discovery does not model.
# shellcheck disable=SC2016  # single-quoted on purpose: $existing/$discovered below are jq syntax, not shell expansions
DISCOVER_MERGE_PROGRAM='
$existing[0] as $old
| $discovered[0] as $new
| $old + {
    custom_fields: (($old.custom_fields // {}) + ($new.custom_fields // {})),
    type_aliases: ($old.type_aliases // $new.type_aliases),
    issue_types: $new.issue_types,
    subtask_types: $new.subtask_types,
    subtask_parent_types: ($old.subtask_parent_types // $new.subtask_parent_types),
    workflows: ($old.workflows // $new.workflows)
  }
'

# atomic_install SRC DEST — install SRC at DEST atomically: copy SRC to an
# mktemp sibling in DEST's OWN directory (same filesystem, so `mv` is an atomic
# rename) then rename it into place. An interrupted write can never leave a
# truncated/partial DEST — a reader sees either the old file or the whole new
# one, never a half-written config. DEST's directory must already exist (the
# caller mkdir -p's the projects dir first).
atomic_install() {
	ai_src=$1
	ai_dest=$2
	ai_tmp=$(mktemp "${ai_dest}.tmp.XXXXXX")
	cp "$ai_src" "$ai_tmp"
	mv "$ai_tmp" "$ai_dest"
}

# save_discovered_config CONFIG_FILE — persist the discovered
# CONFIG_FILE to $JIRA_PROJECTS_DIR/<discover_project>.json without CLOBBERING
# human curation. A fresh target is written as-is (created). An existing target
# is BACKED UP to a timestamped sibling FIRST, then: --force writes the pure
# discovered config (replaced); a valid existing file is MERGED (merged, via
# DISCOVER_MERGE_PROGRAM); an invalid/unreadable existing file is replaced with
# a fresh config plus a stderr WARNING. Every write into place goes through
# atomic_install (no truncated config on interrupt). Prints the machine line
# naming the outcome + any backup path. Uses
# $discover_project/$JIRA_PROJECTS_DIR/$OPT_FORCE globals (the script's
# plain-globals convention).
save_discovered_config() {
	sdc_config_file=$1
	[ -d "$JIRA_PROJECTS_DIR" ] || mkdir -p "$JIRA_PROJECTS_DIR"
	# discover_project is [A-Z0-9]+ (validated in cmd_discover), so
	# this join cannot contain a '/' or '..' — the path stays pinned under
	# $JIRA_PROJECTS_DIR, the SAME guarantee try_load_project_config relies on.
	sdc_out_path="$JIRA_PROJECTS_DIR/${discover_project}.json"

	if [ ! -f "$sdc_out_path" ]; then
		atomic_install "$sdc_config_file" "$sdc_out_path"
		printf 'JIRA_DISCOVERED=%s -> %s (created)\n' "$discover_project" "$sdc_out_path"
		return 0
	fi

	# Existing file: back it up before touching it, whichever branch follows.
	# the backup name is uniquified via mktemp (not a bare
	# .bak-<UTC>) so two --write runs in the SAME UTC second get DISTINCT
	# backups — mktemp both guarantees a fresh name (never overwriting an
	# existing backup) and creates it atomically. cp then fills it with the
	# pristine original.
	sdc_backup_path=$(mktemp "${sdc_out_path}.bak-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
	cp "$sdc_out_path" "$sdc_backup_path"

	if [ "$OPT_FORCE" -eq 1 ]; then
		atomic_install "$sdc_config_file" "$sdc_out_path"
		printf 'JIRA_DISCOVERED=%s -> %s (replaced; backup %s)\n' "$discover_project" "$sdc_out_path" "$sdc_backup_path"
		return 0
	fi

	if jq -e . "$sdc_backup_path" >/dev/null 2>&1; then
		# MERGE from the pristine backup (never read-then-write the same path):
		# both inputs enter jq only via --slurpfile, no value concatenated in.
		ensure_workdir
		sdc_merged_file="$WORKDIR/discover-merged.json"
		jq -n \
			--slurpfile existing "$sdc_backup_path" \
			--slurpfile discovered "$sdc_config_file" \
			"$DISCOVER_MERGE_PROGRAM" >"$sdc_merged_file"
		atomic_install "$sdc_merged_file" "$sdc_out_path"
		printf 'JIRA_DISCOVERED=%s -> %s (merged; backup %s)\n' "$discover_project" "$sdc_out_path" "$sdc_backup_path"
		return 0
	fi

	warn "existing $sdc_out_path is not valid JSON — backed it up and wrote a fresh discovered config (curated slots will be empty)"
	atomic_install "$sdc_config_file" "$sdc_out_path"
	printf 'JIRA_DISCOVERED=%s -> %s (replaced; backup %s)\n' "$discover_project" "$sdc_out_path" "$sdc_backup_path"
}

cmd_discover() {
	# The PROJECT positional presence/shape is validated up front — see the
	# main dispatch section's per-command validation (validate_project_key,
	# which rejects a traversal-shaped value like "../../x" with exit 2 before
	# any network or filesystem access).
	#
	# ensure_workdir runs FIRST, unconditionally — fetch_paginated_values and
	# the field-catalog GET below both reach jira_curl(), and the per-type
	# field loop calls fetch_paginated_values from a redirection-fed loop in
	# THIS shell (never a `cmd | while` subshell), so RESP_COUNTER and WORKDIR
	# stay coherent (the discipline the other commands establish).
	ensure_workdir

	discover_project=$TICKET_KEY
	# Defense-in-depth at the sink: the positional already passed
	# validate_project_key (^[A-Z][A-Z0-9]+$) at the dispatch stage, so it
	# holds only A-Z0-9 — no '/', '.', or newline that could retarget the
	# createmeta URL path or (on --write) escape the projects dir. Re-checked
	# here with an opaque whole-string case guard (the same "re-check at the
	# actual sink" posture try_load_project_config takes for its file-path
	# build), which — unlike grep's line-anchored ^/$ — also rejects an
	# embedded newline.
	case "$discover_project" in
		''|*[!A-Z0-9]*) error "invalid project key: $discover_project"; exit 1 ;;
	esac

	# 1. The project's issue types (the page array is under `issueTypes`,
	#    OFFSET-paginated).
	discover_types_jsonl="$WORKDIR/discover-types.jsonl"
	: >"$discover_types_jsonl"
	discover_issuetypes_url="https://${CONFIRMED_HOST}/rest/api/3/issue/createmeta/${discover_project}/issuetypes"
	fetch_paginated_values "$discover_types_jsonl" "$discover_issuetypes_url" issueTypes \
		"discover issue types for $discover_project"

	# 2. Each issue type's create-screen fields (the page array is under
	#    `fields`, OFFSET-paginated — `total` can exceed one page), accumulated
	#    into ONE aggregate JSONL. The loop reads type ids via redirection (not
	#    a pipe) so it runs in THIS shell — matching walk_transition_path's idiom.
	discover_fields_jsonl="$WORKDIR/discover-fields.jsonl"
	: >"$discover_fields_jsonl"
	discover_type_ids_file="$WORKDIR/discover-type-ids.txt"
	jq -r '.id // empty' "$discover_types_jsonl" >"$discover_type_ids_file"
	while IFS= read -r discover_type_id; do
		[ -n "$discover_type_id" ] || continue
		# A createmeta issue-type id is Jira-issued and numeric; it becomes a
		# URL path segment, so reject any non-digit shape up front
		# (defense-in-depth) rather than trusting the value blindly.
		case "$discover_type_id" in
			*[!0-9]*) warn "skipping issue type with an unexpected id shape: $discover_type_id"; continue ;;
		esac
		discover_type_fields_url="https://${CONFIRMED_HOST}/rest/api/3/issue/createmeta/${discover_project}/issuetypes/${discover_type_id}"
		fetch_paginated_values "$discover_fields_jsonl" "$discover_type_fields_url" fields \
			"discover fields for issue type $discover_type_id in $discover_project"
	done <"$discover_type_ids_file"

	# 3. The global field catalog — a plain JSON ARRAY, NOT a paginated bean,
	#    so it is fetched with a single GET (no fetch_paginated_values).
	discover_catalog_file="$WORKDIR/discover-field-catalog.json"
	discover_field_catalog_url="https://${CONFIRMED_HOST}/rest/api/3/field"
	jira_curl GET "$discover_field_catalog_url"
	handle_http_status "$JIRA_HTTP_CODE" "discover the global field catalog"
	require_json_body "discover the global field catalog"
	cp "$JIRA_HTTP_BODY_FILE" "$discover_catalog_file"

	# 4a. Derive the deduped-by-id custom-field (id, name) entries ONCE, so the
	#     config assembler and the collision detector share one derivation.
	discover_custom_entries_file="$WORKDIR/discover-custom-entries.json"
	jq -n \
		--slurpfile fields "$discover_fields_jsonl" \
		--slurpfile catalog "$discover_catalog_file" \
		"$DISCOVER_CUSTOM_ENTRIES_PROGRAM" >"$discover_custom_entries_file"

	# 4b. Warn (to stderr) on any display NAME shared by two distinct
	#     field ids — the flat name->id map keeps only one, so surface which was
	#     dropped. The collision string is API-authored text, so it passes
	#     through strip_control_ansi before it reaches the diagnostic.
	discover_name_collisions=$(jq -r "$DISCOVER_COLLISIONS_PROGRAM" "$discover_custom_entries_file" | strip_control_ansi)
	[ -z "$discover_name_collisions" ] || \
		warn "duplicate custom-field display name(s) — only one id kept per name in custom_fields: $discover_name_collisions"

	# 4c. Assemble the config from the pre-derived entries + the issue types.
	discover_config_file="$WORKDIR/discover-config.json"
	jq -n \
		--slurpfile types "$discover_types_jsonl" \
		--slurpfile entries "$discover_custom_entries_file" \
		"$DISCOVER_CONFIG_PROGRAM" >"$discover_config_file"

	if [ "$OPT_WRITE" -eq 1 ]; then
		save_discovered_config "$discover_config_file"
	else
		cat "$discover_config_file"
	fi
}

# ---------------------------------------------------------------------------
# worklog <KEY> — POST /rest/api/3/issue/<KEY>/worklog
# ---------------------------------------------------------------------------

cmd_worklog() {
	# TICKET_KEY/--time-spent presence is validated up front — see the main
	# dispatch section's per-command required-argument validation.
	#
	# ensure_workdir MUST run here, in the MAIN shell, before
	# convert_markdown_file_to_adf() below (reached only when --comment-file
	# is given) — same subshell-WORKDIR-loss class already fixed in
	# cmd_comment; see that function's own comment for the full mechanism.
	ensure_workdir

	# The request body has NO fields{} wrapper (unlike create/update) — the
	# accumulator built by init_fields_accumulator()/merge_*_field() IS the
	# whole request body, sent to jira_curl as-is.
	worklog_request_file="$WORKDIR/worklog-request.json"
	init_fields_accumulator "$worklog_request_file"
	merge_string_field "$worklog_request_file" timeSpent "$OPT_TIME_SPENT"

	if [ -n "$OPT_COMMENT_FILE" ]; then
		require_readable_file "$OPT_COMMENT_FILE" "--comment-file"
		worklog_comment_adf_file=$(convert_markdown_file_to_adf "$OPT_COMMENT_FILE")
		merge_json_field "$worklog_request_file" comment "$worklog_comment_adf_file"
	fi

	[ -z "$OPT_STARTED" ] || merge_string_field "$worklog_request_file" started "$OPT_STARTED"

	worklog_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/worklog"
	jira_curl POST "$worklog_url" "$worklog_request_file"
	handle_http_status "$JIRA_HTTP_CODE" "log work on $TICKET_KEY"
	require_json_body "log work on $TICKET_KEY"

	if [ "$OPT_JSON" -eq 1 ]; then
		# PASSTHROUGH — Jira's own 201 response body (the created
		# worklog entry) IS the answer, same reasoning as cmd_create/cmd_comment.
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	printf 'JIRA_WORKLOGGED=%s (%s)\n' "$TICKET_KEY" "$OPT_TIME_SPENT"
}

# ---------------------------------------------------------------------------
# watch <KEY> — POST/DELETE/GET /rest/api/3/issue/<KEY>/watchers
# vote <KEY>  — POST/DELETE/GET /rest/api/3/issue/<KEY>/votes
# ---------------------------------------------------------------------------

# render_watchers_human BODY_FILE — watch count + each watcher's display name.
render_watchers_human() {
	watchers_body_file=$1
	watcher_count=$(jq -r '.watchCount // 0' "$watchers_body_file")
	printf 'Watchers: %s\n' "$watcher_count"
	jq -r '.watchers[]?.displayName // "Unknown"' "$watchers_body_file" | while IFS= read -r watcher_name; do
		clean_watcher_name=$(printf '%s' "$watcher_name" | strip_control_ansi)
		printf '  - %s\n' "$clean_watcher_name"
	done
}

cmd_watch() {
	# TICKET_KEY presence/shape, and the --list/--remove/--account
	# combinations, are validated up front — see the main dispatch section's
	# per-command validation.
	#
	# ensure_workdir runs FIRST, unconditionally — the add/remove branches
	# below reach resolve_account_id() from INSIDE a `$(...)` command
	# substitution, which is a SUBSHELL (the same WORKDIR-loss class already
	# fixed in cmd_search/cmd_create/cmd_comment/cmd_transition; see
	# cmd_search's own comment for the full mechanism) — calling it here
	# first means resolve_account_id -> jira_curl's own ensure_workdir call
	# is a no-op, inherited from the already-tracked WORKDIR.
	ensure_workdir

	if [ "$OPT_LIST" -eq 1 ]; then
		watchers_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/watchers"
		jira_curl GET "$watchers_url"
		handle_http_status "$JIRA_HTTP_CODE" "list watchers for $TICKET_KEY"
		require_json_body "list watchers for $TICKET_KEY"
		if [ "$OPT_JSON" -eq 1 ]; then
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		render_watchers_human "$JIRA_HTTP_BODY_FILE"
		return 0
	fi

	# "me"/"@me" (the default when --account is omitted) resolves via
	# GET /myself; anything else resolves via GET /user/search — the SAME
	# resolve_account_id() the READ path's search --assignee and the WRITE
	# path's create/update --assignee/--developer already use.
	watch_target=${OPT_ACCOUNT:-@me}
	watch_account_id=$(resolve_account_id "$watch_target")

	if [ "$OPT_REMOVE" -eq 1 ]; then
		# the resolved accountId (never the caller's raw --account
		# value) is urlencode()'d into the query string — the SAME helper
		# view/search already use for ?fields=/?query=.
		encoded_watch_account_id=$(urlencode "$watch_account_id")
		remove_watcher_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/watchers?accountId=${encoded_watch_account_id}"
		jira_curl DELETE "$remove_watcher_url"
		handle_http_status "$JIRA_HTTP_CODE" "remove watcher from $TICKET_KEY"
		# DELETE /watchers returns 204 No Content — no require_json_body call.
		if [ "$OPT_JSON" -eq 1 ]; then
			jq -n --arg key "$TICKET_KEY" --arg accountId "$watch_account_id" \
				'{key: $key, accountId: $accountId, watching: false}'
		else
			printf 'JIRA_UNWATCHED=%s\n' "$TICKET_KEY"
		fi
		return 0
	fi

	# Add: the request body is the BARE accountId as a JSON string (per
	# Jira's own /watchers contract) — built via a single static jq -n
	# program fed via --arg, never string-concatenated.
	watch_request_file="$WORKDIR/watch-request.json"
	jq -n --arg id "$watch_account_id" '$id' >"$watch_request_file"
	add_watcher_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/watchers"
	jira_curl POST "$add_watcher_url" "$watch_request_file"
	handle_http_status "$JIRA_HTTP_CODE" "add watcher to $TICKET_KEY"
	# POST /watchers returns 204 No Content — no require_json_body call.
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -n --arg key "$TICKET_KEY" --arg accountId "$watch_account_id" \
			'{key: $key, accountId: $accountId, watching: true}'
	else
		printf 'JIRA_WATCHED=%s\n' "$TICKET_KEY"
	fi
}

# render_votes_human BODY_FILE — vote count + whether the caller has voted.
render_votes_human() {
	votes_body_file=$1
	vote_count=$(jq -r '.votes // 0' "$votes_body_file")
	has_voted=$(jq -r '.hasVoted // false' "$votes_body_file")
	printf 'Votes: %s\n' "$vote_count"
	printf 'You have voted: %s\n' "$has_voted"
}

cmd_vote() {
	# TICKET_KEY presence/shape, and the --list/--remove mutual exclusivity,
	# are validated up front — see the main dispatch section's per-command
	# validation.
	if [ "$OPT_LIST" -eq 1 ]; then
		votes_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/votes"
		jira_curl GET "$votes_url"
		handle_http_status "$JIRA_HTTP_CODE" "list votes for $TICKET_KEY"
		require_json_body "list votes for $TICKET_KEY"
		if [ "$OPT_JSON" -eq 1 ]; then
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		render_votes_human "$JIRA_HTTP_BODY_FILE"
		return 0
	fi

	if [ "$OPT_REMOVE" -eq 1 ]; then
		remove_vote_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/votes"
		jira_curl DELETE "$remove_vote_url"
		handle_http_status "$JIRA_HTTP_CODE" "remove vote from $TICKET_KEY"
		# DELETE /votes returns 204 No Content — no require_json_body call.
		if [ "$OPT_JSON" -eq 1 ]; then
			jq -n --arg key "$TICKET_KEY" '{key: $key, voted: false}'
		else
			printf 'JIRA_UNVOTED=%s\n' "$TICKET_KEY"
		fi
		return 0
	fi

	add_vote_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/votes"
	jira_curl POST "$add_vote_url"
	handle_http_status "$JIRA_HTTP_CODE" "add vote to $TICKET_KEY"
	# POST /votes returns 204 No Content — no require_json_body call.
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -n --arg key "$TICKET_KEY" '{key: $key, voted: true}'
	else
		printf 'JIRA_VOTED=%s\n' "$TICKET_KEY"
	fi
}

# ---------------------------------------------------------------------------
# version — project versions/releases (POST/PUT /rest/api/3/version,
# GET /rest/api/3/project/<KEY>/versions). Mode selected by exactly ONE of
# --list/--create/--update/--release/--archive (validated up front).
# ---------------------------------------------------------------------------

# render_versions_human BODY_FILE — one line per version. BODY is a PLAIN JSON
# ARRAY (NOT a paginated {values:[...]} envelope) — verified against live Jira.
render_versions_human() {
	versions_body_file=$1
	version_count=$(jq 'length' "$versions_body_file")
	if [ "$version_count" -eq 0 ]; then
		printf 'No versions.\n'
		return 0
	fi
	printf 'Versions:\n'
	# Emit ONE compact JSON object per line (jq -c escapes any tab or newline
	# inside a version NAME as \t/\n, so a name authored by another Jira user
	# can never split a row or misalign a column) and extract each field
	# INDEPENDENTLY with jq — the same delimiter-injection-proof idiom
	# render_search_human uses. A plain `IFS=<tab> read` split would be unsafe:
	# strip_control_ansi runs AFTER the split and removes neither tab (\011)
	# nor newline (\012), so a name carrying either byte would break parsing.
	jq -c '.[]' "$versions_body_file" | while IFS= read -r version_line; do
		v_name=$(printf '%s' "$version_line" | jq -r '.name // ""' | strip_control_ansi)
		v_id=$(printf '%s' "$version_line" | jq -r '.id // ""' | strip_control_ansi)
		v_released=$(printf '%s' "$version_line" | jq -r '.released // false' | strip_control_ansi)
		printf '  %s (id %s, released %s)\n' "$v_name" "$v_id" "$v_released"
	done
}

# build_version_write_body OUT_FILE — builds the FLAT /version body for the
# active mode (create vs update/release/archive) into OUT_FILE. `project` is
# the project KEY STRING (verified live: a numeric projectId is REJECTED — the
# API reads only the `project` key field). Every value enters jq via
# --arg/--argjson in a static merge program; nothing is concatenated.
build_version_write_body() {
	bvw_out_file=$1
	init_fields_accumulator "$bvw_out_file"
	if [ "$OPT_CREATE" -eq 1 ]; then
		merge_string_field "$bvw_out_file" project "$OPT_PROJECT"
		merge_string_field "$bvw_out_file" name "$OPT_NAME"
		[ -z "$OPT_DESCRIPTION" ]  || merge_string_field "$bvw_out_file" description "$OPT_DESCRIPTION"
		[ -z "$OPT_RELEASE_DATE" ] || merge_string_field "$bvw_out_file" releaseDate "$OPT_RELEASE_DATE"
		[ -z "$OPT_START_DATE" ]   || merge_string_field "$bvw_out_file" startDate "$OPT_START_DATE"
		if [ "$OPT_RELEASED" -eq 1 ]; then merge_bool_field "$bvw_out_file" released true; fi
	elif [ "$OPT_UPDATE" -eq 1 ]; then
		[ -z "$OPT_NAME" ]         || merge_string_field "$bvw_out_file" name "$OPT_NAME"
		[ -z "$OPT_DESCRIPTION" ]  || merge_string_field "$bvw_out_file" description "$OPT_DESCRIPTION"
		[ -z "$OPT_RELEASE_DATE" ] || merge_string_field "$bvw_out_file" releaseDate "$OPT_RELEASE_DATE"
		[ -z "$OPT_START_DATE" ]   || merge_string_field "$bvw_out_file" startDate "$OPT_START_DATE"
	elif [ "$OPT_RELEASE" -eq 1 ]; then
		merge_bool_field "$bvw_out_file" released true
		[ -z "$OPT_RELEASE_DATE" ] || merge_string_field "$bvw_out_file" releaseDate "$OPT_RELEASE_DATE"
	elif [ "$OPT_ARCHIVE" -eq 1 ]; then
		merge_bool_field "$bvw_out_file" archived true
	fi
}

cmd_version() {
	# Mode (exactly one of --list/--create/--update/--release/--archive),
	# --project/--name presence, --id numeric shape, and "update needs a field"
	# are validated up front — see the main dispatch section's per-command block.
	ensure_workdir

	if [ "$OPT_LIST" -eq 1 ]; then
		versions_url="https://${CONFIRMED_HOST}/rest/api/3/project/${OPT_PROJECT}/versions"
		jira_curl GET "$versions_url"
		handle_http_status "$JIRA_HTTP_CODE" "list versions for $OPT_PROJECT"
		require_json_body "list versions for $OPT_PROJECT"
		if [ "$OPT_JSON" -eq 1 ]; then
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		render_versions_human "$JIRA_HTTP_BODY_FILE"
		return 0
	fi

	if [ "$OPT_CREATE" -eq 1 ]; then
		version_create_body="$WORKDIR/version-create.json"
		build_version_write_body "$version_create_body"
		create_version_url="https://${CONFIRMED_HOST}/rest/api/3/version"
		jira_curl POST "$create_version_url" "$version_create_body"
		handle_http_status "$JIRA_HTTP_CODE" "create version"
		require_json_body "create version"
		if [ "$OPT_JSON" -eq 1 ]; then
			# PASSTHROUGH — Jira's 201 body (id/name/released/...) IS the answer.
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		created_version_id=$(jq -r '.id // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
		created_version_name=$(jq -r '.name // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
		printf 'JIRA_VERSION_ID=%s\n' "$created_version_id"
		printf 'JIRA_VERSION_NAME=%s\n' "$created_version_name"
		return 0
	fi

	# update / release / archive all PUT /version/<id> with a partial body.
	# OPT_ID is numeric-validated up front before it reaches this URL segment.
	version_put_body="$WORKDIR/version-put.json"
	build_version_write_body "$version_put_body"
	version_put_url="https://${CONFIRMED_HOST}/rest/api/3/version/${OPT_ID}"
	jira_curl PUT "$version_put_url" "$version_put_body"
	handle_http_status "$JIRA_HTTP_CODE" "update version $OPT_ID"
	require_json_body "update version $OPT_ID"
	if [ "$OPT_JSON" -eq 1 ]; then
		# PASSTHROUGH — PUT /version returns 200 with the updated version object.
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	put_version_id=$(jq -r '.id // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
	put_version_name=$(jq -r '.name // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
	printf 'JIRA_VERSION_ID=%s\n' "$put_version_id"
	printf 'JIRA_VERSION_NAME=%s\n' "$put_version_name"
}

# ---------------------------------------------------------------------------
# component — project components (POST/PUT/DELETE /rest/api/3/component,
# GET /rest/api/3/project/<KEY>/components). Mode selected by exactly ONE of
# --list/--create/--update/--delete (validated up front).
# ---------------------------------------------------------------------------

# render_components_human BODY_FILE — one line per component. BODY is a PLAIN
# JSON ARRAY (empty `[]` is valid) — verified against live Jira.
render_components_human() {
	components_body_file=$1
	component_count=$(jq 'length' "$components_body_file")
	if [ "$component_count" -eq 0 ]; then
		printf 'No components.\n'
		return 0
	fi
	printf 'Components:\n'
	# Same delimiter-injection-proof idiom as render_versions_human /
	# render_search_human — one compact JSON object per line, each field
	# extracted independently by jq, never an IFS=<tab> split that a name
	# carrying a literal tab/newline would break (strip_control_ansi strips
	# neither byte).
	jq -c '.[]' "$components_body_file" | while IFS= read -r component_line; do
		c_name=$(printf '%s' "$component_line" | jq -r '.name // ""' | strip_control_ansi)
		c_id=$(printf '%s' "$component_line" | jq -r '.id // ""' | strip_control_ansi)
		printf '  %s (id %s)\n' "$c_name" "$c_id"
	done
}

cmd_component() {
	# Mode (exactly one of --list/--create/--update/--delete), --project/--name
	# presence, --id / --move-issues-to numeric shape, and "--move-issues-to
	# only with --delete" are validated up front — see the per-command block.
	ensure_workdir

	if [ "$OPT_LIST" -eq 1 ]; then
		components_url="https://${CONFIRMED_HOST}/rest/api/3/project/${OPT_PROJECT}/components"
		jira_curl GET "$components_url"
		handle_http_status "$JIRA_HTTP_CODE" "list components for $OPT_PROJECT"
		require_json_body "list components for $OPT_PROJECT"
		if [ "$OPT_JSON" -eq 1 ]; then
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		render_components_human "$JIRA_HTTP_BODY_FILE"
		return 0
	fi

	if [ "$OPT_CREATE" -eq 1 ]; then
		component_create_body="$WORKDIR/component-create.json"
		init_fields_accumulator "$component_create_body"
		merge_string_field "$component_create_body" project "$OPT_PROJECT"
		merge_string_field "$component_create_body" name "$OPT_NAME"
		[ -z "$OPT_DESCRIPTION" ]     || merge_string_field "$component_create_body" description "$OPT_DESCRIPTION"
		[ -z "$OPT_LEAD_ACCOUNT_ID" ] || merge_string_field "$component_create_body" leadAccountId "$OPT_LEAD_ACCOUNT_ID"
		create_component_url="https://${CONFIRMED_HOST}/rest/api/3/component"
		jira_curl POST "$create_component_url" "$component_create_body"
		handle_http_status "$JIRA_HTTP_CODE" "create component"
		require_json_body "create component"
		if [ "$OPT_JSON" -eq 1 ]; then
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		created_component_id=$(jq -r '.id // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
		created_component_name=$(jq -r '.name // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
		printf 'JIRA_COMPONENT_ID=%s\n' "$created_component_id"
		printf 'JIRA_COMPONENT_NAME=%s\n' "$created_component_name"
		return 0
	fi

	if [ "$OPT_UPDATE" -eq 1 ]; then
		component_update_body="$WORKDIR/component-update.json"
		init_fields_accumulator "$component_update_body"
		[ -z "$OPT_NAME" ]            || merge_string_field "$component_update_body" name "$OPT_NAME"
		[ -z "$OPT_DESCRIPTION" ]     || merge_string_field "$component_update_body" description "$OPT_DESCRIPTION"
		[ -z "$OPT_LEAD_ACCOUNT_ID" ] || merge_string_field "$component_update_body" leadAccountId "$OPT_LEAD_ACCOUNT_ID"
		update_component_url="https://${CONFIRMED_HOST}/rest/api/3/component/${OPT_ID}"
		jira_curl PUT "$update_component_url" "$component_update_body"
		handle_http_status "$JIRA_HTTP_CODE" "update component $OPT_ID"
		require_json_body "update component $OPT_ID"
		if [ "$OPT_JSON" -eq 1 ]; then
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		updated_component_id=$(jq -r '.id // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
		updated_component_name=$(jq -r '.name // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
		printf 'JIRA_COMPONENT_ID=%s\n' "$updated_component_id"
		printf 'JIRA_COMPONENT_NAME=%s\n' "$updated_component_name"
		return 0
	fi

	# delete — DELETE /component/<id> with an OPTIONAL ?moveIssuesTo=<id2> to
	# reassign the component's issues. Both ids are numeric-validated up front;
	# moveIssuesTo is urlencode()'d into the query the same way watch --remove
	# encodes its accountId (belt-and-braces even for a digits-only value).
	delete_component_url="https://${CONFIRMED_HOST}/rest/api/3/component/${OPT_ID}"
	if [ -n "$OPT_MOVE_ISSUES_TO" ]; then
		encoded_move_target=$(urlencode "$OPT_MOVE_ISSUES_TO")
		delete_component_url="${delete_component_url}?moveIssuesTo=${encoded_move_target}"
	fi
	jira_curl DELETE "$delete_component_url"
	handle_http_status "$JIRA_HTTP_CODE" "delete component $OPT_ID"
	# DELETE /component returns 204 No Content — no require_json_body call.
	if [ "$OPT_JSON" -eq 1 ]; then
		# SYNTHESIZED — no 204 body to pass through (same as cmd_update's --json).
		jq -n --arg id "$OPT_ID" '{id: $id, deleted: true}'
	else
		printf 'JIRA_COMPONENT_DELETED=%s\n' "$OPT_ID"
	fi
}

# ---------------------------------------------------------------------------
# attach — issue attachments (POST /issue/<KEY>/attachments multipart upload,
# GET /issue/<KEY>?fields=attachment list, DELETE /attachment/<id>). Mode
# selected by exactly ONE of: --file present (upload) / --list / --delete
# (validated up front). Upload/list take the positional KEY; --delete takes
# --id only.
# ---------------------------------------------------------------------------

# render_attachments_human BODY_FILE — one line per attachment. BODY is the
# GET /issue?fields=attachment response; .fields.attachment is a PLAIN ARRAY
# (empty `[]` is valid) — verified against live Jira. `id` is a STRING.
render_attachments_human() {
	attachments_body_file=$1
	# Assert .fields.attachment is a JSON ARRAY before the per-line loop: on a
	# valid-JSON body where it is absent/non-array, `jq -c '.fields.attachment[]'`
	# would error, and under POSIX sh (no pipefail) that error is masked by the
	# pipe — the loop would silently emit nothing and exit 0. Fail loud instead.
	if ! jq -e '.fields.attachment | type=="array"' "$attachments_body_file" >/dev/null 2>&1; then
		error "list attachments failed: response body was not the expected attachment array"
		exit 1
	fi
	attachment_count=$(jq '.fields.attachment | length' "$attachments_body_file")
	if [ "$attachment_count" -eq 0 ]; then
		printf 'No attachments.\n'
		return 0
	fi
	printf 'Attachments:\n'
	# Same delimiter-injection-proof idiom as render_components_human — one
	# compact JSON object per line, each field extracted independently by jq,
	# never an IFS split a filename carrying a literal tab/newline would break.
	# strip_control_ansi on the untrusted filename + mimeType (id/size are
	# API-shaped, but stripping them too is harmless).
	jq -c '.fields.attachment[]' "$attachments_body_file" | while IFS= read -r attachment_line; do
		at_id=$(printf '%s' "$attachment_line" | jq -r '.id // ""' | strip_control_ansi)
		at_name=$(printf '%s' "$attachment_line" | jq -r '.filename // ""' | strip_control_ansi)
		at_size=$(printf '%s' "$attachment_line" | jq -r '.size // ""' | strip_control_ansi)
		at_mime=$(printf '%s' "$attachment_line" | jq -r '.mimeType // ""' | strip_control_ansi)
		printf '  %s · %s · %s · %s\n' "$at_id" "$at_name" "$at_size" "$at_mime"
	done
}

cmd_attach() {
	# Mode (exactly one of upload[=--file present]/--list/--delete), the KEY
	# positional / --id numeric shape, and per-file readability are validated
	# up front — see the main dispatch section's per-command block.
	ensure_workdir

	if [ "$OPT_LIST" -eq 1 ]; then
		attach_list_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}?fields=attachment"
		jira_curl GET "$attach_list_url"
		handle_http_status "$JIRA_HTTP_CODE" "list attachments for $TICKET_KEY"
		require_json_body "list attachments for $TICKET_KEY"
		if [ "$OPT_JSON" -eq 1 ]; then
			cat "$JIRA_HTTP_BODY_FILE"
			return 0
		fi
		render_attachments_human "$JIRA_HTTP_BODY_FILE"
		return 0
	fi

	if [ "$OPT_DELETE" -eq 1 ]; then
		# OPT_ID is numeric-validated up front before this URL-segment interp.
		attach_delete_url="https://${CONFIRMED_HOST}/rest/api/3/attachment/${OPT_ID}"
		jira_curl DELETE "$attach_delete_url"
		handle_http_status "$JIRA_HTTP_CODE" "delete attachment $OPT_ID"
		# DELETE /attachment returns 204 No Content — no require_json_body call.
		if [ "$OPT_JSON" -eq 1 ]; then
			# SYNTHESIZED — no 204 body to pass through (same as component --delete).
			jq -n --arg id "$OPT_ID" '{id: $id, deleted: true}'
		else
			printf 'JIRA_ATTACHMENT_DELETED=%s\n' "$OPT_ID"
		fi
		return 0
	fi

	# upload — POST /issue/<KEY>/attachments as multipart, one -F part per
	# --file. The 200 body is a JSON ARRAY (one object per uploaded file).
	attach_upload_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/attachments"
	jira_curl_multipart POST "$attach_upload_url" "$OPT_FILES"
	handle_http_status "$JIRA_HTTP_CODE" "upload attachment(s) to $TICKET_KEY"
	require_json_body "upload attachment(s) to $TICKET_KEY"
	if [ "$OPT_JSON" -eq 1 ]; then
		# PASSTHROUGH — Jira's 200 body IS the array of uploaded attachments.
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	# Assert the 200 body is a JSON ARRAY before the per-line loop: a valid-JSON
	# non-array body would make `jq -c '.[]'` error, and under POSIX sh (no
	# pipefail) that error is masked by the pipe — the loop would silently emit
	# nothing and exit 0. Fail loud instead.
	if ! jq -e 'type=="array"' "$JIRA_HTTP_BODY_FILE" >/dev/null 2>&1; then
		error "upload attachment(s) to $TICKET_KEY failed: response body was not a JSON array"
		exit 1
	fi
	# One id + filename pair per uploaded file, in array order. id is a STRING;
	# the untrusted filename goes through strip_control_ansi. Same per-line jq
	# idiom as render_attachments_human.
	jq -c '.[]' "$JIRA_HTTP_BODY_FILE" | while IFS= read -r uploaded_line; do
		up_id=$(printf '%s' "$uploaded_line" | jq -r '.id // ""' | strip_control_ansi)
		up_name=$(printf '%s' "$uploaded_line" | jq -r '.filename // ""' | strip_control_ansi)
		printf 'JIRA_ATTACHMENT_ID=%s\n' "$up_id"
		printf 'JIRA_ATTACHMENT_FILENAME=%s\n' "$up_name"
	done
}

# ===========================================================================
# Agile (READ-only) — boards / sprints / backlog / epics over the Agile REST
# base /rest/agile/1.0/ (note: a DIFFERENT base than the rest of the engine's
# /rest/api/3/, but the SAME jira_curl transport, which takes a full URL and
# pins host/https regardless of path). Every command here is a GET; nothing
# in this block mutates.
# ===========================================================================

# AGILE_PAGE_SIZE — Jira Agile per-request page size (startAt/maxResults offset
# paging). 50 is a safe default well under the API's own ceiling.
AGILE_PAGE_SIZE=50

# AGILE_COLLECTED — set by fetch_paginated_agile() to the number of rows it
# appended, so an issues-envelope caller can pass it to render_search_human()
# as the total without re-counting the file.
AGILE_COLLECTED=0

# validate_board_type VALUE -> 0 if VALUE is one of Jira's fixed board types.
# Checked BEFORE VALUE becomes a `type=` query value (allow-list, not a
# deny-list — anything outside the set is rejected with a usage error).
validate_board_type() {
	case "$1" in
		scrum|kanban|simple) return 0 ;;
		*) return 1 ;;
	esac
}

# validate_sprint_states CSV -> 0 if CSV is a non-empty comma-separated list
# whose EVERY element is one of the fixed sprint states (active|future|closed).
# The Agile sprint endpoint's `state=` takes a CSV, so each element is checked
# independently against the allow-list; any unknown OR EMPTY element is rejected
# (a trailing/leading/doubled comma yields an empty slot that would urlencode
# into a malformed `state=` value). An empty boundary comma is caught up front
# because a TRAILING one never survives as its own `read` line — command
# substitution strips the trailing newline; the per-element allow-list then
# rejects any remaining empty (e.g. an internal doubled comma's blank line),
# with no `continue` skip. The split is a here-doc-fed `while read` (runs in
# THIS shell, no subshell) over comma->newline'd input — no `for x in $csv`
# word-splitting (which would also glob-expand the value), matching the
# codebase's CSV idiom.
validate_sprint_states() {
	vss_csv=$1
	case "$vss_csv" in
		''|,*|*,|*,,*) return 1 ;;
	esac
	vss_seen=0
	while IFS= read -r vss_state; do
		case "$vss_state" in
			active|future|closed) vss_seen=1 ;;
			*) return 1 ;;
		esac
	done <<-VSS_STATES_EOF
	$(printf '%s' "$vss_csv" | tr ',' "$NL")
	VSS_STATES_EOF
	[ "$vss_seen" -eq 1 ] || return 1
}

# fetch_paginated_agile OUT_FILE URL_BASE ARRAY_KEY ACTION — pages a Jira Agile
# LIST endpoint to full resolution, appending each element as one compact JSON
# line to OUT_FILE, and sets $AGILE_COLLECTED to the row count. Handles BOTH
# Agile list envelopes with ONE loop:
#   * the "values" envelope (board / sprint / epic lists):
#     {maxResults,startAt,total?,isLast,values:[...]} — `total` is OPTIONAL
#     (the /board/<id>/epic endpoint omits it, returning ONLY isLast).
#   * the "issues" envelope (sprint issues, backlog, epic issues):
#     {startAt,maxResults,total,issues:[...]} — has `total`, NO isLast.
# ARRAY_KEY is "values" or "issues" accordingly.
#
# A deliberately SEPARATE function from fetch_paginated_values (discover's
# offset pager): the two share only a superficial offset loop but their
# TERMINATION rules genuinely diverge — discover's createmeta endpoints have
# `total` and no isLast and no --limit; the Agile endpoints have the isLast /
# no-total variance below and an explicit --limit cap. Keeping them apart means
# this block cannot regress discover (the task's "keep discover intact" rule).
#
# Termination is robust across the envelope variance — it stops on the FIRST of:
#   * an empty page (no rows returned — the infinite-loop guard, and the ONLY
#     stop the epic endpoint would ever need if isLast were also absent),
#   * isLast == true (present ONLY on the values envelope),
#   * `total` present AND startAt has reached it (all rows collected).
# A loop keyed on `total` alone would spin forever on the epic endpoint (no
# total); one keyed on isLast alone would never stop on the issues envelope (no
# isLast). Checking all three covers every shape.
#
# --limit (OPT_LIMIT) is an EXPLICIT cap: when set, at most that many rows are
# collected and paging stops as soon as the cap is reached — the user's
# deliberate choice, never a silent truncation. Unset => full pagination.
fetch_paginated_agile() {
	fpa_out_file=$1
	fpa_url_base=$2
	fpa_array_key=$3
	fpa_action=$4
	fpa_start=0
	fpa_collected=0
	fpa_cap=${OPT_LIMIT:-0}
	while :; do
		fpa_page_size=$AGILE_PAGE_SIZE
		if [ "$fpa_cap" -gt 0 ]; then
			fpa_remaining=$((fpa_cap - fpa_collected))
			[ "$fpa_remaining" -gt 0 ] || break
			[ "$fpa_remaining" -ge "$fpa_page_size" ] || fpa_page_size=$fpa_remaining
		fi
		case "$fpa_url_base" in
			*\?*) fpa_sep='&' ;;
			*)    fpa_sep='?' ;;
		esac
		fpa_url="${fpa_url_base}${fpa_sep}startAt=${fpa_start}&maxResults=${fpa_page_size}"
		jira_curl GET "$fpa_url"
		handle_http_status "$JIRA_HTTP_CODE" "$fpa_action"
		require_json_body "$fpa_action"
		jq -c --arg k "$fpa_array_key" '.[$k][]?' "$JIRA_HTTP_BODY_FILE" >>"$fpa_out_file"
		fpa_page_count=$(jq --arg k "$fpa_array_key" '(.[$k] // []) | length' "$JIRA_HTTP_BODY_FILE")
		fpa_collected=$((fpa_collected + fpa_page_count))
		fpa_start=$((fpa_start + fpa_page_count))
		# is_last is "true"/"false"/"absent" — NOT `.isLast // false`: `//` also
		# fires on a JSON `false`, and (more importantly) isLast is ABSENT on the
		# issues envelope, so an explicit null-check keeps "absent" distinct from
		# "present and false" (the same trap cmd_search documents at its own loop).
		fpa_is_last=$(jq -r 'if .isLast == null then "absent" else (.isLast | tostring) end' "$JIRA_HTTP_BODY_FILE")
		# total is the row count, or -1 when the field is absent (epic values
		# envelope) — the -1 sentinel keeps the startAt>=total check from firing
		# spuriously on an endpoint that never reports a total.
		fpa_total=$(jq -r 'if .total == null then -1 else .total end' "$JIRA_HTTP_BODY_FILE")
		# Stop on an empty page (guards a missing/short total), OR isLast:true
		# (the values envelope's authoritative "no more pages"), OR once startAt
		# has reached a REPORTED total (issues envelope, and a values envelope
		# that does carry a total).
		[ "$fpa_page_count" -gt 0 ] || break
		[ "$fpa_is_last" != "true" ] || break
		if [ "$fpa_total" -ge 0 ] && [ "$fpa_start" -ge "$fpa_total" ]; then
			break
		fi
	done
	AGILE_COLLECTED=$fpa_collected
}

# agile_paginate OUT_FILE URL ARRAY_KEY ACTION — the shared fetch half of every
# Agile LIST read: TRUNCATE OUT_FILE, then paginate URL to full resolution via
# fetch_paginated_agile (appending each ARRAY_KEY element as one compact JSON
# line and setting $AGILE_COLLECTED to the row count). It does NOT branch on
# --json or render anything — each cmd_* owns that split afterward, reading
# OUT_FILE + $AGILE_COLLECTED. Kept as a helper so the seven commands never each
# re-implement the truncate-then-fetch step.
agile_paginate() {
	ap_out_file=$1
	ap_url=$2
	ap_array_key=$3
	ap_action=$4
	: >"$ap_out_file"
	fetch_paginated_agile "$ap_out_file" "$ap_url" "$ap_array_key" "$ap_action"
}

# render_boards_human FILE TOTAL — one line per board (values envelope). Each element
# is emitted as one compact JSON object (jq -c escapes any tab/newline inside a
# board NAME, so an author-controlled name can never split a row) and every
# field is extracted INDEPENDENTLY through jq + strip_control_ansi — the same
# delimiter-injection-safe idiom render_search_human / render_versions_human use.
render_boards_human() {
	boards_file=$1
	boards_total=$2
	if [ "$boards_total" -eq 0 ]; then
		printf 'No boards.\n'
		return 0
	fi
	printf '%s board(s):\n\n' "$boards_total"
	while IFS= read -r board_line; do
		b_id=$(printf '%s' "$board_line" | jq -r '.id // ""' | strip_control_ansi)
		b_name=$(printf '%s' "$board_line" | jq -r '.name // ""' | strip_control_ansi)
		b_type=$(printf '%s' "$board_line" | jq -r '.type // "N/A"' | strip_control_ansi)
		b_project=$(printf '%s' "$board_line" | jq -r '.location.projectKey // "N/A"' | strip_control_ansi)
		printf '  %-8s [%s] %s (project %s)\n' "$b_id" "$b_type" "$b_name" "$b_project"
	done <"$boards_file"
}

cmd_boards() {
	# No positional; optional --project (validated as a project key up front) and
	# --type (allow-list-validated up front). Both are urlencode'd query values.
	ensure_workdir
	boards_url="https://${CONFIRMED_HOST}/rest/agile/1.0/board"
	boards_qs=""
	if [ -n "$OPT_PROJECT" ]; then
		boards_qs="projectKeyOrId=$(urlencode "$OPT_PROJECT")"
	fi
	if [ -n "$OPT_TYPE" ]; then
		[ -z "$boards_qs" ] || boards_qs="${boards_qs}&"
		boards_qs="${boards_qs}type=$(urlencode "$OPT_TYPE")"
	fi
	[ -z "$boards_qs" ] || boards_url="${boards_url}?${boards_qs}"

	boards_file="$WORKDIR/agile-boards.jsonl"
	agile_paginate "$boards_file" "$boards_url" values "list boards"
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -s '{values: .}' "$boards_file"
	else
		render_boards_human "$boards_file" "$AGILE_COLLECTED"
	fi
}

# render_board_config_human FILE — the SINGLE board-configuration object: its
# id/name/type plus one line per column. Columns are walked with the same
# per-object jq extraction (a column NAME is author-controlled text).
render_board_config_human() {
	cfg_file=$1
	cfg_id=$(jq -r '.id // ""' "$cfg_file" | strip_control_ansi)
	cfg_name=$(jq -r '.name // ""' "$cfg_file" | strip_control_ansi)
	cfg_type=$(jq -r '.type // "N/A"' "$cfg_file" | strip_control_ansi)
	printf 'Board %s: %s (type %s)\n' "$cfg_id" "$cfg_name" "$cfg_type"
	cfg_col_count=$(jq '(.columnConfig.columns // []) | length' "$cfg_file")
	if [ "$cfg_col_count" -eq 0 ]; then
		printf 'Columns: (none)\n'
		return 0
	fi
	printf 'Columns:\n'
	jq -c '.columnConfig.columns[]?' "$cfg_file" | while IFS= read -r cfg_col_line; do
		cfg_col_name=$(printf '%s' "$cfg_col_line" | jq -r '.name // ""' | strip_control_ansi)
		printf '  - %s\n' "$cfg_col_name"
	done
}

cmd_board() {
	# BOARD_ID (the positional) is numeric-validated up front — it is the only
	# URL path segment here. board/<id>/configuration is a SINGLE object (not
	# paginated), so --json passes the raw body straight through.
	ensure_workdir
	board_url="https://${CONFIRMED_HOST}/rest/agile/1.0/board/${TICKET_KEY}/configuration"
	jira_curl GET "$board_url"
	handle_http_status "$JIRA_HTTP_CODE" "get configuration for board $TICKET_KEY"
	require_json_body "get configuration for board $TICKET_KEY"
	if [ "$OPT_JSON" -eq 1 ]; then
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	render_board_config_human "$JIRA_HTTP_BODY_FILE"
}

# render_sprints_human FILE TOTAL — one line per sprint (values envelope). Dates are
# optional (a sprint element may omit start/end), so a missing date renders as
# "N/A" rather than an empty gap.
render_sprints_human() {
	sprints_file=$1
	sprints_total=$2
	if [ "$sprints_total" -eq 0 ]; then
		printf 'No sprints.\n'
		return 0
	fi
	printf '%s sprint(s):\n\n' "$sprints_total"
	while IFS= read -r sprint_line; do
		s_id=$(printf '%s' "$sprint_line" | jq -r '.id // ""' | strip_control_ansi)
		s_state=$(printf '%s' "$sprint_line" | jq -r '.state // "N/A"' | strip_control_ansi)
		s_name=$(printf '%s' "$sprint_line" | jq -r '.name // ""' | strip_control_ansi)
		s_start=$(printf '%s' "$sprint_line" | jq -r '.startDate // "N/A"' | strip_control_ansi)
		s_end=$(printf '%s' "$sprint_line" | jq -r '.endDate // "N/A"' | strip_control_ansi)
		printf '  %-8s [%s] %s (%s -> %s)\n' "$s_id" "$s_state" "$s_name" "$s_start" "$s_end"
	done <"$sprints_file"
}

cmd_sprints() {
	# BOARD_ID numeric-validated up front; optional --state (allow-list CSV,
	# validated up front) becomes an urlencode'd `state=` query value.
	ensure_workdir
	sprints_url="https://${CONFIRMED_HOST}/rest/agile/1.0/board/${TICKET_KEY}/sprint"
	[ -z "$OPT_STATE" ] || sprints_url="${sprints_url}?state=$(urlencode "$OPT_STATE")"
	sprints_file="$WORKDIR/agile-sprints.jsonl"
	agile_paginate "$sprints_file" "$sprints_url" values "list sprints for board $TICKET_KEY"
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -s '{values: .}' "$sprints_file"
	else
		render_sprints_human "$sprints_file" "$AGILE_COLLECTED"
	fi
}

# render_sprint_human FILE — the SINGLE sprint-detail object.
render_sprint_human() {
	sprint_file=$1
	sd_id=$(jq -r '.id // ""' "$sprint_file" | strip_control_ansi)
	sd_state=$(jq -r '.state // "N/A"' "$sprint_file" | strip_control_ansi)
	sd_name=$(jq -r '.name // ""' "$sprint_file" | strip_control_ansi)
	sd_start=$(jq -r '.startDate // "N/A"' "$sprint_file" | strip_control_ansi)
	sd_end=$(jq -r '.endDate // "N/A"' "$sprint_file" | strip_control_ansi)
	sd_goal=$(jq -r '.goal // ""' "$sprint_file" | strip_control_ansi)
	printf 'Sprint %s: %s [%s]\n' "$sd_id" "$sd_name" "$sd_state"
	printf '  window: %s -> %s\n' "$sd_start" "$sd_end"
	printf '  goal:   %s\n' "$sd_goal"
}

# emit_sprint_result — the shared success output for every sprint WRITE
# (create/update/start/close). On --json: PASSTHROUGH of Jira's sprint object
# (the 200/201 body IS the answer). Otherwise: the two machine lines
# JIRA_SPRINT_ID / JIRA_SPRINT_STATE. `.id` is a JSON number in the response;
# jq -r renders it as its decimal digits.
emit_sprint_result() {
	if [ "$OPT_JSON" -eq 1 ]; then
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	esr_id=$(jq -r '.id // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
	esr_state=$(jq -r '.state // ""' "$JIRA_HTTP_BODY_FILE" | strip_control_ansi)
	printf 'JIRA_SPRINT_ID=%s\n' "$esr_id"
	printf 'JIRA_SPRINT_STATE=%s\n' "$esr_state"
}

cmd_sprint() {
	# Mode: exactly one of the WRITE modes (--create/--update/--start/--close) OR
	# a READ (no write mode; the positional SPRINT_ID + optional --issues). Mode,
	# --board/--name presence, id shapes, required dates, and ISO-8601 date FORMAT
	# are all validated up front — see the main dispatch section's per-command
	# block. Bodies are built with static-jq merge helpers (--arg/--argjson),
	# never string concatenation; every write is a POST over /rest/agile/1.0/.
	ensure_workdir

	if [ "$OPT_CREATE" -eq 1 ]; then
		# POST /sprint — body {name, originBoardId[, goal, startDate, endDate]}.
		# originBoardId is a JSON NUMBER (merge_int_field); the rest are strings.
		sprint_create_body="$WORKDIR/sprint-create.json"
		init_fields_accumulator "$sprint_create_body"
		merge_string_field "$sprint_create_body" name "$OPT_NAME"
		merge_int_field    "$sprint_create_body" originBoardId "$OPT_BOARD"
		[ -z "$OPT_GOAL" ]       || merge_string_field "$sprint_create_body" goal "$OPT_GOAL"
		[ -z "$OPT_START_DATE" ] || merge_string_field "$sprint_create_body" startDate "$OPT_START_DATE"
		[ -z "$OPT_END_DATE" ]   || merge_string_field "$sprint_create_body" endDate "$OPT_END_DATE"
		sprint_create_url="https://${CONFIRMED_HOST}/rest/agile/1.0/sprint"
		jira_curl POST "$sprint_create_url" "$sprint_create_body"
		handle_http_status "$JIRA_HTTP_CODE" "create sprint"
		require_json_body "create sprint"
		emit_sprint_result
		return 0
	fi

	if [ "$OPT_UPDATE" -eq 1 ] || [ "$OPT_START" -eq 1 ] || [ "$OPT_CLOSE" -eq 1 ]; then
		# All three POST /sprint/<id> with a PARTIAL body. State transitions
		# (future->active->closed) are enforced by the SERVER — a bad transition
		# surfaces as its own HTTP error via handle_http_status, not a pre-GET.
		# OPT_ID here is the positional TICKET_KEY, numeric-validated up front.
		sprint_write_body="$WORKDIR/sprint-write.json"
		init_fields_accumulator "$sprint_write_body"
		if [ "$OPT_START" -eq 1 ]; then
			# start REQUIRES both dates (enforced up front): {state:active,dates}.
			merge_string_field "$sprint_write_body" state active
			merge_string_field "$sprint_write_body" startDate "$OPT_START_DATE"
			merge_string_field "$sprint_write_body" endDate "$OPT_END_DATE"
		elif [ "$OPT_CLOSE" -eq 1 ]; then
			merge_string_field "$sprint_write_body" state closed
		else
			# update — only the fields the caller supplied (>=1 enforced up front).
			[ -z "$OPT_NAME" ]       || merge_string_field "$sprint_write_body" name "$OPT_NAME"
			[ -z "$OPT_GOAL" ]       || merge_string_field "$sprint_write_body" goal "$OPT_GOAL"
			[ -z "$OPT_START_DATE" ] || merge_string_field "$sprint_write_body" startDate "$OPT_START_DATE"
			[ -z "$OPT_END_DATE" ]   || merge_string_field "$sprint_write_body" endDate "$OPT_END_DATE"
		fi
		sprint_write_url="https://${CONFIRMED_HOST}/rest/agile/1.0/sprint/${TICKET_KEY}"
		jira_curl POST "$sprint_write_url" "$sprint_write_body"
		handle_http_status "$JIRA_HTTP_CODE" "update sprint $TICKET_KEY"
		require_json_body "update sprint $TICKET_KEY"
		emit_sprint_result
		return 0
	fi

	# READ: SPRINT_ID numeric-validated up front. Default: the single
	# sprint-detail object (raw body passthrough on --json). With --issues: the
	# sprint's issues (issues envelope, paginated, rendered via the shared render).
	if [ "$OPT_ISSUES" -eq 1 ]; then
		sprint_issues_url="https://${CONFIRMED_HOST}/rest/agile/1.0/sprint/${TICKET_KEY}/issue"
		sprint_issues_file="$WORKDIR/agile-sprint-issues.jsonl"
		agile_paginate "$sprint_issues_file" "$sprint_issues_url" issues "list issues for sprint $TICKET_KEY"
		if [ "$OPT_JSON" -eq 1 ]; then
			jq -s '{issues: .}' "$sprint_issues_file"
		else
			render_search_human "$sprint_issues_file" "$AGILE_COLLECTED"
		fi
		return 0
	fi
	sprint_url="https://${CONFIRMED_HOST}/rest/agile/1.0/sprint/${TICKET_KEY}"
	jira_curl GET "$sprint_url"
	handle_http_status "$JIRA_HTTP_CODE" "get sprint $TICKET_KEY"
	require_json_body "get sprint $TICKET_KEY"
	if [ "$OPT_JSON" -eq 1 ]; then
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	render_sprint_human "$JIRA_HTTP_BODY_FILE"
}

cmd_backlog() {
	# BOARD_ID numeric-validated up front. board/<id>/backlog is the issues
	# envelope — paginated to full resolution, rendered via the shared issue
	# render (the same shape as a search result).
	ensure_workdir
	backlog_url="https://${CONFIRMED_HOST}/rest/agile/1.0/board/${TICKET_KEY}/backlog"
	backlog_file="$WORKDIR/agile-backlog.jsonl"
	agile_paginate "$backlog_file" "$backlog_url" issues "list backlog for board $TICKET_KEY"
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -s '{issues: .}' "$backlog_file"
	else
		render_search_human "$backlog_file" "$AGILE_COLLECTED"
	fi
}

# render_epics_human FILE TOTAL — one line per epic (values envelope). The epic
# element carries both a key (PROJECT-NNN) and a done flag.
render_epics_human() {
	epics_file=$1
	epics_total=$2
	if [ "$epics_total" -eq 0 ]; then
		printf 'No epics.\n'
		return 0
	fi
	printf '%s epic(s):\n\n' "$epics_total"
	while IFS= read -r epic_line; do
		e_key=$(printf '%s' "$epic_line" | jq -r '.key // ""' | strip_control_ansi)
		e_name=$(printf '%s' "$epic_line" | jq -r '.name // ""' | strip_control_ansi)
		e_done=$(printf '%s' "$epic_line" | jq -r '.done // false' | strip_control_ansi)
		printf '  %-12s [done %s] %s\n' "$e_key" "$e_done" "$e_name"
	done <"$epics_file"
}

cmd_epics() {
	# BOARD_ID numeric-validated up front. board/<id>/epic is the values
	# envelope but — UNIQUELY — returns isLast with NO `total`; full pagination
	# therefore relies on isLast/empty-page, which fetch_paginated_agile handles.
	ensure_workdir
	epics_url="https://${CONFIRMED_HOST}/rest/agile/1.0/board/${TICKET_KEY}/epic"
	epics_file="$WORKDIR/agile-epics.jsonl"
	agile_paginate "$epics_file" "$epics_url" values "list epics for board $TICKET_KEY"
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -s '{values: .}' "$epics_file"
	else
		render_epics_human "$epics_file" "$AGILE_COLLECTED"
	fi
}

cmd_epic() {
	# EPIC_ID numeric-validated up front; --issues is REQUIRED (the only
	# supported epic read is its issues). epic/<id>/issue is the issues
	# envelope, paginated, rendered via the shared issue render.
	ensure_workdir
	epic_issues_url="https://${CONFIRMED_HOST}/rest/agile/1.0/epic/${TICKET_KEY}/issue"
	epic_issues_file="$WORKDIR/agile-epic-issues.jsonl"
	agile_paginate "$epic_issues_file" "$epic_issues_url" issues "list issues for epic $TICKET_KEY"
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -s '{issues: .}' "$epic_issues_file"
	else
		render_search_human "$epic_issues_file" "$AGILE_COLLECTED"
	fi
}

# ---------------------------------------------------------------------------
# bulk — apply ONE existing verb (transition|comment|update) to a SET of
# issues, synchronously, in a single invocation. A deliberate CLIENT-SIDE loop
# that COMPOSES over the already-reviewed single-issue verbs — NOT Jira's
# native async bulk API (intentionally out of scope).
#
# FAILURE-ISOLATION APPROACH (subshell, not core-extraction): each issue's
# verb runs inside a `( ... )` subshell — apply_bulk_verb_to_key below — so a
# per-issue `exit 1` (a 4xx, an unreachable transition, an unresolvable field)
# isolates to THAT iteration and never aborts the batch. This was chosen over
# factoring a status-returning core out of each cmd_* precisely because it
# leaves the single-issue verbs (and every one of their existing tests)
# BYTE-FOR-BYTE unchanged: the isolation is a property of the subshell
# boundary, not of any edit to the verbs. Verified: a `( )` subshell does NOT
# run the parent's EXIT trap on its own exit, so cleanup() never wipes WORKDIR
# mid-batch. The subshell also gets its OWN COPY of every WORKDIR temp-file
# counter (RESP_COUNTER/TRANS_COUNTER/...), so each iteration reuses the same
# fixed temp-file names and overwrites them SEQUENTIALLY — no cross-iteration
# collision, since the prior subshell has already exited before the next runs.
#
# --plan is the batch-safety mechanism: it resolves + validates the set, prints
# exactly what WOULD change, and MUTATES NOTHING — for --keys it makes ZERO
# requests; for --jql it makes ONLY the read that resolves the set (via the
# reused search path). No write verb (POST/PUT) is ever reached under --plan.
# ---------------------------------------------------------------------------

# split_keys_csv CSV — emits each comma-separated key on its own line, trimmed
# of surrounding whitespace, empties dropped. Uses the engine's ESTABLISHED
# jq CSV idiom (see merge_labels_field / build_search_request_body's --fields),
# so --keys splits exactly as every other CSV in this engine does — one helper,
# one behaviour, no divergent tr/sed pipeline.
split_keys_csv() {
	jq -rn --arg csv "$1" \
		'$csv | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$";"")) | .[] | select(length > 0)'
}

# resolve_bulk_keys_file OUT_FILE — writes the resolved, shape-validated issue
# keys (one per line) to OUT_FILE. Exactly one of --keys/--jql drives it
# (enforced up front). Every key — from BOTH sources — is re-validated with
# validate_ticket_key before it can become a URL path segment downstream.
resolve_bulk_keys_file() {
	bulk_keys_out_file=$1
	: >"$bulk_keys_out_file"

	if [ -n "$OPT_KEYS" ]; then
		# One key per line via the shared split helper. The values were already
		# shape-validated up front (usage error, exit 2); the re-validation loop
		# below is defense in depth before any URL use.
		split_keys_csv "$OPT_KEYS" >"$bulk_keys_out_file"
	else
		# --jql: resolve the set through the SAME search path cmd_search uses —
		# reuse cmd_search wholesale (its allow-listed JQL escaping, its sender,
		# its pagination), capturing its --json output and extracting the keys.
		# The resolve MUST cover the FULL matching set, never a silently truncated
		# prefix: with no explicit --limit we set SEARCH_UNBOUNDED so cmd_search
		# paginates to exhaustion; a user-supplied --limit stays an explicit,
		# intentional cap (its truncation is DISCLOSED downstream, see cmd_bulk).
		# OPT_JSON is flipped to 1 in THIS (parent) scope — not inside the
		# capture subshell — so cmd_search emits its {issues:[...]} structure
		# regardless of the user's own --json, then restored so the batch's own
		# later rendering honors the user's choice. ensure_workdir already ran
		# in the MAIN shell (see cmd_bulk), so cmd_search's inner ensure_workdir
		# is a no-op and the capture subshell orphans no WORKDIR. A failed
		# resolve (cmd_search exit 1) fails this assignment under set -e,
		# aborting the batch BEFORE any mutation — the desired fail-closed path
		# (OPT_JSON is not restored on that abort, but the process is exiting).
		if [ -n "$OPT_LIMIT" ]; then SEARCH_UNBOUNDED=0; else SEARCH_UNBOUNDED=1; fi
		bulk_saved_json=$OPT_JSON
		OPT_JSON=1
		bulk_search_json=$(cmd_search)
		OPT_JSON=$bulk_saved_json
		SEARCH_UNBOUNDED=0
		printf '%s' "$bulk_search_json" | jq -r '.issues[].key // empty' >"$bulk_keys_out_file"
	fi

	# Shape-validate EVERY resolved key before it becomes a URL segment — a
	# --jql set is derived from a network response and is therefore untrusted.
	while IFS= read -r bulk_resolved_key; do
		[ -n "$bulk_resolved_key" ] || continue
		validate_ticket_key "$bulk_resolved_key" || { error "resolved an invalid ticket key: $bulk_resolved_key"; exit 1; }
	done <"$bulk_keys_out_file"
}

# bulk_update_field_summary -> a space-joined list of the update aspects the
# caller asked to change, for the --plan disclosure (human + json). Mirrors the
# single-verb flag set; purely descriptive, so it never touches the network.
bulk_update_field_summary() {
	bulk_fields=""
	[ -z "$OPT_TITLE" ]            || bulk_fields="$bulk_fields title"
	[ -z "$OPT_DESCRIPTION_FILE" ] || bulk_fields="$bulk_fields description"
	[ -z "$OPT_APPEND_FILE" ]      || bulk_fields="$bulk_fields description(append)"
	[ -z "$OPT_ACCEPTANCE_FILE" ]  || bulk_fields="$bulk_fields acceptance"
	[ -z "$OPT_REVIEW_FILE" ]      || bulk_fields="$bulk_fields review"
	[ -z "$OPT_ASSIGNEE" ]         || bulk_fields="$bulk_fields assignee"
	[ -z "$OPT_DEVELOPER" ]        || bulk_fields="$bulk_fields developer"
	[ -z "$OPT_LABELS" ]           || bulk_fields="$bulk_fields labels"
	[ -z "$OPT_DUE_DATE" ]         || bulk_fields="$bulk_fields due-date"
	[ -z "$OPT_PARENT" ]           || bulk_fields="$bulk_fields parent"
	[ -z "$OPT_FIX_VERSIONS" ]     || bulk_fields="$bulk_fields fix-version"
	[ -z "$OPT_AFFECTS_VERSIONS" ] || bulk_fields="$bulk_fields affects-version"
	[ -z "$OPT_COMPONENTS" ]       || bulk_fields="$bulk_fields component"
	# strip the single leading space
	printf '%s' "${bulk_fields# }"
}

# bulk_intent_phrase -> one human phrase describing the change --plan would
# apply, per --op (the "intended change" the plan discloses).
bulk_intent_phrase() {
	case "$OPT_OP" in
		transition)
			if [ -n "$OPT_RESOLUTION" ]; then
				printf 'transition to "%s" (resolution: %s)' "$OPT_STATUS" "$OPT_RESOLUTION"
			else
				printf 'transition to "%s"' "$OPT_STATUS"
			fi
			;;
		comment) printf 'add a comment from %s' "$OPT_TEXT_FILE" ;;
		update)  printf 'update field(s): %s' "$(bulk_update_field_summary)" ;;
	esac
}

# render_bulk_plan KEYS_FILE TOTAL TRUNCATED RESOLVED_LIMIT — the --plan
# disclosure: names every issue in the set + the single change that WOULD be
# applied, discloses any cap in effect (truncated/resolvedLimit), then states
# plainly that nothing was written. Routed to json or human by OPT_JSON.
# TRUNCATED is a bare true/false; RESOLVED_LIMIT a bare integer or null.
render_bulk_plan() {
	plan_keys_file=$1
	plan_total=$2
	plan_truncated=$3
	plan_resolved_limit=$4
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -n --arg op "$OPT_OP" --arg intent "$(bulk_intent_phrase)" \
			--argjson total "$plan_total" --argjson truncated "$plan_truncated" \
			--argjson resolvedLimit "$plan_resolved_limit" --rawfile keys_raw "$plan_keys_file" \
			'{op: $op, plan: true, willWrite: false, intent: $intent,
			  total: $total, truncated: $truncated, resolvedLimit: $resolvedLimit,
			  keys: ($keys_raw | split("\n") | map(select(length > 0)))}'
		return 0
	fi
	printf 'PLAN (bulk %s): would %s for %d issue(s):\n' "$OPT_OP" "$(bulk_intent_phrase)" "$plan_total"
	while IFS= read -r plan_key; do
		[ -n "$plan_key" ] || continue
		printf '  %s\n' "$plan_key"
	done <"$plan_keys_file"
	if [ "$plan_truncated" = "true" ]; then
		printf 'NOTE: capped at --limit %s — additional matches may exist and are NOT in this set.\n' "$plan_resolved_limit"
	fi
	printf 'NOTHING WAS WRITTEN (dry-run / --plan).\n'
}

# apply_bulk_verb_to_key KEY — runs the selected verb against ONE issue inside
# a SUBSHELL, returning that verb's status (0 ok / non-0 failed) WITHOUT ever
# aborting the caller's batch loop. Only TICKET_KEY is overridden per issue;
# the op-specific OPT_* (OPT_STATUS/OPT_TEXT_FILE/the update fields) are already
# the globals the single verb reads. The subshell's stdout is discarded (this
# batch emits its OWN machine lines and OPT_JSON only affects that discarded
# output, so it need not be forced off; OPT_PLAN is already 0 on this real-run
# path), while stderr is left to flow so a per-issue failure's diagnostic still
# reaches the operator.
apply_bulk_verb_to_key() {
	apply_bulk_key=$1
	(
		TICKET_KEY=$apply_bulk_key
		case "$OPT_OP" in
			transition) cmd_transition ;;
			comment)    cmd_comment ;;
			update)     cmd_update ;;
		esac
	) >/dev/null
}

cmd_bulk() {
	# --op validity, exactly-one-of --keys/--jql, per-key shape, and the
	# op-specific required args are all validated up front — see the main
	# dispatch section's per-command block.
	#
	# ensure_workdir runs FIRST in the MAIN shell so neither the cmd_search
	# reuse (for --jql) nor any per-issue verb subshell below can create — and
	# then orphan — a WORKDIR from inside a subshell (the same leak already
	# guarded in cmd_search/cmd_comment/cmd_transition).
	ensure_workdir

	# comment's --text-file is the SAME file for every issue — assert it is
	# readable ONCE, up front, before any network I/O (usage-class failure).
	if [ "$OPT_OP" = "comment" ]; then
		require_readable_file "$OPT_TEXT_FILE" "--text-file"
	fi

	bulk_keys_file="$WORKDIR/bulk-keys.txt"
	resolve_bulk_keys_file "$bulk_keys_file"

	# Count non-empty lines without wc/awk (kept off the test toolbox on
	# purpose): a plain read loop is the portable, dependency-free counter.
	bulk_total=0
	while IFS= read -r bulk_count_key; do
		[ -n "$bulk_count_key" ] || continue
		bulk_total=$((bulk_total + 1))
	done <"$bulk_keys_file"

	if [ "$bulk_total" -eq 0 ]; then
		error "bulk --op $OPT_OP resolved ZERO issues (nothing to do)"
		exit 1
	fi

	# Truncation disclosure — the load-bearing safety invariant: a bulk MUST NEVER silently mutate
	# a truncated set nor claim complete success over one. A --jql resolve with no
	# --limit paginates to exhaustion, so the set is complete (truncated=false).
	# When the caller passes an explicit --limit, that cap is intentional but MUST
	# be disclosed: if the resolved count reached the cap, more matches may exist
	# beyond it, so flag it as truncated (conservative — never under-discloses).
	bulk_truncated=false
	bulk_resolved_limit=null
	if [ -n "$OPT_JQL" ] && [ -n "$OPT_LIMIT" ] && [ "$bulk_total" -ge "$OPT_LIMIT" ]; then
		bulk_truncated=true
		bulk_resolved_limit=$OPT_LIMIT
		warn "bulk --jql resolved $bulk_total issue(s), capped at --limit $OPT_LIMIT — additional matches may exist and were NOT included in this batch"
	fi

	if [ "$OPT_PLAN" -eq 1 ]; then
		render_bulk_plan "$bulk_keys_file" "$bulk_total" "$bulk_truncated" "$bulk_resolved_limit"
		return 0
	fi

	# Real run: apply the verb to each issue, isolating per-issue failure and
	# collecting outcomes. The loop reads the keys file via REDIRECTION (not a
	# pipe) so it runs in THIS shell and its counters survive each iteration.
	bulk_ok=0
	bulk_failed=0
	bulk_results_file="$WORKDIR/bulk-results.jsonl"
	: >"$bulk_results_file"

	while IFS= read -r bulk_key; do
		[ -n "$bulk_key" ] || continue
		if apply_bulk_verb_to_key "$bulk_key"; then
			bulk_ok=$((bulk_ok + 1))
			bulk_outcome=ok
		else
			bulk_failed=$((bulk_failed + 1))
			bulk_outcome=failed
		fi
		if [ "$OPT_JSON" -eq 1 ]; then
			jq -nc --arg key "$bulk_key" --arg status "$bulk_outcome" \
				'{key: $key, status: $status}' >>"$bulk_results_file"
		else
			printf 'JIRA_BULK_RESULT=%s:%s\n' "$bulk_key" "$bulk_outcome"
		fi
	done <"$bulk_keys_file"

	if [ "$OPT_JSON" -eq 1 ]; then
		jq -s --arg op "$OPT_OP" --argjson ok "$bulk_ok" --argjson total "$bulk_total" \
			--argjson truncated "$bulk_truncated" --argjson resolvedLimit "$bulk_resolved_limit" \
			'{op: $op, results: .,
			  summary: {ok: $ok, total: $total, failed: ($total - $ok),
			            truncated: $truncated, resolvedLimit: $resolvedLimit}}' \
			"$bulk_results_file"
	elif [ "$bulk_truncated" = "true" ]; then
		# NEVER a bare "N/N succeeded" over a capped set — disclose the cap inline.
		printf 'JIRA_BULK_SUMMARY=%d/%d succeeded (CAPPED at --limit %s; additional matches may exist and were NOT processed)\n' \
			"$bulk_ok" "$bulk_total" "$bulk_resolved_limit"
	else
		printf 'JIRA_BULK_SUMMARY=%d/%d succeeded\n' "$bulk_ok" "$bulk_total"
	fi

	# Exit 0 iff ALL issues succeeded; non-zero if ANY failed (so a caller can
	# detect partial failure). This is the LAST statement, so its status
	# becomes cmd_bulk's return and thus the script's exit code.
	[ "$bulk_failed" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Command + argument parsing
# ---------------------------------------------------------------------------
COMMAND=${1:-}
case "$COMMAND" in
	-h|--help) usage; exit 0 ;;
	view|search|workflow|create|comment|transition|update|link|link-types|children|discover|worklog|watch|vote|version|component|attach|bulk|boards|board|sprints|sprint|backlog|epics|epic) shift ;;
	'') usage >&2; error "missing command"; exit 2 ;;
	*) usage >&2; error "unknown command: $COMMAND"; exit 2 ;;
esac

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
TICKET_KEY=""

while [ $# -gt 0 ]; do
	case "$1" in
		--confirmed-site)    need_arg "$1" "${2:-}"; OPT_CONFIRMED_SITE=$2; shift ;;
		--project)           need_arg "$1" "${2:-}"; OPT_PROJECT=$2; shift ;;
		--fields)            need_arg "$1" "${2:-}"; OPT_FIELDS=$2; shift ;;
		--assignee)          need_arg "$1" "${2:-}"; OPT_ASSIGNEE=$2; shift ;;
		--status)            need_arg "$1" "${2:-}"; OPT_STATUS=$2; shift ;;
		--type)              need_arg "$1" "${2:-}"; OPT_TYPE=$2; shift ;;
		--labels)            need_arg "$1" "${2:-}"; OPT_LABELS=$2; shift ;;
		--jql)               need_arg "$1" "${2:-}"; OPT_JQL=$2; shift ;;
		--op)                need_arg "$1" "${2:-}"; OPT_OP=$2; shift ;;
		--keys)              need_arg "$1" "${2:-}"; OPT_KEYS=$2; shift ;;
		--limit)             need_arg "$1" "${2:-}"; OPT_LIMIT=$2; shift ;;
		--page-size)         need_arg "$1" "${2:-}"; OPT_PAGE_SIZE=$2; shift ;;
		--projects-dir)      need_arg "$1" "${2:-}"; OPT_PROJECTS_DIR=$2; shift ;;
		--title)             need_arg "$1" "${2:-}"; OPT_TITLE=$2; shift ;;
		--description-file)  need_arg "$1" "${2:-}"; OPT_DESCRIPTION_FILE=$2; shift ;;
		--append-file)       need_arg "$1" "${2:-}"; OPT_APPEND_FILE=$2; shift ;;
		--acceptance-file)   need_arg "$1" "${2:-}"; OPT_ACCEPTANCE_FILE=$2; shift ;;
		--review-file)       need_arg "$1" "${2:-}"; OPT_REVIEW_FILE=$2; shift ;;
		--text-file)         need_arg "$1" "${2:-}"; OPT_TEXT_FILE=$2; shift ;;
		--due-date)          need_arg "$1" "${2:-}"; OPT_DUE_DATE=$2; shift ;;
		--parent)            need_arg "$1" "${2:-}"; OPT_PARENT=$2; shift ;;
		--developer)         need_arg "$1" "${2:-}"; OPT_DEVELOPER=$2; shift ;;
		--resolution)        need_arg "$1" "${2:-}"; OPT_RESOLUTION=$2; shift ;;
		--plan|--dry-run)    OPT_PLAN=1 ;;
		--to)                need_arg "$1" "${2:-}"; OPT_TO=$2; shift ;;
		--link-type)         need_arg "$1" "${2:-}"; OPT_LINK_TYPE=$2; shift ;;
		--time-spent)        need_arg "$1" "${2:-}"; OPT_TIME_SPENT=$2; shift ;;
		--comment-file)      need_arg "$1" "${2:-}"; OPT_COMMENT_FILE=$2; shift ;;
		--started)           need_arg "$1" "${2:-}"; OPT_STARTED=$2; shift ;;
		--account)           need_arg "$1" "${2:-}"; OPT_ACCOUNT=$2; shift ;;
		--id)                need_arg "$1" "${2:-}"; OPT_ID=$2; shift ;;
		--name)              need_arg "$1" "${2:-}"; OPT_NAME=$2; shift ;;
		--description)       need_arg "$1" "${2:-}"; OPT_DESCRIPTION=$2; shift ;;
		--release-date)      need_arg "$1" "${2:-}"; OPT_RELEASE_DATE=$2; shift ;;
		--start-date)        need_arg "$1" "${2:-}"; OPT_START_DATE=$2; shift ;;
		--lead-account-id)   need_arg "$1" "${2:-}"; OPT_LEAD_ACCOUNT_ID=$2; shift ;;
		--move-issues-to)    need_arg "$1" "${2:-}"; OPT_MOVE_ISSUES_TO=$2; shift ;;
		--fix-version)       need_arg "$1" "${2:-}"; OPT_FIX_VERSIONS="${OPT_FIX_VERSIONS}${2}${NL}"; shift ;;
		--affects-version)   need_arg "$1" "${2:-}"; OPT_AFFECTS_VERSIONS="${OPT_AFFECTS_VERSIONS}${2}${NL}"; shift ;;
		--component)         need_arg "$1" "${2:-}"; OPT_COMPONENTS="${OPT_COMPONENTS}${2}${NL}"; shift ;;
		--file)              need_arg "$1" "${2:-}"; OPT_FILES="${OPT_FILES}${2}${NL}"; shift ;;
		--state)             need_arg "$1" "${2:-}"; OPT_STATE=$2; shift ;;
		--board)             need_arg "$1" "${2:-}"; OPT_BOARD=$2; shift ;;
		--goal)              need_arg "$1" "${2:-}"; OPT_GOAL=$2; shift ;;
		--end-date)          need_arg "$1" "${2:-}"; OPT_END_DATE=$2; shift ;;
		--issues)            OPT_ISSUES=1 ;;
		--start)             OPT_START=1 ;;
		--close)             OPT_CLOSE=1 ;;
		--released)          OPT_RELEASED=1 ;;
		--create)            OPT_CREATE=1 ;;
		--update)            OPT_UPDATE=1 ;;
		--delete)            OPT_DELETE=1 ;;
		--release)           OPT_RELEASE=1 ;;
		--archive)           OPT_ARCHIVE=1 ;;
		--remove)            OPT_REMOVE=1 ;;
		--list)              OPT_LIST=1 ;;
		--write)             OPT_WRITE=1 ;;
		--force)             OPT_FORCE=1 ;;
		--json)              OPT_JSON=1 ;;
		-h|--help)           usage; exit 0 ;;
		--)                  shift; break ;;
		-*)                  usage >&2; error "unknown option: $1"; exit 2 ;;
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
	view|workflow|children)
		[ -n "$TICKET_KEY" ] || { usage >&2; error "$COMMAND requires a ticket key, e.g.: $COMMAND PROJ-123"; exit 2; }
		validate_ticket_key "$TICKET_KEY" || { usage >&2; error "invalid ticket key: $TICKET_KEY"; exit 2; }
		;;
	search)
		# search takes no positional — silently accepting one (e.g. a
		# stray ticket key from a copy-pasted `view` invocation) would run an
		# unintended, unfiltered-by-that-key query instead of failing loudly.
		if [ -n "$TICKET_KEY" ]; then
			usage >&2
			error "search takes no positional argument, got: $TICKET_KEY (use --project instead)"
			exit 2
		fi
		if [ -z "$OPT_JQL" ] && [ -z "$OPT_PROJECT" ] && [ -z "$OPT_ASSIGNEE" ] \
			&& [ -z "$OPT_STATUS" ] && [ -z "$OPT_TYPE" ] && [ -z "$OPT_LABELS" ]; then
			usage >&2
			error "search requires at least one filter: --project/--assignee/--status/--type/--labels/--jql"
			exit 2
		fi
		;;
	create)
		[ -n "$OPT_PROJECT" ] || { usage >&2; error "create requires --project"; exit 2; }
		[ -n "$OPT_TITLE" ]   || { usage >&2; error "create requires --title"; exit 2; }
		;;
	comment)
		[ -n "$TICKET_KEY" ]    || { usage >&2; error "comment requires a ticket key, e.g.: comment PROJ-123"; exit 2; }
		validate_ticket_key "$TICKET_KEY" || { usage >&2; error "invalid ticket key: $TICKET_KEY"; exit 2; }
		[ -n "$OPT_TEXT_FILE" ] || { usage >&2; error "comment requires --text-file"; exit 2; }
		;;
	transition)
		[ -n "$TICKET_KEY" ] || { usage >&2; error "transition requires a ticket key, e.g.: transition PROJ-123"; exit 2; }
		validate_ticket_key "$TICKET_KEY" || { usage >&2; error "invalid ticket key: $TICKET_KEY"; exit 2; }
		[ -n "$OPT_STATUS" ] || { usage >&2; error "transition requires --status TARGET"; exit 2; }
		;;
	update)
		[ -n "$TICKET_KEY" ] || { usage >&2; error "update requires a ticket key, e.g.: update PROJ-123"; exit 2; }
		validate_ticket_key "$TICKET_KEY" || { usage >&2; error "invalid ticket key: $TICKET_KEY"; exit 2; }
		if [ -n "$OPT_DESCRIPTION_FILE" ] && [ -n "$OPT_APPEND_FILE" ]; then
			usage >&2
			error "--description-file and --append-file are mutually exclusive"
			exit 2
		fi
		if [ -z "$OPT_TITLE" ] && [ -z "$OPT_DESCRIPTION_FILE" ] && [ -z "$OPT_APPEND_FILE" ] \
			&& [ -z "$OPT_ACCEPTANCE_FILE" ] && [ -z "$OPT_REVIEW_FILE" ] && [ -z "$OPT_ASSIGNEE" ] \
			&& [ -z "$OPT_DEVELOPER" ] && [ -z "$OPT_LABELS" ] && [ -z "$OPT_DUE_DATE" ] && [ -z "$OPT_PARENT" ] \
			&& [ -z "$OPT_FIX_VERSIONS" ] && [ -z "$OPT_AFFECTS_VERSIONS" ] && [ -z "$OPT_COMPONENTS" ]; then
			usage >&2
			error "update requires at least one field to change"
			exit 2
		fi
		;;
	link)
		[ -n "$TICKET_KEY" ] || { usage >&2; error "link requires a FROM ticket key, e.g.: link PROJ-1 --to PROJ-2 --link-type Blocks"; exit 2; }
		validate_ticket_key "$TICKET_KEY" || { usage >&2; error "invalid FROM ticket key: $TICKET_KEY"; exit 2; }
		[ -n "$OPT_TO" ] || { usage >&2; error "link requires --to TARGET_KEY"; exit 2; }
		validate_ticket_key "$OPT_TO" || { usage >&2; error "invalid --to ticket key: $OPT_TO"; exit 2; }
		[ -n "$OPT_LINK_TYPE" ] || { usage >&2; error "link requires --link-type NAME"; exit 2; }
		;;
	link-types)
		# link-types takes no positional — same "fail loud on a stray
		# argument" reasoning as search's own check above.
		if [ -n "$TICKET_KEY" ]; then
			usage >&2
			error "link-types takes no positional argument, got: $TICKET_KEY"
			exit 2
		fi
		;;
	discover)
		# discover's positional is a bare PROJECT key (not a ticket key) — it
		# becomes a URL path segment AND (on --write) a config file path, so it
		# is shape-validated here with validate_project_key, the SAME guard
		# try_load_project_config uses for --project. A traversal-shaped value
		# (e.g. "../../x") is rejected with exit 2 here, BEFORE any read/write.
		[ -n "$TICKET_KEY" ] || { usage >&2; error "discover requires a PROJECT key, e.g.: discover PROJ"; exit 2; }
		validate_project_key "$TICKET_KEY" || { usage >&2; error "invalid project key: $TICKET_KEY"; exit 2; }
		;;
	worklog)
		[ -n "$TICKET_KEY" ] || { usage >&2; error "worklog requires a ticket key, e.g.: worklog PROJ-1 --time-spent 2h"; exit 2; }
		validate_ticket_key "$TICKET_KEY" || { usage >&2; error "invalid ticket key: $TICKET_KEY"; exit 2; }
		[ -n "$OPT_TIME_SPENT" ] || { usage >&2; error "worklog requires --time-spent STR"; exit 2; }
		;;
	watch)
		[ -n "$TICKET_KEY" ] || { usage >&2; error "watch requires a ticket key, e.g.: watch PROJ-123"; exit 2; }
		validate_ticket_key "$TICKET_KEY" || { usage >&2; error "invalid ticket key: $TICKET_KEY"; exit 2; }
		if [ "$OPT_LIST" -eq 1 ] && [ "$OPT_REMOVE" -eq 1 ]; then
			usage >&2
			error "watch --list and --remove are mutually exclusive"
			exit 2
		fi
		if [ "$OPT_LIST" -eq 1 ] && [ -n "$OPT_ACCOUNT" ]; then
			usage >&2
			error "watch --list does not take --account"
			exit 2
		fi
		;;
	vote)
		[ -n "$TICKET_KEY" ] || { usage >&2; error "vote requires a ticket key, e.g.: vote PROJ-123"; exit 2; }
		validate_ticket_key "$TICKET_KEY" || { usage >&2; error "invalid ticket key: $TICKET_KEY"; exit 2; }
		if [ "$OPT_LIST" -eq 1 ] && [ "$OPT_REMOVE" -eq 1 ]; then
			usage >&2
			error "vote --list and --remove are mutually exclusive"
			exit 2
		fi
		;;
	version)
		# version takes NO positional — a stray one fails loud (same
		# reasoning as search/link-types).
		if [ -n "$TICKET_KEY" ]; then
			usage >&2
			error "version takes no positional argument, got: $TICKET_KEY"
			exit 2
		fi
		# --delete is a COMPONENT mode, not a version mode. Without this,
		# `version --list --delete` would count exactly one OWN version mode
		# (--list) and silently run the list, ignoring the foreign --delete.
		# Reject it by name (clear message), and additionally fold every mode
		# flag from BOTH commands into the exactly-one count below so no
		# foreign mode can pass unnoticed even if one is added later.
		if [ "$OPT_DELETE" -eq 1 ]; then
			usage >&2
			error "--delete is not a version mode (did you mean 'component --delete'?)"
			exit 2
		fi
		version_mode_count=$((OPT_LIST + OPT_CREATE + OPT_UPDATE + OPT_RELEASE + OPT_ARCHIVE + OPT_DELETE))
		if [ "$version_mode_count" -ne 1 ]; then
			usage >&2
			error "version requires exactly one mode: --list, --create, --update, --release, or --archive"
			exit 2
		fi
		if [ "$OPT_LIST" -eq 1 ] || [ "$OPT_CREATE" -eq 1 ]; then
			[ -n "$OPT_PROJECT" ] || { usage >&2; error "version --list/--create requires --project"; exit 2; }
			validate_project_key "$OPT_PROJECT" || { usage >&2; error "invalid project key: $OPT_PROJECT"; exit 2; }
		fi
		if [ "$OPT_CREATE" -eq 1 ]; then
			[ -n "$OPT_NAME" ] || { usage >&2; error "version --create requires --name"; exit 2; }
		fi
		if [ "$OPT_UPDATE" -eq 1 ] || [ "$OPT_RELEASE" -eq 1 ] || [ "$OPT_ARCHIVE" -eq 1 ]; then
			[ -n "$OPT_ID" ] || { usage >&2; error "version --update/--release/--archive requires --id"; exit 2; }
			validate_numeric_id "$OPT_ID" || { usage >&2; error "invalid --id (must be a numeric version id): $OPT_ID"; exit 2; }
		fi
		if [ "$OPT_UPDATE" -eq 1 ]; then
			if [ -z "$OPT_NAME" ] && [ -z "$OPT_DESCRIPTION" ] && [ -z "$OPT_RELEASE_DATE" ] && [ -z "$OPT_START_DATE" ]; then
				usage >&2
				error "version --update requires at least one field to change (--name/--description/--release-date/--start-date)"
				exit 2
			fi
		fi
		if [ -n "$OPT_MOVE_ISSUES_TO" ]; then
			usage >&2
			error "--move-issues-to is only valid with component --delete"
			exit 2
		fi
		;;
	component)
		if [ -n "$TICKET_KEY" ]; then
			usage >&2
			error "component takes no positional argument, got: $TICKET_KEY"
			exit 2
		fi
		# --release/--archive are VERSION modes, not component modes. Without
		# this, `component --list --release` would count exactly one OWN
		# component mode (--list) and silently run the list, ignoring the
		# foreign --release. Reject by name, and fold both commands' mode flags
		# into the exactly-one count for defense in depth.
		if [ "$OPT_RELEASE" -eq 1 ] || [ "$OPT_ARCHIVE" -eq 1 ]; then
			usage >&2
			error "--release/--archive are not component modes (did you mean 'version --release/--archive'?)"
			exit 2
		fi
		component_mode_count=$((OPT_LIST + OPT_CREATE + OPT_UPDATE + OPT_DELETE + OPT_RELEASE + OPT_ARCHIVE))
		if [ "$component_mode_count" -ne 1 ]; then
			usage >&2
			error "component requires exactly one mode: --list, --create, --update, or --delete"
			exit 2
		fi
		if [ "$OPT_LIST" -eq 1 ] || [ "$OPT_CREATE" -eq 1 ]; then
			[ -n "$OPT_PROJECT" ] || { usage >&2; error "component --list/--create requires --project"; exit 2; }
			validate_project_key "$OPT_PROJECT" || { usage >&2; error "invalid project key: $OPT_PROJECT"; exit 2; }
		fi
		if [ "$OPT_CREATE" -eq 1 ]; then
			[ -n "$OPT_NAME" ] || { usage >&2; error "component --create requires --name"; exit 2; }
		fi
		if [ "$OPT_UPDATE" -eq 1 ] || [ "$OPT_DELETE" -eq 1 ]; then
			[ -n "$OPT_ID" ] || { usage >&2; error "component --update/--delete requires --id"; exit 2; }
			validate_numeric_id "$OPT_ID" || { usage >&2; error "invalid --id (must be a numeric component id): $OPT_ID"; exit 2; }
		fi
		if [ "$OPT_UPDATE" -eq 1 ]; then
			if [ -z "$OPT_NAME" ] && [ -z "$OPT_DESCRIPTION" ] && [ -z "$OPT_LEAD_ACCOUNT_ID" ]; then
				usage >&2
				error "component --update requires at least one field to change (--name/--description/--lead-account-id)"
				exit 2
			fi
		fi
		if [ -n "$OPT_MOVE_ISSUES_TO" ]; then
			if [ "$OPT_DELETE" -ne 1 ]; then
				usage >&2
				error "--move-issues-to is only valid with component --delete"
				exit 2
			fi
			validate_numeric_id "$OPT_MOVE_ISSUES_TO" || { usage >&2; error "invalid --move-issues-to (must be a numeric component id): $OPT_MOVE_ISSUES_TO"; exit 2; }
		fi
		;;
	attach)
		# --create/--update/--release/--archive are version/component modes,
		# not attach modes — reject by name (clear message; same defense as
		# version/component's foreign-flag guards), and additionally fold every
		# foreign mode flag into the exactly-one count below so no foreign mode
		# passes unnoticed even if one is added later.
		if [ "$OPT_CREATE" -eq 1 ] || [ "$OPT_UPDATE" -eq 1 ] || [ "$OPT_RELEASE" -eq 1 ] || [ "$OPT_ARCHIVE" -eq 1 ]; then
			usage >&2
			error "--create/--update/--release/--archive are not attach modes"
			exit 2
		fi
		# Exactly one of: --file present (upload) | --list | --delete.
		attach_upload=0
		[ -n "$OPT_FILES" ] && attach_upload=1
		attach_mode_count=$((attach_upload + OPT_LIST + OPT_DELETE + OPT_CREATE + OPT_UPDATE + OPT_RELEASE + OPT_ARCHIVE))
		if [ "$attach_mode_count" -ne 1 ]; then
			usage >&2
			error "attach requires exactly one mode: --file PATH (upload), --list, or --delete --id N"
			exit 2
		fi
		# --id is a --delete-only selector; upload/list address the issue by KEY.
		if [ -n "$OPT_ID" ] && [ "$OPT_DELETE" -ne 1 ]; then
			usage >&2
			error "--id is only valid with attach --delete"
			exit 2
		fi
		if [ "$attach_upload" -eq 1 ] || [ "$OPT_LIST" -eq 1 ]; then
			[ -n "$TICKET_KEY" ] || { usage >&2; error "attach upload/--list requires a ticket key, e.g.: attach PROJ-1 --file PATH"; exit 2; }
			validate_ticket_key "$TICKET_KEY" || { usage >&2; error "invalid ticket key: $TICKET_KEY"; exit 2; }
		fi
		if [ "$attach_upload" -eq 1 ]; then
			# Each --file must exist + be readable BEFORE any network call
			# (usage error, exit 2). while-read runs in THIS shell so an exit
			# inside require_readable_file aborts the whole script as intended.
			while IFS= read -r attach_file_path; do
				[ -n "$attach_file_path" ] || continue
				require_readable_file "$attach_file_path" "--file"
			done <<-ATTACH_FILES_EOF
			$OPT_FILES
			ATTACH_FILES_EOF
		fi
		if [ "$OPT_DELETE" -eq 1 ]; then
			if [ -n "$TICKET_KEY" ]; then
				usage >&2
				error "attach --delete takes no ticket key (it deletes by --id): $TICKET_KEY"
				exit 2
			fi
			[ -n "$OPT_ID" ] || { usage >&2; error "attach --delete requires --id N"; exit 2; }
			validate_numeric_id "$OPT_ID" || { usage >&2; error "invalid --id (must be a numeric attachment id): $OPT_ID"; exit 2; }
		fi
		;;
	bulk)
		# bulk takes NO positional — the set is named by --keys/--jql, so a
		# stray positional (e.g. a copy-pasted ticket key) fails loud rather
		# than being silently ignored (same reasoning as search/version).
		if [ -n "$TICKET_KEY" ]; then
			usage >&2
			error "bulk takes no positional argument, got: $TICKET_KEY (use --keys or --jql)"
			exit 2
		fi
		# --op is required and must name one of the three loopable verbs.
		case "$OPT_OP" in
			transition|comment|update) : ;;
			'') usage >&2; error "bulk requires --op transition|comment|update"; exit 2 ;;
			*)  usage >&2; error "invalid --op '$OPT_OP' (must be transition|comment|update)"; exit 2 ;;
		esac
		# Exactly one set selector: --keys XOR --jql.
		if [ -n "$OPT_KEYS" ] && [ -n "$OPT_JQL" ]; then
			usage >&2
			error "bulk requires exactly one of --keys or --jql, not both"
			exit 2
		fi
		if [ -z "$OPT_KEYS" ] && [ -z "$OPT_JQL" ]; then
			usage >&2
			error "bulk requires a set selector: --keys CSV or --jql QUERY"
			exit 2
		fi
		# Every --keys entry is shape-validated HERE (usage error, exit 2)
		# before it can ever become a URL path segment downstream — via the
		# SAME split_keys_csv helper resolve_bulk_keys_file uses (one idiom,
		# no divergence). An empty CSV (only whitespace/commas) is a usage error.
		if [ -n "$OPT_KEYS" ]; then
			bulk_keys_seen=0
			while IFS= read -r bulk_validate_key; do
				[ -n "$bulk_validate_key" ] || continue
				bulk_keys_seen=1
				validate_ticket_key "$bulk_validate_key" || { usage >&2; error "invalid ticket key in --keys: $bulk_validate_key"; exit 2; }
			done <<-BULK_KEYS_EOF
			$(split_keys_csv "$OPT_KEYS")
			BULK_KEYS_EOF
			[ "$bulk_keys_seen" -eq 1 ] || { usage >&2; error "--keys contained no ticket keys"; exit 2; }
		fi
		# Op-specific required arguments — the SAME preconditions the single
		# verb enforces, asserted up front so a batch never starts before its
		# per-issue change is fully specified.
		case "$OPT_OP" in
			transition)
				[ -n "$OPT_STATUS" ] || { usage >&2; error "bulk --op transition requires --status TARGET"; exit 2; }
				;;
			comment)
				[ -n "$OPT_TEXT_FILE" ] || { usage >&2; error "bulk --op comment requires --text-file PATH"; exit 2; }
				;;
			update)
				if [ -z "$OPT_TITLE" ] && [ -z "$OPT_DESCRIPTION_FILE" ] && [ -z "$OPT_APPEND_FILE" ] \
					&& [ -z "$OPT_ACCEPTANCE_FILE" ] && [ -z "$OPT_REVIEW_FILE" ] && [ -z "$OPT_ASSIGNEE" ] \
					&& [ -z "$OPT_DEVELOPER" ] && [ -z "$OPT_LABELS" ] && [ -z "$OPT_DUE_DATE" ] && [ -z "$OPT_PARENT" ] \
					&& [ -z "$OPT_FIX_VERSIONS" ] && [ -z "$OPT_AFFECTS_VERSIONS" ] && [ -z "$OPT_COMPONENTS" ]; then
					usage >&2
					error "bulk --op update requires at least one field to change"
					exit 2
				fi
				if [ -n "$OPT_DESCRIPTION_FILE" ] && [ -n "$OPT_APPEND_FILE" ]; then
					usage >&2
					error "--description-file and --append-file are mutually exclusive"
					exit 2
				fi
				;;
		esac
		;;
	boards)
		# boards takes NO positional (it addresses boards via --project/--type) —
		# a stray one fails loud, same reasoning as search/version.
		if [ -n "$TICKET_KEY" ]; then
			usage >&2
			error "boards takes no positional argument, got: $TICKET_KEY (use --project)"
			exit 2
		fi
		if [ -n "$OPT_PROJECT" ]; then
			validate_project_key "$OPT_PROJECT" || { usage >&2; error "invalid project key: $OPT_PROJECT"; exit 2; }
		fi
		if [ -n "$OPT_TYPE" ]; then
			validate_board_type "$OPT_TYPE" || { usage >&2; error "invalid --type '$OPT_TYPE' (must be scrum|kanban|simple)"; exit 2; }
		fi
		;;
	board)
		[ -n "$TICKET_KEY" ] || { usage >&2; error "board requires a numeric board id, e.g.: board 826"; exit 2; }
		validate_numeric_id "$TICKET_KEY" || { usage >&2; error "invalid board id (must be numeric): $TICKET_KEY"; exit 2; }
		;;
	sprints)
		[ -n "$TICKET_KEY" ] || { usage >&2; error "sprints requires a numeric board id, e.g.: sprints 826"; exit 2; }
		validate_numeric_id "$TICKET_KEY" || { usage >&2; error "invalid board id (must be numeric): $TICKET_KEY"; exit 2; }
		if [ -n "$OPT_STATE" ]; then
			validate_sprint_states "$OPT_STATE" || { usage >&2; error "invalid --state '$OPT_STATE' (comma-separated: active|future|closed)"; exit 2; }
		fi
		;;
	sprint)
		# sprint is READ (positional id, optional --issues) OR one WRITE mode
		# (--create/--update/--start/--close). --delete/--release/--archive/--list
		# are foreign modes (version/component/attach) — reject by name, the same
		# by-name foreign-flag guard version/component use, then fold the sprint
		# modes into an exactly-one-write count.
		if [ "$OPT_DELETE" -eq 1 ] || [ "$OPT_RELEASE" -eq 1 ] || [ "$OPT_ARCHIVE" -eq 1 ] || [ "$OPT_LIST" -eq 1 ]; then
			usage >&2
			error "--delete/--release/--archive/--list are not sprint modes"
			exit 2
		fi
		sprint_write_count=$((OPT_CREATE + OPT_UPDATE + OPT_START + OPT_CLOSE))
		if [ "$sprint_write_count" -gt 1 ]; then
			usage >&2
			error "sprint requires exactly one write mode: --create, --update, --start, or --close"
			exit 2
		fi
		if [ "$sprint_write_count" -eq 0 ]; then
			# READ: a numeric sprint id, no write-only flags.
			[ -n "$TICKET_KEY" ] || { usage >&2; error "sprint requires a numeric sprint id, e.g.: sprint 2212"; exit 2; }
			validate_numeric_id "$TICKET_KEY" || { usage >&2; error "invalid sprint id (must be numeric): $TICKET_KEY"; exit 2; }
			if [ -n "$OPT_BOARD" ] || [ -n "$OPT_GOAL" ] || [ -n "$OPT_NAME" ] || [ -n "$OPT_START_DATE" ] || [ -n "$OPT_END_DATE" ]; then
				usage >&2
				error "sprint read takes no --board/--goal/--name/--start-date/--end-date (did you mean a write mode?)"
				exit 2
			fi
		elif [ "$OPT_CREATE" -eq 1 ]; then
			# create: NO positional (the sprint doesn't exist yet); --board + --name.
			if [ -n "$TICKET_KEY" ]; then
				usage >&2
				error "sprint --create takes no positional (use --board and --name): $TICKET_KEY"
				exit 2
			fi
			if [ "$OPT_ISSUES" -eq 1 ]; then usage >&2; error "--issues is a read modifier, not valid with sprint --create"; exit 2; fi
			[ -n "$OPT_BOARD" ] || { usage >&2; error "sprint --create requires --board BOARD_ID"; exit 2; }
			validate_numeric_id "$OPT_BOARD" || { usage >&2; error "invalid --board (must be a numeric board id): $OPT_BOARD"; exit 2; }
			[ -n "$OPT_NAME" ] || { usage >&2; error "sprint --create requires --name STR"; exit 2; }
			if [ -n "$OPT_START_DATE" ]; then
				validate_iso_datetime "$OPT_START_DATE" || { usage >&2; error "invalid --start-date (expected ISO-8601, e.g. 2026-07-26T10:00:00.000Z): $OPT_START_DATE"; exit 2; }
			fi
			if [ -n "$OPT_END_DATE" ]; then
				validate_iso_datetime "$OPT_END_DATE" || { usage >&2; error "invalid --end-date (expected ISO-8601, e.g. 2026-08-02T10:00:00.000Z): $OPT_END_DATE"; exit 2; }
			fi
		else
			# update / start / close: positional numeric sprint id; --board rejected.
			[ -n "$TICKET_KEY" ] || { usage >&2; error "sprint --update/--start/--close requires a numeric sprint id, e.g.: sprint 2212 --close"; exit 2; }
			validate_numeric_id "$TICKET_KEY" || { usage >&2; error "invalid sprint id (must be numeric): $TICKET_KEY"; exit 2; }
			if [ "$OPT_ISSUES" -eq 1 ]; then usage >&2; error "--issues is a read modifier, not valid with a sprint write mode"; exit 2; fi
			if [ -n "$OPT_BOARD" ]; then usage >&2; error "--board is only valid with sprint --create"; exit 2; fi
			if [ "$OPT_UPDATE" -eq 1 ]; then
				if [ -z "$OPT_NAME" ] && [ -z "$OPT_GOAL" ] && [ -z "$OPT_START_DATE" ] && [ -z "$OPT_END_DATE" ]; then
					usage >&2
					error "sprint --update requires at least one field to change (--name/--goal/--start-date/--end-date)"
					exit 2
				fi
				if [ -n "$OPT_START_DATE" ]; then
					validate_iso_datetime "$OPT_START_DATE" || { usage >&2; error "invalid --start-date (expected ISO-8601, e.g. 2026-07-26T10:00:00.000Z): $OPT_START_DATE"; exit 2; }
				fi
				if [ -n "$OPT_END_DATE" ]; then
					validate_iso_datetime "$OPT_END_DATE" || { usage >&2; error "invalid --end-date (expected ISO-8601, e.g. 2026-08-02T10:00:00.000Z): $OPT_END_DATE"; exit 2; }
				fi
			fi
			if [ "$OPT_START" -eq 1 ]; then
				# start REQUIRES both dates; --name/--goal are not part of a start.
				[ -n "$OPT_START_DATE" ] || { usage >&2; error "sprint --start requires --start-date ISO (start needs both dates)"; exit 2; }
				[ -n "$OPT_END_DATE" ]   || { usage >&2; error "sprint --start requires --end-date ISO (start needs both dates)"; exit 2; }
				validate_iso_datetime "$OPT_START_DATE" || { usage >&2; error "invalid --start-date (expected ISO-8601, e.g. 2026-07-26T10:00:00.000Z): $OPT_START_DATE"; exit 2; }
				validate_iso_datetime "$OPT_END_DATE"   || { usage >&2; error "invalid --end-date (expected ISO-8601, e.g. 2026-08-02T10:00:00.000Z): $OPT_END_DATE"; exit 2; }
				if [ -n "$OPT_NAME" ] || [ -n "$OPT_GOAL" ]; then
					usage >&2
					error "sprint --start takes only --start-date/--end-date (rename/re-goal with --update)"
					exit 2
				fi
			fi
			if [ "$OPT_CLOSE" -eq 1 ]; then
				if [ -n "$OPT_NAME" ] || [ -n "$OPT_GOAL" ] || [ -n "$OPT_START_DATE" ] || [ -n "$OPT_END_DATE" ]; then
					usage >&2
					error "sprint --close takes no fields (it only sets state=closed)"
					exit 2
				fi
			fi
		fi
		;;
	backlog)
		[ -n "$TICKET_KEY" ] || { usage >&2; error "backlog requires a numeric board id, e.g.: backlog 826"; exit 2; }
		validate_numeric_id "$TICKET_KEY" || { usage >&2; error "invalid board id (must be numeric): $TICKET_KEY"; exit 2; }
		;;
	epics)
		[ -n "$TICKET_KEY" ] || { usage >&2; error "epics requires a numeric board id, e.g.: epics 826"; exit 2; }
		validate_numeric_id "$TICKET_KEY" || { usage >&2; error "invalid board id (must be numeric): $TICKET_KEY"; exit 2; }
		;;
	epic)
		[ -n "$TICKET_KEY" ] || { usage >&2; error "epic requires a numeric epic id, e.g.: epic 91591 --issues"; exit 2; }
		validate_numeric_id "$TICKET_KEY" || { usage >&2; error "invalid epic id (must be numeric): $TICKET_KEY"; exit 2; }
		[ "$OPT_ISSUES" -eq 1 ] || { usage >&2; error "epic requires --issues (its issues are the only supported epic read)"; exit 2; }
		;;
esac

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
esac
