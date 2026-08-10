# shellcheck shell=sh
#
# validate.sh — input-shape predicates: pure, network-free allow-shape checks
#               run BEFORE a value can become a URL path segment, a query
#               value, a file path, or a JSON literal.
#
# Every predicate uses `case`/parameter-expansion whole-string matching rather
# than a line-anchored `grep -Eq '^...$'`, so a value with an EMBEDDED newline
# cannot match on its first line while the whole string is malformed.
#
# GUARD VOCABULARY — the verb names an EXIT CONTRACT, not a subject, so a new
# guard picks its verb from what it does on failure, never from what it looks
# at: `validate_*` is a pure predicate (returns 0/1, exits nothing, leaves the
# diagnostic to its caller), `require_*` is a usage guard (prints usage +
# a diagnostic and exits 2), `assert_*` is a precondition guard (exits 1).
# There is no fourth verb; a guard that reads as "reject/refuse X" is still a
# `require_*` when it exits 2 (hence require_foreign_flag_unset below).
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

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

# require_readable_file PATH FLAG_NAME — a usage-error guard (exit 2) shared
# by every --*-file flag across create/comment/update.
require_readable_file() {
	rrf_file_path=$1
	rrf_flag_name=$2
	if [ ! -f "$rrf_file_path" ] || [ ! -r "$rrf_file_path" ]; then
		usage >&2
		error "$rrf_flag_name does not exist or is not readable: $rrf_file_path"
		exit 2
	fi
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

# require_ticket_positional CMD — the "this command takes exactly one ticket
# key" prelude shared by view, workflow and children. It was ONE case arm before
# the engine was split; splitting it across three command files is what created
# the duplication, so this is the de-duplication that split requires rather than
# a pre-existing one. CMD is the command's own name, so both diagnostics read
# exactly as they did when $COMMAND supplied it.
require_ticket_positional() {
	rtp_command=$1
	[ -n "$TICKET_KEY" ] || { usage >&2; error "$rtp_command requires a ticket key, e.g.: $rtp_command PROJ-123"; exit 2; }
	validate_ticket_key "$TICKET_KEY" || { usage >&2; error "invalid ticket key: $TICKET_KEY"; exit 2; }
	return 0
}

# require_iso_date FLAG_DESC VALUE — the ISO-8601 guard behind sprint's
# --start-date/--end-date, at all six of its call sites.
#
# FLAG_DESC deliberately carries the flag name AND its own example date as ONE
# parameter: the two differ per flag and travel together into the diagnostic, so
# splitting them would let a caller pair --end-date with --start-date's example
# and produce a message that quietly teaches the wrong format.
require_iso_date() {
	rid_flag_desc=$1
	rid_value=$2
	validate_iso_datetime "$rid_value" || { usage >&2; error "invalid $rid_flag_desc: $rid_value"; exit 2; }
	return 0
}

# require_delete_move_target FLAG_NAME VALUE OWNER_CMD ID_KIND — the guard
# behind EVERY `--delete` mode's OPTIONAL reassignment target: `version
# --delete`'s --move-fix-issues-to/--move-affected-issues-to and `component
# --delete`'s --move-issues-to. All three carry the SAME two rules — meaningful
# only while deleting, and a numeric id of the deleted entity's own kind — so
# they are stated once here rather than copied per flag and per command.
#
# FLAG_NAME, OWNER_CMD and ID_KIND are all parameters, for the one reason:
# every part of the two diagnostics that VARIES between call sites travels as
# an argument, so each message names the flag the CALLER actually passed, the
# command that owns it, and the id kind it wants — never a sibling's. (A caller
# who supplied only one of version's two targets must not be told about the
# other; a component caller must not be told "version --delete".) Same reason
# require_iso_date takes its FLAG_DESC and require_foreign_flag_unset its
# OWNER_CMD.
#
# Call it only for a NON-EMPTY value — absent is legal (every target is
# optional), so presence is the call site's own precondition, exactly as it is
# for require_iso_date.
require_delete_move_target() {
	rdmt_flag_name=$1
	rdmt_value=$2
	rdmt_owner_cmd=$3
	rdmt_id_kind=$4
	if [ "$OPT_DELETE" -ne 1 ]; then
		usage >&2
		error "$rdmt_flag_name is only valid with $rdmt_owner_cmd"
		exit 2
	fi
	validate_numeric_id "$rdmt_value" || { usage >&2; error "invalid $rdmt_flag_name (must be a numeric $rdmt_id_kind id): $rdmt_value"; exit 2; }
	return 0
}

# require_foreign_flag_unset FLAG_NAME VALUE OWNER_CMD — refuse a flag that
# belongs to a DIFFERENT command. The shared OPT_* carriers mean version's
# parser happily stores component's --move-issues-to (and vice versa) while the
# handler never reads it, so an unguarded misuse would exit 0 having done the
# destructive part and SILENTLY dropped the reassignment the caller asked for.
# Each command therefore rejects its siblings' reassignment flags, which is what
# made several copies of this same five-line block.
#
# OWNER_CMD is a parameter because the diagnostic must name the command that
# DOES accept the flag ("component --delete" vs "version --delete"); FLAG_NAME
# is one for the same reason require_delete_move_target takes it — a caller who
# passed only one flag must not be told about the other.
#
# Unlike require_delete_move_target, this guard tests VALUE itself rather than
# leaving presence to the call site: presence is the ENTIRE rule here (there is
# no second check to run on a valid value), so keeping it inside collapses each
# site to one line instead of one line plus an `if`.
require_foreign_flag_unset() {
	rffu_flag_name=$1
	rffu_value=$2
	rffu_owner_cmd=$3
	if [ -n "$rffu_value" ]; then
		usage >&2
		error "$rffu_flag_name is only valid with $rffu_owner_cmd"
		exit 2
	fi
	return 0
}

# require_flag_off FLAG_NAME FLAG_STATE OWNER_DESC — the 0/1-CARRIER twin of
# require_foreign_flag_unset, for a flag whose carrier is a boolean counter
# rather than a string. It exists because the two carriers test differently and
# cannot share one guard: OPT_PLAN is always literally "0" or "1", so
# `[ -n "$OPT_PLAN" ]` is TRUE even when the flag was never passed and
# require_foreign_flag_unset would reject every invocation.
#
# Same message shape ("$FLAG is only valid with $OWNER"), same exit-2 usage
# contract, same reason FLAG_NAME and OWNER_DESC are parameters: every varying
# part of the diagnostic travels as an argument so each site names the flag the
# caller actually typed and the command that really does implement it.
#
# The motivating case is `--plan`/`--dry-run` on a destructive command that
# implements NO preview. A silently-ignored `--plan` is the worst possible
# failure here — the caller believes they asked for a dry run and gets a real,
# irreversible delete — so it must fail loud, exit 2, before any network call.
require_flag_off() {
	rfo_flag_name=$1
	rfo_flag_state=$2
	rfo_owner_desc=$3
	if [ "$rfo_flag_state" -eq 1 ]; then
		usage >&2
		error "$rfo_flag_name is only valid with $rfo_owner_desc"
		exit 2
	fi
	return 0
}
