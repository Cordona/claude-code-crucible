# shellcheck shell=sh
#
# usage.sh — the `--help` text (usage()) plus need_arg(), the flag-value guard
#            every option in jira.sh's argv loop runs before consuming its
#            argument.
#
# THE CLI SYNOPSIS LIVES IN usage() BELOW — ONE COPY, NOWHERE ELSE. Every
# command, flag and mode is spelled out there, and `jira.sh --help` renders it
# verbatim, so it cannot drift from what the engine actually accepts. A second
# synopsis used to sit here in this header; it silently fell twelve commands
# behind and was deleted. Do not reintroduce one — add the command to usage().
#
# What DOES live here is the per-flag SEMANTIC reference: what each flag means,
# why it behaves the way it does, and which commands it applies to — the detail
# usage() deliberately omits to stay skimmable. It moved here from jira.sh's own
# header, next to the help text it expands on, when the engine was split.
#
#   --confirmed-site SITE   REQUIRED on every command. The
#                            human-confirmed Jira Cloud site, e.g.
#                            "mycompany.atlassian.net" (an "https://" prefix
#                            and/or trailing path are stripped). This is NOT
#                            optional and there is no default — a command
#                            given without it fails closed before any
#                            network call. See "Site gate" below.
#   --project KEY            (search, create, version/component --list and
#                            --create) The project key the command works in.
#                            Additionally, on `version --delete` ONLY, it is
#                            an OPTIONAL ownership CROSS-CHECK rather than a
#                            selector: given, the version is fetched first and
#                            the delete is REFUSED (exit 1, before any write)
#                            unless the version really belongs to KEY; omitted,
#                            the delete behaves exactly as it always has. A
#                            version id is SITE-GLOBAL, so this is the only
#                            way to pin a delete to the project you meant.
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
#   --priority NAME              (create, update) -> fields.priority.name.
#                            STRICTLY OPT-IN: the field is sent ONLY when this
#                            flag is given, and is never defaulted (a project
#                            whose screen carries no priority field 400s if the
#                            script sets one unasked — the same reasoning as
#                            --resolution below). NAME is NOT validated locally
#                            against a fixed enum, because a priority scheme is
#                            per-project on the Jira side: the site is the only
#                            source of truth, and an unknown name 400s clearly.
#                            Accepted by create, update and `bulk --op update`
#                            (which loops update) and by NOTHING else: every
#                            other command REJECTS it (usage error, exit 2)
#                            rather than ignore it — a dropped --priority would
#                            never appear in the --plan/consent disclosure, so
#                            the caller would believe they set a priority the
#                            engine never sent.
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
#   --plan, --dry-run              (transition, bulk, schedule, version
#                            --delete) One flag, one meaning everywhere:
#                            DISCLOSE what the real run would do and MUTATE
#                            NOTHING — the reads a plan needs still happen, no
#                            write ever does, and the output ends on the same
#                            "NOTHING WAS WRITTEN (dry-run / --plan)" line.
#                            transition prints the full walked path (+ any
#                            resolution/injected comment); bulk/schedule print
#                            the resolved issue set + the single change; and
#                            version --delete prints what the --id actually
#                            resolves to (name + owning project key) plus the
#                            exact DELETE it would send — the site-global id
#                            space is why seeing that first matters. This is
#                            what the orchestrator's P4 consent gate discloses
#                            BEFORE authorizing the real write.
#                            The two SIBLING deletes — component --delete and
#                            attach --delete — implement NO preview, so they
#                            REJECT this flag (usage error, exit 2) rather than
#                            ignore it: a caller who believes they asked for a
#                            dry run must never get a real, irreversible delete.
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
# The ENVIRONMENT is not a flag surface, but two variables change what the
# engine will do at all, so they belong in the same reference:
#
#   $JIRA_READ_ONLY            Set it (any value but empty or "0") and EVERY
#                            write command is REFUSED — exit 1, before any
#                            network call and before a credential is
#                            resolved. Reads are untouched. It exists so the
#                            "this credential may only read" scope of an
#                            analysis pass is enforced by the ENGINE rather
#                            than by prose the caller is trusted to follow —
#                            that caller reads untrusted, attacker-authorable
#                            ticket text while holding the credential. The
#                            write/read classification (the one read-mode
#                            carve-out, `transition --plan`, and the one
#                            LOCAL write it refuses, `discover --write`)
#                            lives in lib/readonlygate.sh.
#   $JIRA_CURL_CONFIG          The credential handoff from procedure-jira-auth
#                            — a `curl -K` config file, consumed as-is and
#                            never deleted by this engine. Its BASENAME must
#                            be "<confirmed-host>.cfg" (the one-file-per-site
#                            name that skill stores; compared
#                            case-insensitively, because hostnames are), or
#                            the engine refuses it (exit 1) rather than spend
#                            a credential that may belong to a different Jira
#                            site.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

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
         [--priority NAME] [--fix-version NAME]... [--affects-version NAME]...
         [--component NAME]... [--json]
  $PROG comment <KEY> --text-file PATH --confirmed-site SITE [--json]
  $PROG transition <KEY> --status TARGET --confirmed-site SITE
         [--resolution STR] [--plan|--dry-run] [--json]
  $PROG update <KEY> --confirmed-site SITE
         [--title STR] [--description-file PATH | --append-file PATH]
         [--acceptance-file PATH] [--review-file PATH]
         [--assignee VALUE] [--developer VALUE] [--labels LIST]
         [--due-date YYYY-MM-DD] [--parent KEY] [--priority NAME]
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
         | --archive --id N
         | --delete --id N [--move-fix-issues-to N2]
             [--move-affected-issues-to N3] [--project KEY]
             [--plan|--dry-run]) [--json]
  (version --delete: a version id is SITE-GLOBAL, so --plan/--dry-run previews
  what the id resolves to and writes nothing, and --project KEY refuses the
  delete unless the version really belongs to KEY)
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
         [update: --title/--labels/--assignee/--due-date/--parent/--priority/... ]
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

Usage (AGILE WRITE — issue scheduling, base /rest/agile/1.0/ + api/3):
  $PROG schedule --confirmed-site SITE
         (--to-sprint SPRINT_ID | --to-backlog --board BOARD_ID
          | --to-epic EPIC_KEY | --from-epic)
         (--keys "K-1,K-2,..." | --jql QUERY) [--plan|--dry-run] [--json]
  (exactly one target op + exactly one issue selector; --dry-run discloses the
  plan and mutates NOTHING; sprint/backlog move the whole set in one call,
  epic assign/remove is a per-issue PUT loop with partial-failure reporting)

--confirmed-site SITE is REQUIRED on every command (fails closed if absent
or if it mismatches the intended site — see the script header). See the
script header for the full flag reference and transition --plan's contract.

Environment:
  JIRA_READ_ONLY     Set (any value but empty or "0") -> every WRITE command
                     is refused with exit 1 before any network call; reads
                     and transition --plan still work. discover --write counts
                     as a write (it overwrites the local project config).
  JIRA_CURL_CONFIG   The -K credential-config path from
                     procedure-jira-auth. Its basename must be
                     "<confirmed-host>.cfg" (case-insensitive) or it is
                     refused (exit 1).

link direction: \`link FROM --to TO --link-type NAME\` reads "FROM <type>
TO" in active voice (FROM -> inwardIssue, TO -> outwardIssue; verified
live). Run link-types first to see a type's exact inward/outward wording.

Exit codes:
  0  success
  1  curl/jq absent / credentials unavailable / JIRA_READ_ONLY set on a write
     command / JIRA_CURL_CONFIG not named for the confirmed site /
     site gate failed / an API
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
