#!/usr/bin/env sh
#
# doc-lint.sh — deterministic structural/redaction lint for ONE markdown
#               document. Run by the ORCHESTRATOR against a tech-writer
#               draft, from OUTSIDE the agent that authored it — never
#               invoked by tech-writer itself (see the procedure-doc-lint
#               SKILL.md for why that independence is the whole point).
#
# Purpose:
#   Checks a single markdown file for four deterministic, pattern-matchable
#   violations and reports every one of them as file:line, itemized:
#     1. A code fence (```) opened without a language tag.
#     2. A ticket/issue-ID-shaped identifier (e.g. PROJ-1234) whose PREFIX is
#        not on the allowlist below (e.g. UTF-8, SHA-256, RFC-2119, ISO-8601
#        are common technical-standard mentions, never ticket IDs, and must
#        not be flagged).
#     3. An absolute local filesystem path (/Users/..., /home/...,
#        C:\Users\...).
#     4. A single-item bulleted or numbered list (this repo's own style
#        rule — never a one-item list).
#   NEVER modifies the file; report-only, like every reviewer in this
#   framework.
#
# Usage:
#   doc-lint.sh --file PATH [--allow-ticket-prefixes "FOO BAR"] [-h|--help]
#
#     --file PATH                  The markdown file to lint (required).
#     --allow-ticket-prefixes LIST Space-separated extra prefixes to treat as
#                                  NOT a ticket ID for this invocation only,
#                                  on top of the built-in default allowlist
#                                  below (repeatable; each use appends).
#     -h, --help                   Show this help.
#
# Output:
#   A human-readable block listing every violation (file:line: CODE:
#   message — never quoting the matched sensitive text itself for the
#   TICKET_ID/LOCAL_PATH categories, so the report doesn't re-leak what it
#   flags), THEN machine-parseable DOCLINT_*=VALUE lines:
#     DOCLINT_FILE=<path>
#     DOCLINT_VIOLATIONS=<n>              total violation count
#     DOCLINT_BARE_FENCES=<n>
#     DOCLINT_TICKET_IDS=<n>
#     DOCLINT_LOCAL_PATHS=<n>
#     DOCLINT_SINGLE_ITEM_LISTS=<n>
#   Diagnostics (usage errors) go to stderr.
#
# Exit codes:
#   0  clean — zero violations
#   1  one or more violations found (see the itemized report)
#   2  usage error
#
# Portability: POSIX sh + POSIX awk only (no bashisms, no GNU-only awk/grep
#   extensions). Every external binary is guarded with `command -v`.
#   Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

# ---------------------------------------------------------------------------
# TICKET_ID allowlist — prefixes that match the ticket-ID shape
# ([A-Z]{2,}-[0-9]+) but are common, well-known technical-standard or
# algorithm-name prefixes, never an actual ticket/issue ID (UTF-8, SHA-256,
# RFC-2119, ISO-8601, AES-256, ES256-style algorithm names, ...). Root cause
# of the finding this closes: the bare pattern false-positives on ordinary,
# correct technical vocabulary, making a MANDATORY gating check actively
# harmful — a doc that correctly mentions a standard could never pass without
# lying about content.
#
# This is a LIVING list, not a closed set — mirrors this repo's own
# deploy/hub/lib/hub-discovery.sh HUB_COLOR_KNOWN_LIST shape (a space-separated
# constant, documented as non-exhaustive, extended here as new cases surface)
# rather than a one-off patch. A prefix absent from it is still flagged, never
# silently passed — this list only SUPPRESSES known-safe shapes, it never
# widens what counts as a violation. For a domain-specific standard this
# default list won't anticipate, pass extra prefixes per-invocation with
# --allow-ticket-prefixes, rather than editing this file.
# ---------------------------------------------------------------------------
TICKET_ID_ALLOWLIST_DEFAULT='UTF SHA AES RFC ISO RSA ECDSA HMAC TLS SSL HTTP HTTPS JSON XML IEEE ECMA ANSI POSIX ASCII UUID MIME CRC MD DES RC PKCS ITU IETF W3C ES'

error() { printf '%s: error: %s\n' "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG --file PATH [--allow-ticket-prefixes "FOO BAR"] [-h|--help]

Deterministic structural/redaction lint for ONE markdown document. Never
modifies the file; report-only.

Options:
  --file PATH                  The markdown file to lint (required).
  --allow-ticket-prefixes LIST Space-separated extra ticket-ID prefixes to
                                allow for this run only, on top of the
                                built-in default allowlist (repeatable).
  -h, --help                    Show this help.

Checks:
  1. Every code fence (\`\`\`) carries a language tag (no bare fences).
  2. No ticket/issue-ID-shaped identifiers ([A-Z]{2,}-[0-9]+) whose prefix is
     not on the allowlist (default: $TICKET_ID_ALLOWLIST_DEFAULT).
  3. No absolute local filesystem paths (/Users/, /home/, C:\Users\).
  4. No single-item bulleted/numbered list.

Prints:
  DOCLINT_FILE=<path>
  DOCLINT_VIOLATIONS=<n>
  DOCLINT_BARE_FENCES=<n>
  DOCLINT_TICKET_IDS=<n>
  DOCLINT_LOCAL_PATHS=<n>
  DOCLINT_SINGLE_ITEM_LISTS=<n>

Exit codes:
  0  clean pass
  1  one or more violations found
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_FILE=""
OPT_EXTRA_TICKET_PREFIXES=""

while [ $# -gt 0 ]; do
	case "$1" in
		--file)                     need_arg "$1" "${2:-}"; OPT_FILE=$2; shift ;;
		--allow-ticket-prefixes)    need_arg "$1" "${2:-}"; OPT_EXTRA_TICKET_PREFIXES="$OPT_EXTRA_TICKET_PREFIXES $2"; shift ;;
		-h|--help)  usage; exit 0 ;;
		--)         shift; break ;;
		-*)         usage >&2; error "unknown option: $1"; exit 2 ;;
		*)          usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_FILE" ] || { usage >&2; error "--file is required"; exit 2; }

# Combine the default allowlist with any per-invocation extras, uppercased
# (the pattern's prefix is always [A-Z]{2,}, so a lowercase caller-supplied
# prefix would otherwise silently never match anything).
TICKET_ID_ALLOWLIST=$(printf '%s %s' "$TICKET_ID_ALLOWLIST_DEFAULT" "$OPT_EXTRA_TICKET_PREFIXES" | tr '[:lower:]' '[:upper:]')

for bin in awk grep sort mktemp; do
	if ! command -v "$bin" >/dev/null 2>&1; then
		error "$bin is not installed"
		exit 1
	fi
done

[ -f "$OPT_FILE" ] || { error "--file does not exist or is not a regular file: $OPT_FILE"; exit 2; }
[ -r "$OPT_FILE" ] || { error "--file is not readable: $OPT_FILE"; exit 2; }

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/doc-lint.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT INT TERM
RAW="$WORKDIR/violations.raw"
SORTED="$WORKDIR/violations.sorted"

# ---------------------------------------------------------------------------
# Checks 1 + 4: bare code fences and single-item lists. One awk pass — both
# need line-by-line state across the whole file, and fenced-block content
# must be excluded from list-structure detection (a "- like this" line
# inside an example code block is not a real list).
#
# List-block boundaries track the marker KIND (bullet character, or
# ordered-vs-unordered), not merely "is this line list-item-shaped" —
# per CommonMark, a change in bullet character or a transition between
# ordered and unordered syntax between two consecutive list-item lines
# starts a NEW list, even with no blank line between them. Without this,
# two adjacent single-item lists ("- a" immediately followed by "* b", or
# by "1. b") merge into one two-item block and neither is flagged.
# ---------------------------------------------------------------------------
awk '
	function close_block() {
		if (block_open && block_count == 1) {
			printf "%d\tSINGLE_ITEM_LIST\tsingle-item list (only one bulleted/numbered item in this block)\n", block_first
		}
		block_open = 0
		block_count = 0
		block_first = 0
		block_kind = ""
	}
	{
		line = $0
		trimmed = line
		sub(/^[ \t]*/, "", trimmed)

		# --- fence detection (independent of list state) ---
		if (match(trimmed, /^```+/)) {
			flen = RLENGTH
			rest = substr(trimmed, flen + 1)
			sub(/^[ \t]+/, "", rest)
			sub(/[ \t]+$/, "", rest)
			if (in_fence == 0) {
				if (rest == "") {
					printf "%d\tBARE_FENCE\tcode fence opened without a language tag\n", FNR
				}
				in_fence = 1
			} else {
				in_fence = 0
			}
			next
		}

		if (in_fence) { next }  # never lint list structure inside a fenced block

		# --- list-block detection ---
		is_blank = (trimmed == "")
		is_item = match(trimmed, /^([-*+][ \t]+|[0-9]+\.[ \t]+)/)
		# Extract the marker KIND right here, while RSTART/RLENGTH still
		# reflect the is_item match above — the is_indented match() call
		# just below reuses (and overwrites) those same built-ins, so
		# reading them any later would silently grab the wrong match.
		if (is_item) {
			marker = substr(trimmed, RSTART, RLENGTH)
			kind = (substr(marker, 1, 1) ~ /[0-9]/) ? "ORDERED" : substr(marker, 1, 1)
		}
		is_indented = (!is_blank && match(line, /^[ \t]+/))

		if (is_item) {
			# CommonMark starts a NEW list the instant the marker changes —
			# a different bullet character (-, *, +) or a switch between
			# ordered and unordered syntax is never a continuation of the
			# prior block, even with no blank line between. Track the
			# marker KIND, not merely "is this line list-item-shaped", so
			# two adjacent single-item lists with no separator are each
			# detected as their own block instead of merging into one
			# multi-item block that never gets flagged.
			if (!block_open) {
				block_open = 1; block_first = FNR; block_count = 1; block_kind = kind
			} else if (kind == block_kind) {
				block_count++
			} else {
				close_block()
				block_open = 1; block_first = FNR; block_count = 1; block_kind = kind
			}
		} else if (is_blank || is_indented) {
			# a blank line or an indented continuation never closes a block on
			# its own — only a hard break (plain column-0 text) does
		} else {
			close_block()
		}
	}
	END { close_block() }
' "$OPT_FILE" >"$RAW"

# ---------------------------------------------------------------------------
# Check 2: ticket/issue-ID-shaped identifiers. Location only — the matched
# text itself is deliberately never echoed back into the report (see the
# header comment above on why this script never re-leaks what it flags).
#
# A line is flagged only if it contains at least one [A-Z]{2,}-[0-9]+ match
# whose PREFIX (the letters before the hyphen) is NOT on the TICKET_ID
# allowlist built above — a line that only contains allowlisted
# technical-standard prefixes (UTF-8, SHA-256, RFC-2119, ISO-8601, ...) is not
# a ticket ID and must not be flagged, even though it matches the bare shape.
# A line with both an allowlisted mention AND a real ticket-ID-shaped token
# (e.g. "COTE-1543, per RFC-2119") is still flagged, for the real token.
# ---------------------------------------------------------------------------
awk -v allow="$TICKET_ID_ALLOWLIST" '
	BEGIN {
		n = split(allow, aw, " ")
		for (i = 1; i <= n; i++) ALLOW[aw[i]] = 1
	}
	{
		rest = $0
		flagged = 0
		while (match(rest, /[A-Z]{2,}-[0-9]+/)) {
			tok = substr(rest, RSTART, RLENGTH)
			hy = index(tok, "-")
			prefix = substr(tok, 1, hy - 1)
			if (!(prefix in ALLOW)) { flagged = 1 }
			rest = substr(rest, RSTART + RLENGTH)
		}
		if (flagged) {
			printf "%d\tTICKET_ID\tticket/issue-ID-shaped identifier found (pattern: [A-Z]{2,}-[0-9]+, prefix not on the allowlist)\n", FNR
		}
	}
' "$OPT_FILE" >>"$RAW"

# ---------------------------------------------------------------------------
# Check 3: absolute local filesystem paths (Unix home dirs, Windows user
# dirs). Same non-echo discipline as check 2.
# ---------------------------------------------------------------------------
grep -nE '(/Users/|/home/|C:\\Users\\)' "$OPT_FILE" | cut -d: -f1 | while IFS= read -r lineno; do
	printf '%s\tLOCAL_PATH\tabsolute local filesystem path found (Unix home dir or Windows user dir)\n' "$lineno"
done >>"$RAW"

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
sort -k1,1n "$RAW" >"$SORTED"

TOTAL=$(wc -l <"$RAW" | tr -d ' ')
BARE_FENCES=$(awk -F'\t' '$2=="BARE_FENCE"{c++} END{print c+0}' "$RAW")
TICKET_IDS=$(awk -F'\t' '$2=="TICKET_ID"{c++} END{print c+0}' "$RAW")
LOCAL_PATHS=$(awk -F'\t' '$2=="LOCAL_PATH"{c++} END{print c+0}' "$RAW")
SINGLE_ITEM_LISTS=$(awk -F'\t' '$2=="SINGLE_ITEM_LIST"{c++} END{print c+0}' "$RAW")

printf 'Doc Lint\n'
printf '  File:            %s\n' "$OPT_FILE"
printf '  Violations:      %s\n' "$TOTAL"
printf '\n'

if [ "$TOTAL" -gt 0 ]; then
	printf 'Violations:\n'
	TAB=$(printf '\t')
	while IFS="$TAB" read -r lineno code msg; do
		printf '  %s:%s: %s: %s\n' "$OPT_FILE" "$lineno" "$code" "$msg"
	done <"$SORTED"
	printf '\n'
fi

printf 'DOCLINT_FILE=%s\n'              "$OPT_FILE"
printf 'DOCLINT_VIOLATIONS=%s\n'        "$TOTAL"
printf 'DOCLINT_BARE_FENCES=%s\n'       "$BARE_FENCES"
printf 'DOCLINT_TICKET_IDS=%s\n'        "$TICKET_IDS"
printf 'DOCLINT_LOCAL_PATHS=%s\n'       "$LOCAL_PATHS"
printf 'DOCLINT_SINGLE_ITEM_LISTS=%s\n' "$SINGLE_ITEM_LISTS"

[ "$TOTAL" -eq 0 ] || exit 1
exit 0
