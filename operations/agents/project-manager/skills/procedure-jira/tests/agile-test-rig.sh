#!/usr/bin/env sh
#
# agile-test-rig.sh — a PARANOID, guarded live-test rig for jira.sh's Agile
# sprint-lifecycle WRITE commands. It stands up an ISOLATED, disposable Agile
# environment (a run-scoped filter + scrum board), exercises the sprint verbs
# against it, and tears it down — with FIVE independent guard layers that each
# make it structurally impossible to mutate a real, pre-existing artifact.
#
# ┌─ THIS SCRIPT IS TEST INFRASTRUCTURE, NOT AN ENGINE COMMAND. ───────────────┐
# │ It is BUILT and its guard logic is UNIT-TESTED locally (tests/run-rig-      │
# │ tests.sh) with a STUBBED curl + a hand-written manifest fixture — ZERO      │
# │ network. Running it against a LIVE Jira is a SEPARATE, human-run step.      │
# └────────────────────────────────────────────────────────────────────────────┘
#
# A SIXTH, STRUCTURAL layer wraps the engine's own sprint WRITE verbs: the rig
# never calls `jira.sh sprint --create/--start/--close/--update` directly — every
# such call goes through a thin guarded wrapper (rig_sprint_create /
# rig_sprint_start / rig_sprint_close / rig_sprint_update) that ASSERTS the target
# is a minted-this-run artifact (and not in the deny-list) BEFORE the engine is
# invoked, and REFUSES (exit 3, NO engine call) otherwise. The engine acts on
# whatever id it is handed, so this wrapper is the last line: even if orchestration
# passed a real id by mistake, the mutation never reaches the engine.
#
# The five layers (each independently blocks a real-artifact mutation):
#   1. MINT-AND-TRACK  — setup mints a unique RUNID, creates a filter + a scrum
#      board named/scoped with that token, and records EVERY created id into a
#      MANIFEST. Every later mutation reads its target id ONLY from the manifest.
#   2. PRE-EXISTING DENY-LIST — setup snapshots ALL existing board + sprint ids
#      into the manifest's `preexisting` set BEFORE minting anything; a mutation
#      whose target is in that set is refused.
#   3. PROVENANCE VERIFY — guard_mutation asserts the target is (a) in minted,
#      (b) NOT in preexisting, and (c) that the artifact GET'd back carries the
#      exact RUNID token in its name (a sprint via its originBoardId->board).
#   4. EMPTY-BOARD INVARIANT — before creating sprints, the board's backlog must
#      surface ZERO issues (the run label is on no real ticket).
#   5. FAIL-CLOSED TEARDOWN — deletes ONLY minted ids (each through
#      guard_mutation), then GETs each and asserts a 404; any survivor is a loud
#      non-zero report.
#
# HTTP SEAM (why this is locally testable): every network call routes through
# the single indirection rig_curl(), which invokes `curl` on PATH with the SAME
# argv shape jira.sh uses (-o out -w '%{http_code}' -X METHOD [--data @file]
# URL). The unit tests put a canned-response STUB `curl` first on PATH, so every
# guard decision is a pure function of (manifest fixture, stubbed responses) —
# no hidden live dependency.
#
# Subcommands:
#   setup              mint + snapshot + create filter/board + assert empty
#   teardown           delete every minted id (guarded) + verify 404
#   full               setup -> drive jira.sh's real sprint lifecycle
#                      (create -> register-sprint -> start -> close) -> teardown
#   provision          setup -> stand up 3 tagged sprints (future/active/closed)
#                      via the guarded wrappers and LEAVE THEM STANDING (NO
#                      teardown; a human teammate deletes them later). Prints
#                      every created id + the manifest path.
#   sprint-create BOARD_ID   guarded wrapper seam: assert BOARD_ID is a minted
#                      board (+ not in deny-list), then drive jira.sh sprint
#                      --create; refuse (exit 3, no engine call) otherwise
#   sprint-start / sprint-close / sprint-update SPRINT_ID   guarded wrapper seams:
#                      assert SPRINT_ID is a minted sprint (+ not in deny-list),
#                      then drive the matching engine verb; refuse otherwise
#   register-sprint SPRINT_ID   provenance-verify a jira.sh-created sprint (the
#                      SAME two-hop check guard_mutation runs) and, ONLY on
#                      success, append `MINTED sprint <id>` so teardown can
#                      guard-delete it; any failure is a loud refusal, no write
#   guard-check KIND ID   run guard_mutation, and on success issue ONE (sentinel)
#                         DELETE — the seam the unit tests observe to prove a
#                         refusal emits NO mutation and an accept emits exactly one
#   empty-board-check BOARD_ID   run the layer-4 invariant against BOARD_ID
#
# Common flags: --confirmed-site SITE (REQUIRED, host-pinned fail-closed)
#               --project KEY   --runid TOKEN (inject; else minted from urandom)
#               --manifest PATH (default ./crucible-ephemeral-manifest.txt)
#
# Exit codes: 0 ok · 1 error/precondition · 2 usage · 3 GUARD REFUSAL
#             4 teardown survivor · 5 empty-board invariant failed
#
set -eu

# ---------------------------------------------------------------------------
# Constants + state (POSIX sh has no `local`; every name is unique to its
# function's call chain, per jira.sh's convention).
# ---------------------------------------------------------------------------
RIG_LABEL_PREFIX="crucible-ephemeral-"

# The engine under test is a SIBLING script (scripts/jira.sh), resolved from
# $0's own location — never a bare relative path (which would resolve against
# the caller's cwd). The `full` flow drives its REAL sprint WRITE verbs through
# it; the unit suite exercises that same path with the stub `curl` on PATH.
RIG_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RIG_JIRA_SH="$RIG_SCRIPT_DIR/../scripts/jira.sh"

RIG_HOST=""
RIG_PROJECT=""
RIG_RUNID=""
RIG_RUNID_OVERRIDE=""
RIG_MANIFEST="./crucible-ephemeral-manifest.txt"
RIG_WORKDIR=""
RIG_RESP_COUNTER=0
RIG_HTTP_BODY_FILE=""
RIG_HTTP_CODE=""
RIG_CURL_CONFIG="${RIG_CURL_CONFIG:-}"
RIG_FILTER_ID=""
RIG_BOARD_ID=""
RIG_LAST_SPRINT_ID=""
RIG_ARG1=""
RIG_ARG2=""

# ---------------------------------------------------------------------------
# Diagnostics — ALL to stderr (stdout is reserved for any machine output).
# ---------------------------------------------------------------------------
rig_log()  { printf 'rig: %s\n' "$*" >&2; }
rig_die()  { printf 'rig: error: %s\n' "$*" >&2; exit 1; }
rig_usage_die() { printf 'rig: usage: %s\n' "$*" >&2; exit 2; }

# rig_loud MESSAGE — a deliberately UNMISSABLE stderr banner for a guard refusal
# or a safety-invariant breach (the whole point of the rig is that these never
# scroll past unnoticed).
rig_loud() {
	{
		printf '\n'
		printf '!!! ======================================================================\n'
		printf '!!! %s\n' "$*"
		printf '!!! ======================================================================\n'
		printf '\n'
	} >&2
}

# rig_refuse MESSAGE — a guard said NO. Print the loud banner and exit 3
# WITHOUT the caller ever reaching its mutation (guard_mutation is always
# called BEFORE the mutation, so this exit pre-empts it).
rig_refuse() {
	rig_loud "GUARD REFUSED A MUTATION: $*"
	exit 3
}

# ---------------------------------------------------------------------------
# Workdir + cleanup
# ---------------------------------------------------------------------------
ensure_rig_workdir() {
	if [ -z "$RIG_WORKDIR" ]; then
		RIG_WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/agile-rig.XXXXXX")
	fi
}

# shellcheck disable=SC2317  # invoked indirectly via trap
rig_cleanup() { [ -z "$RIG_WORKDIR" ] || rm -rf "$RIG_WORKDIR"; }
trap rig_cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# The single HTTP indirection. Mirrors jira_curl's security posture: host
# pinned to the confirmed site (fail closed), https-only, the auth token stays
# in a `-K` config file (NEVER on argv, so it can't leak via `ps`), no redirect
# followed. Sets RIG_HTTP_BODY_FILE (a fresh file each call) + RIG_HTTP_CODE.
# ---------------------------------------------------------------------------
rig_curl() {
	rc_method=$1
	rc_url=$2
	rc_data=${3:-}

	rc_host=$(printf '%s' "$rc_url" | sed -E 's#^https://##; s#/.*##')
	if [ "$rc_host" != "$RIG_HOST" ]; then
		rig_die "internal: refusing a request to '$rc_host' — it does not match the confirmed site '$RIG_HOST' (fail closed)"
	fi
	case "$rc_url" in
		https://*) : ;;
		*) rig_die "internal: refusing a non-https URL: $rc_url" ;;
	esac

	ensure_rig_workdir
	RIG_RESP_COUNTER=$((RIG_RESP_COUNTER + 1))
	RIG_HTTP_BODY_FILE="$RIG_WORKDIR/resp-$RIG_RESP_COUNTER.json"

	set -- curl -sS --proto '=https' \
		-H 'Accept: application/json' \
		-X "$rc_method" \
		-o "$RIG_HTTP_BODY_FILE" \
		-w '%{http_code}'
	[ -z "$RIG_CURL_CONFIG" ] || set -- "$@" -K "$RIG_CURL_CONFIG"
	if [ -n "$rc_data" ]; then
		set -- "$@" -H 'Content-Type: application/json' --data "@$rc_data"
	fi
	set -- "$@" "$rc_url"

	if ! RIG_HTTP_CODE=$("$@"); then
		rig_die "curl request failed (network/TLS error) for $rc_method $rc_url"
	fi
}

# rig_require_2xx ACTION — die (exit 1) with the response body if the last
# rig_curl was not a 2xx. Used by setup's own creates/reads (NOT by the guarded
# mutations, whose non-2xx is handled by the caller).
rig_require_2xx() {
	case "$RIG_HTTP_CODE" in
		2??) return 0 ;;
	esac
	rig_loud "$1 FAILED (HTTP $RIG_HTTP_CODE)"
	[ -s "$RIG_HTTP_BODY_FILE" ] && cat "$RIG_HTTP_BODY_FILE" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# Manifest — the ONLY source of any mutation target id. A flat, greppable,
# awk-free line log: `RUNID <t>` · `PROJ <k>` · `FILTER/BOARD <id>` ·
# `MINTED <kind> <id>` · `PREEXISTING <kind> <id>`.
# ---------------------------------------------------------------------------
manifest_append() { printf '%s\n' "$1" >>"$RIG_MANIFEST"; }

manifest_runid() {
	[ -f "$RIG_MANIFEST" ] || return 0
	grep -E '^RUNID ' "$RIG_MANIFEST" | sed -n '1s/^RUNID //p'
}

# manifest_minted_has KIND ID / manifest_preexisting_has KIND ID — EXACT whole-
# line match (grep -Fxq), never a substring: a substring test for id "12" would
# also match "123", silently defeating the deny-list.
manifest_minted_has()      { [ -f "$RIG_MANIFEST" ] && grep -Fxq "MINTED $1 $2" "$RIG_MANIFEST"; }
manifest_preexisting_has() { [ -f "$RIG_MANIFEST" ] && grep -Fxq "PREEXISTING $1 $2" "$RIG_MANIFEST"; }

manifest_minted_ids() {
	[ -f "$RIG_MANIFEST" ] || return 0
	grep -E "^MINTED $1 " "$RIG_MANIFEST" | sed -E "s/^MINTED $1 //"
}
manifest_preexisting_ids() {
	[ -f "$RIG_MANIFEST" ] || return 0
	grep -E "^PREEXISTING $1 " "$RIG_MANIFEST" | sed -E "s/^PREEXISTING $1 //"
}

# ---------------------------------------------------------------------------
# Small validators (digits-only id; the fixed artifact-kind set).
# ---------------------------------------------------------------------------
rig_is_digits() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
	esac
}
rig_valid_kind() {
	case "$1" in
		board|sprint|filter) return 0 ;;
		*) return 1 ;;
	esac
}

# rig_valid_runid TOKEN -> 0 iff TOKEN is a run of >=16 LOWERCASE-hex chars
# (`^[0-9a-f]{16,}$`). The run token is the thread every provenance check hangs
# on: guard_provenance trusts a manifest RUNID as a substring match against an
# artifact's name, so a low-entropy or too-short token would make a forged
# name trivially satisfiable ("*$RUNID*" matches almost anything if $RUNID is a
# couple of characters). Enforcing the mint shape at BOTH boundaries — a
# `--runid` override (rig_mint_runid) and the RUNID read back from the manifest
# (guard_mutation) — makes a forged/low-entropy token structurally impossible to
# trust. The 8-bytes-of-urandom mint already produces exactly 16 hex chars.
rig_valid_runid() {
	rvr_token=$1
	case "$rvr_token" in
		''|*[!0-9a-f]*) return 1 ;;
	esac
	[ "${#rvr_token}" -ge 16 ] || return 1
	return 0
}

# rig_artifact_url KIND ID — the canonical URL for an artifact of KIND.
rig_artifact_url() {
	case "$1" in
		board)  printf 'https://%s/rest/agile/1.0/board/%s' "$RIG_HOST" "$2" ;;
		sprint) printf 'https://%s/rest/agile/1.0/sprint/%s' "$RIG_HOST" "$2" ;;
		filter) printf 'https://%s/rest/api/3/filter/%s' "$RIG_HOST" "$2" ;;
		*) rig_die "unknown artifact kind: $1" ;;
	esac
}

# ---------------------------------------------------------------------------
# LAYER 3 — guard_mutation KIND ID: the choke point every mutation passes
# through. Runs three independent checks and REFUSES (exit 3, no mutation) on
# ANY failure. Checks (a)/(b) are pure manifest reads (ZERO network); only the
# provenance check (c) issues a GET — so a refusal at (a)/(b) makes NO curl call
# at all, and a refusal at (c) makes only that read, NEVER a mutation.
# ---------------------------------------------------------------------------
guard_mutation() {
	gm_kind=$1
	gm_id=$2

	rig_valid_kind "$gm_kind" || rig_refuse "unknown artifact kind '$gm_kind'"
	rig_is_digits "$gm_id"     || rig_refuse "$gm_kind id '$gm_id' is not numeric"

	gm_runid=$(manifest_runid)
	[ -n "$gm_runid" ] || rig_refuse "manifest ($RIG_MANIFEST) has no RUNID — refusing to mutate anything"
	# Re-validate the run-token SHAPE read back from the manifest before any
	# provenance match trusts it as a substring: a forged manifest carrying a
	# low-entropy RUNID must not slip a weak token past the guard.
	rig_valid_runid "$gm_runid" \
		|| rig_refuse "manifest RUNID '$gm_runid' is not a valid run token (^[0-9a-f]{16,}\$) — refusing to trust a forged/low-entropy token"

	# (a) target MUST be an id THIS run minted.
	manifest_minted_has "$gm_kind" "$gm_id" \
		|| rig_refuse "$gm_kind $gm_id is NOT in the run manifest's minted set (layer 1/3a) — it was never created by this run"

	# (b) target MUST NOT be in the pre-existing deny-list.
	if manifest_preexisting_has "$gm_kind" "$gm_id"; then
		rig_refuse "$gm_kind $gm_id is in the PRE-EXISTING deny-list (layer 2/3b) — it existed before this run"
	fi

	# (c) the artifact GET'd back MUST carry the exact RUNID token in its name
	#     (a sprint via its originBoardId -> board name).
	guard_provenance "$gm_kind" "$gm_id" "$gm_runid" \
		|| rig_refuse "$gm_kind $gm_id failed provenance (layer 3c) — its name does not carry the run token '$gm_runid'"

	return 0
}

# guard_provenance KIND ID RUNID -> 0 iff the artifact's name carries RUNID.
# For a sprint, the check is its originBoardId's board name — AND that origin
# board must itself be a minted board (never a real one).
guard_provenance() {
	gp_kind=$1
	gp_id=$2
	gp_runid=$3
	case "$gp_kind" in
		board)
			rig_curl GET "https://${RIG_HOST}/rest/agile/1.0/board/${gp_id}"
			gp_name=$(jq -r '.name // ""' "$RIG_HTTP_BODY_FILE" 2>/dev/null || printf '')
			;;
		filter)
			rig_curl GET "https://${RIG_HOST}/rest/api/3/filter/${gp_id}"
			gp_name=$(jq -r '.name // ""' "$RIG_HTTP_BODY_FILE" 2>/dev/null || printf '')
			;;
		sprint)
			rig_curl GET "https://${RIG_HOST}/rest/agile/1.0/sprint/${gp_id}"
			gp_board=$(jq -r '.originBoardId // ""' "$RIG_HTTP_BODY_FILE" 2>/dev/null || printf '')
			rig_is_digits "$gp_board" || return 1
			manifest_minted_has board "$gp_board" || return 1
			rig_curl GET "https://${RIG_HOST}/rest/agile/1.0/board/${gp_board}"
			gp_name=$(jq -r '.name // ""' "$RIG_HTTP_BODY_FILE" 2>/dev/null || printf '')
			;;
		*) return 1 ;;
	esac
	# Literal-substring match: RUNID is hex, so no glob metacharacters, and the
	# quoted expansion keeps the match literal.
	case "$gp_name" in
		*"$gp_runid"*) return 0 ;;
		*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# LAYER 1 + 2 + 4 — setup.
# ---------------------------------------------------------------------------
rig_mint_runid() {
	if [ -n "$RIG_RUNID_OVERRIDE" ]; then
		# An injected --runid is UNTRUSTED: hold it to the exact mint shape so a
		# caller cannot seed a low-entropy/substring token that weakens every
		# later provenance match.
		rig_valid_runid "$RIG_RUNID_OVERRIDE" \
			|| rig_usage_die "--runid must be >=16 lowercase-hex chars (^[0-9a-f]{16,}\$), got '$RIG_RUNID_OVERRIDE'"
		RIG_RUNID=$RIG_RUNID_OVERRIDE
		return 0
	fi
	# 8 bytes of urandom -> 16 hex chars. Deliberately NOT date/$RANDOM (both
	# collide/repeat); od on /dev/urandom is deterministic to test via --runid.
	RIG_RUNID=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
	[ -n "$RIG_RUNID" ] || rig_die "could not mint a run id from /dev/urandom"
}

rig_create_filter() {
	cf_label=$1
	cf_body="$RIG_WORKDIR/filter-create.json"
	# Static jq program; the project key + label travel as VALUES (--arg), never
	# concatenated into the program text.
	jq -n \
		--arg name "CRUCIBLE-EPHEMERAL-${RIG_RUNID}-filter" \
		--arg jql "project=${RIG_PROJECT} AND labels=${cf_label}" \
		'{name: $name, jql: $jql}' >"$cf_body"
	rig_curl POST "https://${RIG_HOST}/rest/api/3/filter" "$cf_body"
	rig_require_2xx "create filter"
	RIG_FILTER_ID=$(jq -r '.id // ""' "$RIG_HTTP_BODY_FILE")
	[ -n "$RIG_FILTER_ID" ] || rig_die "filter create returned no id"
	manifest_append "FILTER $RIG_FILTER_ID"
	manifest_append "MINTED filter $RIG_FILTER_ID"
	rig_log "minted filter $RIG_FILTER_ID"
}

rig_create_board() {
	cb_body="$RIG_WORKDIR/board-create.json"
	jq -n \
		--arg name "CRUCIBLE-EPHEMERAL-${RIG_RUNID}-board" \
		--argjson filterId "$RIG_FILTER_ID" \
		'{name: $name, type: "scrum", filterId: $filterId}' >"$cb_body"
	rig_curl POST "https://${RIG_HOST}/rest/agile/1.0/board" "$cb_body"
	rig_require_2xx "create board"
	RIG_BOARD_ID=$(jq -r '.id // ""' "$RIG_HTTP_BODY_FILE")
	[ -n "$RIG_BOARD_ID" ] || rig_die "board create returned no id"
	manifest_append "BOARD $RIG_BOARD_ID"
	manifest_append "MINTED board $RIG_BOARD_ID"
	rig_log "minted board $RIG_BOARD_ID"
}

# rig_snapshot_preexisting — LAYER 2. Record every existing board id, then every
# existing sprint id (walked per board). Runs BEFORE any mint so our own new
# artifacts can never land in this set.
rig_snapshot_preexisting() {
	sp_start=0
	while :; do
		rig_curl GET "https://${RIG_HOST}/rest/agile/1.0/board?startAt=${sp_start}&maxResults=50"
		rig_require_2xx "snapshot pre-existing boards"
		sp_count=$(jq -r '(.values // []) | length' "$RIG_HTTP_BODY_FILE")
		# Capture the id list to a FILE and CHECK jq's exit status before reading
		# it: a `jq ... | while read` pipe swallows a jq failure under POSIX sh
		# (no pipefail), which for a deny-list builder would silently yield a
		# PARTIAL layer-2 set — unacceptable for a safety control. On any parse
		# failure, fail closed.
		sp_ids_file="$RIG_WORKDIR/snapshot-boards-page-${sp_start}.ids"
		jq -r '.values[]?.id' "$RIG_HTTP_BODY_FILE" >"$sp_ids_file" \
			|| rig_die "failed to parse the pre-existing board snapshot page (jq error) — refusing to build a partial deny-list"
		while IFS= read -r sp_bid; do
			[ -n "$sp_bid" ] || continue
			manifest_append "PREEXISTING board $sp_bid"
		done <"$sp_ids_file"
		sp_islast=$(jq -r 'if .isLast == null then "absent" else (.isLast|tostring) end' "$RIG_HTTP_BODY_FILE")
		[ "$sp_count" -gt 0 ] || break
		[ "$sp_islast" != "true" ] || break
		sp_start=$((sp_start + sp_count))
	done
	# Sprint ids per pre-existing board. Fed via a here-doc so the while loop runs
	# in THIS shell (the board-id list is already committed to the manifest).
	while IFS= read -r sp_board; do
		[ -n "$sp_board" ] || continue
		rig_snapshot_board_sprints "$sp_board"
	done <<SNAP_BOARDS_EOF
$(manifest_preexisting_ids board)
SNAP_BOARDS_EOF
}

rig_snapshot_board_sprints() {
	sbs_board=$1
	sbs_start=0
	while :; do
		rig_curl GET "https://${RIG_HOST}/rest/agile/1.0/board/${sbs_board}/sprint?startAt=${sbs_start}&maxResults=50"
		# A kanban/simple board answers /sprint with a 4xx — tolerate + skip it
		# (it has no sprints to deny-list).
		case "$RIG_HTTP_CODE" in
			2??) : ;;
			*) return 0 ;;
		esac
		sbs_count=$(jq -r '(.values // []) | length' "$RIG_HTTP_BODY_FILE")
		# Same fail-closed capture as the board snapshot above: a swallowed jq
		# failure in a pipe would silently under-populate the sprint deny-list.
		sbs_ids_file="$RIG_WORKDIR/snapshot-sprints-${sbs_board}-page-${sbs_start}.ids"
		jq -r '.values[]?.id' "$RIG_HTTP_BODY_FILE" >"$sbs_ids_file" \
			|| rig_die "failed to parse the pre-existing sprint snapshot page for board $sbs_board (jq error) — refusing to build a partial deny-list"
		while IFS= read -r sbs_sid; do
			[ -n "$sbs_sid" ] || continue
			manifest_append "PREEXISTING sprint $sbs_sid"
		done <"$sbs_ids_file"
		sbs_islast=$(jq -r 'if .isLast == null then "absent" else (.isLast|tostring) end' "$RIG_HTTP_BODY_FILE")
		[ "$sbs_count" -gt 0 ] || break
		[ "$sbs_islast" != "true" ] || break
		sbs_start=$((sbs_start + sbs_count))
	done
}

# rig_assert_board_empty BOARD — LAYER 4. The board's backlog MUST surface zero
# issues; a non-empty backlog means the run label is on a REAL ticket (label
# reuse) — abort loudly WITHOUT creating any sprint.
rig_assert_board_empty() {
	abe_board=$1
	rig_curl GET "https://${RIG_HOST}/rest/agile/1.0/board/${abe_board}/backlog?startAt=0&maxResults=1"
	rig_require_2xx "check board $abe_board backlog is empty"
	abe_total=$(jq -r 'if .total == null then ((.issues // []) | length) else .total end' "$RIG_HTTP_BODY_FILE")
	abe_issues=$(jq -r '(.issues // []) | length' "$RIG_HTTP_BODY_FILE")
	if [ "$abe_total" != "0" ] || [ "$abe_issues" != "0" ]; then
		rig_loud "EMPTY-BOARD INVARIANT FAILED: board $abe_board surfaced $abe_total backlog issue(s) — the run label may be on a REAL ticket. Aborting; nothing beyond the filter/board in $RIG_MANIFEST was created."
		exit 5
	fi
	rig_log "board $abe_board backlog is empty — invariant holds"
}

rig_setup() {
	ensure_rig_workdir
	[ -n "$RIG_PROJECT" ] || rig_usage_die "setup requires --project KEY"
	case "$RIG_PROJECT" in
		''|*[!A-Z0-9]*) rig_usage_die "invalid --project '$RIG_PROJECT' (A-Z/0-9)" ;;
	esac
	rig_resolve_auth
	rig_mint_runid
	: >"$RIG_MANIFEST"
	manifest_append "RUNID $RIG_RUNID"
	manifest_append "PROJ $RIG_PROJECT"
	rig_log "run token $RIG_RUNID (label ${RIG_LABEL_PREFIX}${RIG_RUNID}); manifest $RIG_MANIFEST"

	rig_snapshot_preexisting                               # LAYER 2 (before minting)
	rig_create_filter "${RIG_LABEL_PREFIX}${RIG_RUNID}"    # LAYER 1
	rig_create_board                                       # LAYER 1
	rig_assert_board_empty "$RIG_BOARD_ID"                 # LAYER 4
	rig_log "setup complete — filter $RIG_FILTER_ID, board $RIG_BOARD_ID"
}

# ---------------------------------------------------------------------------
# LAYER 5 — teardown. Delete ONLY minted ids (each through guard_mutation), in
# dependency order (sprints, then board, then filter), and verify each is gone
# (404). Any survivor is a loud non-zero report.
# ---------------------------------------------------------------------------
rig_delete_and_verify() {
	dv_kind=$1
	dv_id=$2
	# guard_mutation exits 3 on ANY doubt — so a mutation we can't prove is ours
	# is NEVER issued (fail closed; teardown aborts rather than delete blindly).
	guard_mutation "$dv_kind" "$dv_id"
	dv_url=$(rig_artifact_url "$dv_kind" "$dv_id")
	rig_curl DELETE "$dv_url"
	case "$RIG_HTTP_CODE" in
		2??) : ;;
		404) rig_log "$dv_kind $dv_id already gone (HTTP 404 on delete)" ;;
		*) rig_loud "delete of $dv_kind $dv_id returned HTTP $RIG_HTTP_CODE"; return 1 ;;
	esac
	# Verify it is actually gone.
	rig_curl GET "$dv_url"
	if [ "$RIG_HTTP_CODE" = "404" ]; then
		rig_log "deleted + verified gone: $dv_kind $dv_id"
		return 0
	fi
	rig_loud "SURVIVOR: $dv_kind $dv_id still present after delete (verify GET returned HTTP $RIG_HTTP_CODE)"
	return 1
}

rig_teardown() {
	ensure_rig_workdir
	[ -f "$RIG_MANIFEST" ] || rig_die "no manifest at $RIG_MANIFEST — nothing to tear down"
	rig_resolve_auth
	td_survivors=0
	for td_kind in sprint board filter; do
		while IFS= read -r td_id; do
			[ -n "$td_id" ] || continue
			rig_delete_and_verify "$td_kind" "$td_id" || td_survivors=$((td_survivors + 1))
		done <<TEARDOWN_IDS_EOF
$(manifest_minted_ids "$td_kind")
TEARDOWN_IDS_EOF
	done
	if [ "$td_survivors" -gt 0 ]; then
		rig_loud "TEARDOWN INCOMPLETE: $td_survivors artifact(s) survived deletion — MANUAL CLEANUP REQUIRED (see $RIG_MANIFEST)"
		exit 4
	fi
	rig_log "teardown complete — all minted artifacts deleted and verified gone"
}

# ---------------------------------------------------------------------------
# Auth — mirror jira.sh: token in a `-K` config file (mode 600), never argv.
# A caller-supplied RIG_CURL_CONFIG wins; otherwise build one from
# JIRA_EMAIL/JIRA_TOKEN when both are present (absent is fine for the stubbed
# unit tests, whose stub ignores -K).
# ---------------------------------------------------------------------------
rig_resolve_auth() {
	[ -z "$RIG_CURL_CONFIG" ] || return 0
	if [ -n "${JIRA_EMAIL:-}" ] && [ -n "${JIRA_TOKEN:-}" ]; then
		ensure_rig_workdir
		RIG_CURL_CONFIG="$RIG_WORKDIR/curl.cfg"
		ra_email=$(printf '%s' "$JIRA_EMAIL" | sed 's/\\/\\\\/g; s/"/\\"/g')
		ra_token=$(printf '%s' "$JIRA_TOKEN" | sed 's/\\/\\\\/g; s/"/\\"/g')
		printf 'user = "%s:%s"\n' "$ra_email" "$ra_token" >"$RIG_CURL_CONFIG"
		chmod 600 "$RIG_CURL_CONFIG"
	fi
}

# ---------------------------------------------------------------------------
# Testable seams driven by the unit suite.
# ---------------------------------------------------------------------------

# rig_guard_check KIND ID — run guard_mutation; ONLY on success issue exactly
# ONE (sentinel) DELETE. The unit tests observe the argv log: a refusal must
# emit NO DELETE, an accept exactly one.
rig_guard_check() {
	gc_kind=$1
	gc_id=$2
	rig_resolve_auth
	guard_mutation "$gc_kind" "$gc_id"     # exits 3 on refusal, BEFORE the DELETE
	rig_curl DELETE "$(rig_artifact_url "$gc_kind" "$gc_id")"
	rig_log "guard-check: mutation ISSUED for $gc_kind $gc_id (HTTP $RIG_HTTP_CODE)"
}

# rig_register_sprint SPRINT_ID — the missing link that lets teardown clean up a
# sprint the live experiment CREATES via `jira.sh sprint --create`. guard_mutation
# only ever operates on ids ALREADY in the minted set, so a freshly-created sprint
# has to be admitted to that set FIRST — but admitting it blindly would defeat the
# whole guard. So this runs the SAME provenance verification guard_mutation's
# check (c) does (guard_provenance: GET the sprint, its originBoardId must be
# numeric AND a minted board, and that board's name must carry the exact RUNID),
# plus the layer-2 deny-list check, BEFORE it appends `MINTED sprint <id>`. Any
# failure is a loud refusal with NO manifest write — so teardown can only ever be
# handed a sprint that already proved itself ours.
rig_register_sprint() {
	rs_id=$1
	rig_resolve_auth
	rig_is_digits "$rs_id" || rig_usage_die "register-sprint requires a numeric SPRINT_ID, got '$rs_id'"
	[ -f "$RIG_MANIFEST" ] || rig_die "no manifest at $RIG_MANIFEST — run setup first"

	rs_runid=$(manifest_runid)
	[ -n "$rs_runid" ] || rig_refuse "manifest ($RIG_MANIFEST) has no RUNID — refusing to register a sprint"
	rig_valid_runid "$rs_runid" \
		|| rig_refuse "manifest RUNID '$rs_runid' is not a valid run token (^[0-9a-f]{16,}\$) — refusing to register a sprint"

	# Defense-in-depth: never admit a pre-existing (real) sprint into the minted set.
	if manifest_preexisting_has sprint "$rs_id"; then
		rig_refuse "sprint $rs_id is in the PRE-EXISTING deny-list — refusing to register a real sprint as minted"
	fi

	# The SAME two-hop provenance guard_mutation's check (c) uses — reused, not
	# reimplemented (the verified-good core stays the single source of truth).
	guard_provenance sprint "$rs_id" "$rs_runid" \
		|| rig_refuse "sprint $rs_id failed provenance — its origin board is not a minted board carrying the run token '$rs_runid'; NOT registering it"

	manifest_append "MINTED sprint $rs_id"
	rig_log "registered minted sprint $rs_id (provenance verified) — teardown will guard-delete it"
}

# rig_run_jira ARGS... — invoke the sibling engine (jira.sh) with the confirmed
# site appended. Every curl call jira.sh makes routes through the SAME `curl` on
# PATH the rig uses, so the whole lifecycle is exercisable under the stub with
# ZERO network. jira.sh resolves its own credentials from the environment
# (JIRA_CURL_CONFIG or JIRA_EMAIL/JIRA_TOKEN) exactly as it does in production.
rig_run_jira() {
	sh "$RIG_JIRA_SH" "$@" --confirmed-site "$RIG_HOST"
}

# ---------------------------------------------------------------------------
# STRUCTURAL WRAPPERS — the last line before an engine sprint MUTATION. The
# engine (jira.sh) acts on WHATEVER id it is handed, so the safety of a live run
# depends on the rig only ever passing ids sourced from the manifest. These
# wrappers make that STRUCTURAL: each asserts (PURE manifest reads, ZERO network)
# that the target was minted THIS run AND is not in the pre-existing deny-list
# BEFORE the engine is invoked, and REFUSES (rig_refuse -> exit 3, NO engine
# call) on any doubt. They REUSE the verified-good manifest_minted_has /
# manifest_preexisting_has / rig_refuse helpers — never a reimplementation. On
# the ACCEPT path they add NO curl of their own, so a refusal is proven by ZERO
# curl and an accept by the engine's own single mutation call.
# ---------------------------------------------------------------------------

# rig_sprint_create BOARD_ID [ENGINE_ARGS...] — guarded `jira.sh sprint --create`.
# BOARD_ID must be a board THIS run minted and NOT in the deny-list. The empty-
# board invariant on that board was already asserted by setup (LAYER 4), which
# every create path runs first — so a sprint is only ever created on a minted,
# proven-empty board.
rig_sprint_create() {
	sc_board=$1
	shift
	rig_is_digits "$sc_board" || rig_refuse "sprint --create board id '$sc_board' is not numeric"
	manifest_minted_has board "$sc_board" \
		|| rig_refuse "board $sc_board is NOT in the run manifest's minted set — refusing to create a sprint on a board this run did not mint"
	if manifest_preexisting_has board "$sc_board"; then
		rig_refuse "board $sc_board is in the PRE-EXISTING deny-list — refusing to create a sprint on a real board"
	fi
	rig_run_jira sprint --create --board "$sc_board" "$@"
}

# rig_assert_minted_sprint VERB SPRINT_ID — the shared minted-sprint precondition
# for every sprint-mutation wrapper (start/close/update). PURE manifest reads
# (ZERO network): SPRINT_ID must be in this run's minted set (it got there only
# via register-sprint, which already provenance-verified it) AND must not be in
# the pre-existing deny-list. Refuses (exit 3, no engine call) on any doubt.
rig_assert_minted_sprint() {
	ams_verb=$1
	ams_id=$2
	rig_is_digits "$ams_id" || rig_refuse "sprint --$ams_verb id '$ams_id' is not numeric"
	manifest_minted_has sprint "$ams_id" \
		|| rig_refuse "sprint $ams_id is NOT in the run manifest's minted set — refusing to $ams_verb a sprint this run did not mint/register"
	if manifest_preexisting_has sprint "$ams_id"; then
		rig_refuse "sprint $ams_id is in the PRE-EXISTING deny-list — refusing to $ams_verb a real sprint"
	fi
}

# rig_sprint_start SPRINT_ID [ENGINE_ARGS...] — guarded `jira.sh sprint --start`.
rig_sprint_start() {
	ss_id=$1
	shift
	rig_assert_minted_sprint start "$ss_id"
	rig_run_jira sprint --start "$ss_id" "$@"
}

# rig_sprint_close SPRINT_ID [ENGINE_ARGS...] — guarded `jira.sh sprint --close`.
rig_sprint_close() {
	scl_id=$1
	shift
	rig_assert_minted_sprint close "$scl_id"
	rig_run_jira sprint --close "$scl_id" "$@"
}

# rig_sprint_update SPRINT_ID [ENGINE_ARGS...] — guarded `jira.sh sprint --update`.
rig_sprint_update() {
	su_id=$1
	shift
	rig_assert_minted_sprint update "$su_id"
	rig_run_jira sprint --update "$su_id" "$@"
}

# rig_drive_sprint_lifecycle — the end-to-end exercise that gives the rig its
# reason to exist: after setup has minted the board, drive jira.sh's REAL sprint
# WRITE verbs against it — create -> register (guarded manifest append) -> start
# -> close — so teardown then guard-deletes the sprint alongside the filter and
# board. Every mutation stays behind a guard (the create's target board is the
# empty-invariant-checked minted board; register-sprint re-proves provenance
# before the sprint enters the minted set).
rig_drive_sprint_lifecycle() {
	# Jira caps a sprint name at <30 chars; the sprint name is NOT provenance-
	# checked (the board name is), so it need not carry the RUNID. Keep it short
	# and assert the cap here so a too-long name fails locally, not against live.
	dsl_name="[CRUCIBLE][TEST] lifecycle"
	[ "${#dsl_name}" -lt 30 ] || rig_die "sprint name '$dsl_name' (${#dsl_name} chars) exceeds Jira's 30-char limit"
	dsl_start="2026-07-26T10:00:00.000Z"
	dsl_end="2026-08-02T10:00:00.000Z"
	dsl_create_out="$RIG_WORKDIR/sprint-create-out.json"

	# Every engine mutation flows through a guarded wrapper (minted-asserted
	# BEFORE the engine runs) — no `rig_run_jira sprint --*` is ever called direct.
	rig_sprint_create "$RIG_BOARD_ID" --name "$dsl_name" --json \
		>"$dsl_create_out" || rig_die "jira.sh sprint --create failed"
	dsl_sprint_id=$(jq -r '.id // ""' "$dsl_create_out" 2>/dev/null || printf '')
	rig_is_digits "$dsl_sprint_id" || rig_die "jira.sh sprint --create returned no numeric id"
	rig_log "created sprint $dsl_sprint_id via jira.sh (board $RIG_BOARD_ID)"

	# Admit it to the minted set ONLY after re-proving provenance — this is what
	# lets the sprint wrappers below assert it as minted.
	rig_register_sprint "$dsl_sprint_id"

	# start REQUIRES both dates; close needs none.
	rig_sprint_start "$dsl_sprint_id" --start-date "$dsl_start" --end-date "$dsl_end" --json \
		>/dev/null || rig_die "jira.sh sprint --start failed"
	rig_log "started sprint $dsl_sprint_id"
	rig_sprint_close "$dsl_sprint_id" --json \
		>/dev/null || rig_die "jira.sh sprint --close failed"
	rig_log "closed sprint $dsl_sprint_id"
}

# ---------------------------------------------------------------------------
# provision — stand up a small, tagged, ISOLATED agile world and LEAVE IT
# STANDING. Unlike `full`, it NEVER tears down: a human teammate deletes the
# world later (guided by the printed ids + manifest). It runs setup (mint filter
# + board, snapshot the deny-list, assert the board is empty), then creates THREE
# sprints on the minted board — one left FUTURE (create only), one ACTIVE
# (create -> start), one CLOSED (create -> start -> close). Every engine mutation
# still flows through the guarded wrappers, and every created sprint is
# provenance-registered into the manifest so the eventual manual cleanup is
# guard-verifiable.
# ---------------------------------------------------------------------------
rig_provision() {
	rig_setup

	# A concrete, valid window for the active/closed sprints (start REQUIRES both).
	pv_start="2026-07-26T10:00:00.000Z"
	pv_end="2026-08-02T10:00:00.000Z"

	# (a) future — create only.
	rig_provision_sprint future
	pv_future_id=$RIG_LAST_SPRINT_ID

	# (b) active — create then start.
	rig_provision_sprint active
	pv_active_id=$RIG_LAST_SPRINT_ID
	rig_sprint_start "$pv_active_id" --start-date "$pv_start" --end-date "$pv_end" --json \
		>/dev/null || rig_die "jira.sh sprint --start failed for the active sprint"
	rig_log "started sprint $pv_active_id (left ACTIVE)"

	# (c) closed — create then start then close.
	rig_provision_sprint closed
	pv_closed_id=$RIG_LAST_SPRINT_ID
	rig_sprint_start "$pv_closed_id" --start-date "$pv_start" --end-date "$pv_end" --json \
		>/dev/null || rig_die "jira.sh sprint --start failed for the closed sprint"
	rig_sprint_close "$pv_closed_id" --json \
		>/dev/null || rig_die "jira.sh sprint --close failed for the closed sprint"
	rig_log "closed sprint $pv_closed_id (left CLOSED)"

	rig_provision_report "$pv_future_id" "$pv_active_id" "$pv_closed_id"
	# Deliberately NO teardown — the world is left standing for a human to remove.
}

# rig_provision_sprint STATE_LABEL — create ONE sprint on the minted board via the
# guarded rig_sprint_create, then provenance-register it into the minted set.
# Sets RIG_LAST_SPRINT_ID to the created numeric id (a global, matching the
# rig_create_board convention — no command-substitution subshell to lose the
# value in). STATE_LABEL is the human tag in the sprint name.
rig_provision_sprint() {
	ps_state=$1
	# Jira caps a sprint name at <30 chars; the name is NOT provenance-checked
	# (the board name is), so drop the RUNID and keep it short. Assert the cap
	# so a too-long name fails locally, not against live.
	ps_name="[CRUCIBLE][TEST] ${ps_state}"
	[ "${#ps_name}" -lt 30 ] || rig_die "sprint name '$ps_name' (${#ps_name} chars) exceeds Jira's 30-char limit"
	ps_out="$RIG_WORKDIR/provision-sprint-${ps_state}.json"
	rig_sprint_create "$RIG_BOARD_ID" --name "$ps_name" --json \
		>"$ps_out" || rig_die "jira.sh sprint --create failed for the $ps_state sprint"
	RIG_LAST_SPRINT_ID=$(jq -r '.id // ""' "$ps_out" 2>/dev/null || printf '')
	rig_is_digits "$RIG_LAST_SPRINT_ID" \
		|| rig_die "jira.sh sprint --create returned no numeric id for the $ps_state sprint"
	rig_log "created $ps_state sprint $RIG_LAST_SPRINT_ID via jira.sh (board $RIG_BOARD_ID)"
	# Admit it to the minted set ONLY after re-proving provenance.
	rig_register_sprint "$RIG_LAST_SPRINT_ID"
}

# rig_provision_report FUTURE ACTIVE CLOSED — the human-facing summary of the
# world left standing. To STDOUT (stdout is the rig's machine/summary channel;
# diagnostics go to stderr) so it can be captured/parsed by the teammate who
# later deletes it.
rig_provision_report() {
	pr_future=$1
	pr_active=$2
	pr_closed=$3
	printf '\n'
	printf '=== PROVISIONED — LEFT STANDING (no teardown ran) ===\n'
	printf 'runid:          %s\n' "$RIG_RUNID"
	printf 'filter id:      %s\n' "$RIG_FILTER_ID"
	printf 'board id:       %s\n' "$RIG_BOARD_ID"
	printf 'sprint future:  %s\n' "$pr_future"
	printf 'sprint active:  %s\n' "$pr_active"
	printf 'sprint closed:  %s\n' "$pr_closed"
	printf 'manifest:       %s\n' "$RIG_MANIFEST"
	printf 'NOTE: this isolated world is LEFT STANDING; a teammate deletes it later.\n'
	printf '\n'
}

# ---------------------------------------------------------------------------
# Dispatch.
# ---------------------------------------------------------------------------
rig_require_host() {
	[ -n "$RIG_HOST" ] || rig_usage_die "--confirmed-site SITE is required"
	case "$RIG_HOST" in
		*.atlassian.net) : ;;
		*) rig_die "confirmed site '$RIG_HOST' is not an *.atlassian.net host (fail closed)" ;;
	esac
}

rig_main() {
	[ $# -ge 1 ] || rig_usage_die "a subcommand is required (setup|teardown|full|provision|register-sprint|sprint-create|sprint-start|sprint-close|sprint-update|guard-check|empty-board-check)"
	rig_sub=$1
	shift

	while [ $# -gt 0 ]; do
		case "$1" in
			--confirmed-site) [ -n "${2:-}" ] || rig_usage_die "$1 requires an argument"; RIG_HOST=$2; shift ;;
			--project)        [ -n "${2:-}" ] || rig_usage_die "$1 requires an argument"; RIG_PROJECT=$2; shift ;;
			--runid)          [ -n "${2:-}" ] || rig_usage_die "$1 requires an argument"; RIG_RUNID_OVERRIDE=$2; shift ;;
			--manifest)       [ -n "${2:-}" ] || rig_usage_die "$1 requires an argument"; RIG_MANIFEST=$2; shift ;;
			--) shift; break ;;
			-*) rig_usage_die "unknown option: $1" ;;
			*)
				if [ -z "$RIG_ARG1" ]; then RIG_ARG1=$1
				elif [ -z "$RIG_ARG2" ]; then RIG_ARG2=$1
				else rig_usage_die "unexpected argument: $1"
				fi
				;;
		esac
		shift
	done

	command -v curl >/dev/null 2>&1 || rig_die "curl is not installed"
	command -v jq   >/dev/null 2>&1 || rig_die "jq is not installed"

	case "$rig_sub" in
		setup)    rig_require_host; rig_setup ;;
		teardown) rig_require_host; rig_teardown ;;
		full)     rig_require_host; rig_setup; rig_drive_sprint_lifecycle; rig_teardown ;;
		provision)
			rig_require_host
			[ -n "$RIG_PROJECT" ] || rig_usage_die "provision requires --project KEY"
			rig_provision
			;;
		sprint-create)
			# Guarded-wrapper seam: assert BOARD_ID is minted (+ not deny-listed)
			# BEFORE the engine's --create runs. The engine args are fixed here (the
			# seam only proves the guard gates the mutation); the real create path
			# supplies its own name via rig_drive_sprint_lifecycle / rig_provision.
			rig_require_host
			rig_is_digits "$RIG_ARG1" || rig_usage_die "sprint-create requires a numeric BOARD_ID, got '$RIG_ARG1'"
			[ -f "$RIG_MANIFEST" ]    || rig_die "no manifest at $RIG_MANIFEST"
			rig_sprint_create "$RIG_ARG1" --name "[CRUCIBLE][TEST] seam" --json
			;;
		sprint-start)
			rig_require_host
			rig_is_digits "$RIG_ARG1" || rig_usage_die "sprint-start requires a numeric SPRINT_ID, got '$RIG_ARG1'"
			[ -f "$RIG_MANIFEST" ]    || rig_die "no manifest at $RIG_MANIFEST"
			rig_sprint_start "$RIG_ARG1" --start-date "2026-07-26T10:00:00.000Z" --end-date "2026-08-02T10:00:00.000Z" --json
			;;
		sprint-close)
			rig_require_host
			rig_is_digits "$RIG_ARG1" || rig_usage_die "sprint-close requires a numeric SPRINT_ID, got '$RIG_ARG1'"
			[ -f "$RIG_MANIFEST" ]    || rig_die "no manifest at $RIG_MANIFEST"
			rig_sprint_close "$RIG_ARG1" --json
			;;
		sprint-update)
			rig_require_host
			rig_is_digits "$RIG_ARG1" || rig_usage_die "sprint-update requires a numeric SPRINT_ID, got '$RIG_ARG1'"
			[ -f "$RIG_MANIFEST" ]    || rig_die "no manifest at $RIG_MANIFEST"
			rig_sprint_update "$RIG_ARG1" --name "[CRUCIBLE][TEST] renamed" --json
			;;
		register-sprint)
			rig_require_host
			rig_is_digits "$RIG_ARG1" || rig_usage_die "register-sprint requires a numeric SPRINT_ID, got '$RIG_ARG1'"
			[ -f "$RIG_MANIFEST" ]    || rig_die "no manifest at $RIG_MANIFEST"
			rig_register_sprint "$RIG_ARG1"
			;;
		guard-check)
			rig_require_host
			rig_valid_kind "$RIG_ARG1" || rig_usage_die "guard-check requires KIND (board|sprint|filter), got '$RIG_ARG1'"
			rig_is_digits "$RIG_ARG2"  || rig_usage_die "guard-check requires a numeric ID, got '$RIG_ARG2'"
			[ -f "$RIG_MANIFEST" ]     || rig_die "no manifest at $RIG_MANIFEST"
			rig_guard_check "$RIG_ARG1" "$RIG_ARG2"
			;;
		empty-board-check)
			rig_require_host
			rig_is_digits "$RIG_ARG1" || rig_usage_die "empty-board-check requires a numeric BOARD_ID, got '$RIG_ARG1'"
			rig_resolve_auth
			rig_assert_board_empty "$RIG_ARG1"
			;;
		*) rig_usage_die "unknown subcommand: $rig_sub" ;;
	esac
}

rig_main "$@"
