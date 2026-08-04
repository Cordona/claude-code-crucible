#!/usr/bin/env sh
#
# md-to-adf.sh — convert the FULL Jira-supported markdown formatting set
#                into an Atlassian Document Format (ADF) JSON document,
#                printed on stdout. Verified against Atlassian's ADF spec
#                shapes; see the per-node notes below for the exact JSON
#                each construct must produce (a wrong shape is a Jira 400).
#
# Supported:
#   #  .. ######        -> heading (level 1-6)
#   - x  / * x            -> a run of consecutive bullets -> ONE bulletList
#   1. x                   -> a run of consecutive numbered lines -> ONE orderedList
#     (NESTED lists: increasing leading-whitespace opens a deeper level; a
#      listItem's content is [paragraph, <nested list>] — the nested list is
#      a SIBLING of the paragraph, never its own top-level block. See the
#      "Nested lists" design note below.)
#   ---  (a line that IS exactly "---")  -> a rule node
#   ```lang / ```           -> a fenced code block (see "Fenced code" below)
#   > ...                   -> a blockquote wrapping ONE OR MORE paragraphs
#   > [!INFO]/[!NOTE]/[!WARNING]/[!SUCCESS]/[!ERROR] (+ GitHub-alert aliases
#     [!TIP]->success, [!CAUTION]->error, [!IMPORTANT]->warning), as the
#     FIRST line of a blockquote -> a `panel` instead of a `blockquote`
#   | a | b | \n |---|---| \n | c | d |   -> a GFM pipe table (see "Tables")
#   inline **bold**, ***bold+italic***, _italic_/*italic*, `code`,
#     ~~strike~~, [text](url) -> marks on text runs
#   a line ending in 2+ trailing spaces or a trailing "\" -> an inline
#     hardBreak node between it and the next line of the SAME paragraph
#   anything else (a markdown construct we don't recognize) -> degrades to a
#     plain paragraph (the default fallback — no special-casing required: an
#     unrecognized line simply falls through every classifier below into
#     the paragraph branch)
#
# Deliberate divergences from the jira.py reference oracle (documented, not
# accidental):
#   1. `---` -> ADF `rule`. The oracle instead leaves a literal "---" in a
#      paragraph's text. A `rule` node is what ADF actually renders as a
#      horizontal rule in Jira; the oracle's behavior is a gap being fixed
#      forward here, not preserved.
#   2. NOT reproduced: an oracle bug where a plain paragraph immediately
#      followed (no blank line) by a heading/list/rule marker silently DROPS
#      that following line — the oracle's paragraph-collection loop
#      unconditionally advances one extra line past the break, whichever
#      line caused it. This script's line-at-a-time state machine has no
#      lookahead-and-skip step, so it cannot exhibit that bug; it was not
#      replicated for "parity" because a bug is not a contract.
#      Canonical empty-paragraph shape, used EVERYWHERE this
#      script emits one (this fallback, the listItem/blockquote/panel/
#      table-cell empty-child fallbacks) — {"type":"paragraph"}, with NO
#      "content" key at all, never {"type":"paragraph","content":[]}. Both
#      are valid ADF (a paragraph MAY be empty either way), but one shape
#      throughout is easier to reason about and test than two that mean
#      the same thing.
#   3. Empty/whitespace-only input -> a single-paragraph doc, not an empty
#      content array: {"type":"doc","version":1,"content":[{"type":
#      "paragraph"}]}. An empty `content:[]` at the DOCUMENT level is what
#      Jira's API may reject as an invalid ADF body; a doc holding one
#      empty paragraph is the minimal always-valid shape.
#   4. A `[text](url)` link's href is scheme-restricted to http(s)/mailto
#      (case-insensitive). A disallowed scheme (`javascript:`, `data:`, ...)
#      drops the link mark and keeps the text as plain text.
#   5. Fenced code, blockquote/panel, nested lists, tables, strike, italic,
#      bold+italic, hardBreak, and headings 4-6 are ALL extensions with no
#      oracle equivalent at all (the oracle only ever produces headings
#      2-3, flat lists, and bold/code/link marks) — there is no parity
#      constraint for any of them; their golden fixtures are hand-authored.
#
# Known limitation (documented, not a defect): italic uses `_text_` OR
# `*text*`. A single `*` is also common in ordinary prose as multiplication/
# a bullet-adjacent glyph (e.g. `5 * 3 * 2`), and CAN false-italicize when
# two such `*`s appear on the same line with non-`*` text between them.
# `_text_` has no such ambiguity. `***text***` is the ONLY syntax that
# stacks strong+em on one node — `**_text_**` and similar mixed forms are
# NOT specially parsed (the outer `**...**` wins and the inner `_..._`
# stays literal), consistent with "nested markup inside an already-matched
# span stays literal" (see the tokenizer note below). The `code` mark is
# never stacked with strong/em/strike by construction: this tokenizer
# assigns AT MOST one mark per matched span (the `***text***` case is its
# own dedicated alternative, not real nesting) — the only way a "combined"
# mark set ever appears is that dedicated strong+em case, so code can never
# appear combined with anything.
#
# Usage:
#   md-to-adf.sh [--file PATH] [--media-map PATH] [-h|--help]
#
#     --file PATH        Read markdown from PATH instead of stdin.
#     --media-map PATH   A JSON object mapping a LOCAL image path to a Jira
#                        media UUID (built by jira.sh's inline-image pre-pass;
#                        this converter itself does NO network). When present,
#                        an OWN-LINE local image `![alt](LOCALPATH)` whose
#                        LOCALPATH is a key in the map is emitted as an ADF
#                        `mediaSingle` block (see "Inline images" below).
#     -h, --help         Show this help.
#
# Output:
#   stdout: a single ADF document JSON object:
#     {"type":"doc","version":1,"content":[ ...blocks... ]}
#   Diagnostics go to stderr.
#
# Inline images (block-level media — only with --media-map):
#   In ADF, media is a BLOCK node, so an image is its own line between
#   paragraphs (this is what "an image in the middle of the text" means here).
#   The block parser (NOT the inline tokenizer) recognizes a line that is
#   SOLELY an image — `![alt](PATH)` — and, when --media-map maps PATH to a
#   media UUID, emits the verified-rendering block:
#     {"type":"mediaSingle","attrs":{"layout":"center"},
#      "content":[{"type":"media",
#        "attrs":{"type":"file","id":"<UUID>","collection":""}}]}
#   collection is the EMPTY STRING "" (verified live: null -> 400
#   INVALID_INPUT; "" -> accepted and renders). The alt text is intentionally
#   NOT carried into the media node: the block above (without alt) is the exact
#   shape probed to render as an <img>; alt is cosmetic and unverified, so it
#   is dropped to stay on the proven path (the image itself is never dropped).
#
#   FALLBACK (no content is ever silently dropped):
#     * --media-map absent, OR PATH is an http(s):// URL, OR the line is not
#       SOLELY an image -> preserved exactly as today (the line degrades to
#       paragraph text; the inline tokenizer keeps the `!` literal, and an
#       http(s) target keeps its link mark while a local one drops it per the
#       scheme allow-list).
#     * PATH looks local and is NOT in the map -> ALSO passed through as
#       paragraph text (chosen over erroring: jira.sh's pre-pass guarantees
#       every own-line local image is in the map, so an unmapped local path is
#       a defensive standalone-use case, not a jira.sh flow — degrading to text
#       preserves the content instead of aborting).
#     * PATH IS in the map but its value is not a 36-char [a-f0-9-] UUID ->
#       FAIL LOUD (exit 1): a malformed UUID would otherwise become an ADF
#       value, so it is rejected at the sink (see standard-security).
#
# Exit codes:
#   0  converted
#   1  jq absent / jq lacks Oniguruma regex support / an internal jq failure /
#      a --media-map value that is not a valid media UUID
#   2  usage error (unknown option, --file/--media-map missing/unreadable)
#
# Jira-400 landmines — how each is guarded (see standard-security's "think
# in taint": each is a sink-specific control, not just "validate on input"):
#   1. version:1 on the root doc            -> hardcoded in the final jq -s.
#   2. never an empty text node             -> the tokenizer's no-match base
#      case only emits a node for NON-empty text; the codeBlock/table-cell
#      builders emit content:[] / an attrs-only paragraph instead of a
#      text:"" node when the body/cell is empty.
#   3. codeBlock text has NO marks          -> built via `jq -Rs` directly
#      from the raw fence body; the inline tokenizer is NEVER called on
#      fence content, so no mark can ever attach to it.
#   4. code mark never stacks with strong/em/strike -> by construction (see
#      "Known limitation" above): this tokenizer never combines marks
#      except the dedicated `***text***` strong+em case, which is not code.
#   5. panel needs a valid panelType / heading needs level 1-6 / link needs
#      href -> panelType comes only from the fixed detect_panel_type map
#      (info/note/warning/success/error, never a raw user string); heading
#      level is always a hardcoded shell integer 1-6 from the matched case
#      arm; a link mark is only ever emitted together with its href in the
#      SAME jq expression (see the tokenizer's link branch) — there is no
#      code path that emits one without the other.
#   6. containers never emit content:[] (tableRow, tableCell/tableHeader,
#      bulletList/orderedList, listItem, blockquote, panel, table) -> each
#      assembler defensively injects a single empty-paragraph fallback
#      child if its buffer would otherwise be empty before slurping.
#   7. blockquote/panel/table-cell wrap block nodes, never raw text -> every
#      buffered child is always a full {type:"paragraph",...} object; text
#      nodes are only ever placed INSIDE a paragraph's content array.
#
# Design notes (POSIX sh has no arrays):
#   Every node accumulates as ONE COMPACT JSON OBJECT PER LINE in a temp
#   file (NDJSON) — the file itself is the "array"; `jq -s` slurps a buffer
#   into its parent block. This is uniform across paragraphs, lists, table
#   rows, and blockquote paragraphs. The shell layer stays array-free; jq
#   alone assembles arrays, and jq NEVER concatenates JSON strings.
#
#   Nested lists: represented as a STACK, encoded as a single '|'-delimited
#   string ("indent:type:bufferpath|indent:type:bufferpath|..."), innermost
#   entry last. A new list-item line with leading-whitespace count N pops
#   every level whose indent is STRICTLY GREATER than N (closing deeper
#   nested lists), then either continues the current top level (same indent,
#   same type -> just append), replaces it (same indent, different type ->
#   pop+push), or opens a new deeper level (indent greater than the current
#   top's, or the stack was empty). Popping a level assembles it into one
#   bulletList/orderedList block and folds it as a SECOND element into the
#   NEW top's most-recently-buffered listItem's content array (a sibling of
#   that item's paragraph) — or, once the stack is fully empty, appends it
#   straight to $BLOCKS_FILE. No recursion, no real arrays: a string stack
#   plus "amend the last NDJSON line" (via `sed '$d'` + a filtered re-append,
#   both POSIX-portable — no GNU-only `head -n -1`) is the whole mechanism.
#
#   Tables/blockquotes/fences avoid needing lookahead-with-pushback (POSIX
#   sh has no ungetc for a `read` loop) by tracking OPEN/state across outer
#   loop iterations, the same pattern paragraphs and lists already use: when
#   a stateful block ends on a line that does NOT belong to it, that line is
#   simply NOT consumed by the state — execution falls through to the
#   normal classifiers within the SAME iteration, so the line is dispatched
#   exactly once, correctly, with no pushback machinery. Table-vs-not-a-
#   table IS one genuine 1-line lookahead (GFM requires the row after a
#   candidate header to be a valid delimiter row to confirm it's a table at
#   all) — done via a `sed -n 'Np'` peek directly on $NORMALIZED_FILE (a
#   plain file, safe to random-access without disturbing the main read
#   loop's own position), never by consuming from the stream.
#
# Security: markdown text is DATA. It reaches jq only via `--arg`/`--rawfile`
# into STATIC, hardcoded jq programs (never string-concatenated, never
# eval'd). Where the shell itself branches on the text (case/grep/sed), the
# text is only ever matched/piped as data against a HARDCODED pattern — it
# is never used as a pattern, a program, or a command itself. No `eval`
# anywhere in this script, including the list-nesting stack (a real string
# stack, not name-indirection).
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). `sed -E` (not `-r`) is
#   used throughout because BSD sed lacks `-r`; `sed '$d'` / `sed -n '$p'`
#   (not GNU `head -n -1`) for "all but the last line" / "just the last
#   line", both POSIX. Standard coreutils (cut, tr, mv, cat, grep, sed, rm,
#   mktemp) are assumed present, unguarded, same as the sibling
#   procedure-inbox-capture/scripts/capture.sh. jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`, plus a
#   dedicated Oniguruma-support preflight
#   (see assert_oniguruma). There is deliberately NO sh-loop fallback for
#   inline parsing — Oniguruma is asserted, not
#   forked around. Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout stays machine-clean JSON)
# ---------------------------------------------------------------------------
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG [--file PATH] [--media-map PATH] [-h|--help]

Convert the full Jira-supported markdown set to an ADF document JSON on
stdout. Reads --file, or stdin when --file is omitted.

Options:
  --file PATH        Read markdown from PATH (must exist and be readable).
  --media-map PATH   JSON object mapping a LOCAL image path -> media UUID; an
                     own-line \`![alt](LOCALPATH)\` whose path is a key becomes
                     an ADF mediaSingle block. No network is ever performed.
  -h, --help         Show this help.

Exit codes:
  0  converted
  1  jq absent / jq lacks Oniguruma regex support / internal jq failure /
     a --media-map value that is not a valid media UUID
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# assert_oniguruma — fail closed with a clear message if jq's regex
# functions (test/match/capture/scan) aren't available. This is a REAL
# probe (an actual jq invocation's exit status), not a version-string
# parse: a jq built without Oniguruma raises on the very first test()/
# match() call, which is exactly what this probes.
assert_oniguruma() {
	if ! jq -n '"x" | test("x")' >/dev/null 2>&1; then
		error "jq lacks Oniguruma regex support (test/match unavailable) — required for inline markdown parsing"
		warn  "install a jq build with Oniguruma support (the default on Homebrew/apt/most distros), then re-run"
		exit 1
	fi
}

# trim TEXT — prints TEXT with leading/trailing whitespace stripped.
trim() {
	printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# The inline tokenizer — TWO static, hardcoded jq programs (never built from
# markdown text): tokenize_marks (regex mark-matching) wrapped by tokenize
# (hardBreak splitting). Recognizes, in priority order, left-to-right,
# non-overlapping: ***bold+italic***, **bold**, `code`, [text](url),
# *italic*, _italic_, ~~strike~~ — modeled on the oracle's single combined
# regex, extended (the oracle has none of bold+italic/strike/hardBreak).
# Untrusted text arrives ONLY via --arg; this string is never interpolated
# into the jq source.
#
# Regex (as Oniguruma sees it, after jq string-literal unescaping):
#   \*\*\*([^*]+)\*\*\*|\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\(([^)]+)\)|
#   \*([^*]+)\*|_([^_]+)_|~~([^~]+)~~
# capture group 1 = bold+italic text, 2 = bold text, 3 = code text,
# 4 = link text, 5 = link href, 6 = italic(*) text, 7 = italic(_) text,
# 8 = strike text.
#
# `***bold+italic***` MUST precede `**bold**`, which MUST precede
# `*italic*`, in the alternation: alternation tries branches left-to-right
# at each position and takes the first that matches (leftmost-first, not
# longest-match). `***text***`'s content excludes '*' entirely
# (`[^*]+`, not `.+?`), so it can ONLY match a genuine triple-star pair —
# it can never partially consume a `**bold**` pair (whose content starts
# immediately after exactly two stars) or misfire inside prose. With bold
# listed before italic, `**x**` always matches the bold branch — `*([^*]+)*`
# can never even attempt a match starting on the first `*` of a `**` pair,
# because its own required `[^*]+` immediately rejects the second `*`. An
# unclosed `*only`/`_only` simply never completes any alternative and falls
# through untouched to plain text, by construction — no special-casing
# needed.
#
# A matched link's href is checked against an http(s)/mailto
# scheme allow-list (case-insensitive) before it is trusted as a link mark.
# A disallowed scheme (`javascript:`, `data:`, ...) keeps the link's TEXT
# but drops the mark entirely — the href never reaches the output.
#
# hardBreak: the block parser (not this regex) splits accumulated paragraph
# text on a U+0007 (BEL) sentinel — see line_has_hard_break below — before
# handing each segment here; `tokenize` re-joins the per-segment mark
# results with a literal {"type":"hardBreak"} node between segments. A
# BEL byte in the ORIGINAL input WOULD collide with this sentinel (`read`
# does not reject arbitrary control bytes) — that gap is closed by
# stripping any literal BEL during input normalization (see the
# normalization step below, before this tokenizer ever runs), so by the
# time text reaches here BEL means exactly one thing: a hardBreak join.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: $text/$m/.captures below are jq syntax, not shell expansions
INLINE_TOKENIZE_PROGRAM='
def tokenize_marks:
  . as $t
  | [match("\\*\\*\\*([^*]+)\\*\\*\\*|\\*\\*(.+?)\\*\\*|`([^`]+)`|\\[([^\\]]+)\\]\\(([^)]+)\\)|\\*([^*]+)\\*|_([^_]+)_|~~([^~]+)~~"; "g")] as $ms
  | if ($ms | length) == 0 then
      (if ($t | length) == 0 then [] else [{type:"text", text:$t}] end)
    else
      (reduce $ms[] as $m
        ({nodes: [], last: 0};
          ($m.offset) as $s
          | ($s + $m.length) as $e
          | (if $s > .last then .nodes += [{type:"text", text:($t[.last:$s])}] else . end)
          | (
              if ($m.captures[0].string != null) then
                .nodes += [{type:"text", text:$m.captures[0].string, marks:[{type:"strong"},{type:"em"}]}]
              elif ($m.captures[1].string != null) then
                .nodes += [{type:"text", text:$m.captures[1].string, marks:[{type:"strong"}]}]
              elif ($m.captures[2].string != null) then
                .nodes += [{type:"text", text:$m.captures[2].string, marks:[{type:"code"}]}]
              elif ($m.captures[3].string != null) then
                ($m.captures[4].string) as $href
                | if ($href | test("^(?:https?|mailto):"; "i")) then
                    .nodes += [{type:"text", text:$m.captures[3].string, marks:[{type:"link", attrs:{href:$href}}]}]
                  else
                    .nodes += [{type:"text", text:$m.captures[3].string}]
                  end
              elif ($m.captures[5].string != null) then
                .nodes += [{type:"text", text:$m.captures[5].string, marks:[{type:"em"}]}]
              elif ($m.captures[6].string != null) then
                .nodes += [{type:"text", text:$m.captures[6].string, marks:[{type:"em"}]}]
              elif ($m.captures[7].string != null) then
                .nodes += [{type:"text", text:$m.captures[7].string, marks:[{type:"strike"}]}]
              else .
              end
            )
          | .last = $e
        )
      ) as $acc
      | (if ($t | length) > $acc.last then $acc.nodes + [{type:"text", text:($t[$acc.last:])}] else $acc.nodes end)
    end;
def tokenize:
  ($text | split("\u0007")) as $segs
  | if ($segs | length) <= 1 then
      ($text | tokenize_marks)
    else
      reduce range(0; ($segs | length)) as $i
        ([];
          . + ($segs[$i] | tokenize_marks)
            + (if $i < (($segs | length) - 1) then [{type:"hardBreak"}] else [] end)
        )
    end;
tokenize
'

# tokenize_inline TEXT — prints a compact JSON array of ADF inline nodes for
# TEXT on stdout. TEXT travels only via --arg into the static program above.
tokenize_inline() {
	raw_text=$1
	jq -n -c --arg text "$raw_text" "$INLINE_TOKENIZE_PROGRAM"
}

# line_has_hard_break RAW_LINE — true iff RAW_LINE (BEFORE trimming) ends in
# 2+ literal trailing spaces or a literal trailing backslash — the two
# CommonMark hardBreak triggers.
line_has_hard_break() {
	# shellcheck disable=SC1003  # the *'\') arm is a literal trailing backslash, not an escape — already literal inside single quotes
	case "$1" in
		*'  ') return 0 ;;
		*'\') return 0 ;;
		*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# Empty-container guard (landmine #6): every list/table/quote assembler
# calls this before slurping its buffer, so a buffer that would otherwise be
# empty gets ONE defensive fallback child instead of content:[].
#
# The fallback is CALLER-SUPPLIED, not a hardcoded
# paragraph. A bare {"type":"paragraph"} is only valid where the CONTAINER
# accepts a paragraph directly (blockquote/panel). A listItem needs
# [paragraph]; a tableRow needs [tableCell]; a tableCell/tableHeader needs
# {type:<that type>,attrs:{},content:[paragraph]} — injecting a bare
# paragraph into any of those is itself invalid ADF (this IS the exact
# shape of the zero-field-table-row 400: a stray "|" line
# strips to zero cells, and a bare-paragraph fallback there produced
# tableRow.content:[paragraph] where a tableCell was required). Each call
# site below passes the fallback shaped for what it actually assembles.
# ---------------------------------------------------------------------------
ensure_nonempty_buffer() {
	buffer_path=$1
	fallback_json=$2
	if [ ! -s "$buffer_path" ]; then
		printf '%s\n' "$fallback_json" >"$buffer_path"
	fi
}

# ---------------------------------------------------------------------------
# Block emitters. Each appends ONE compact JSON object (one NDJSON line) to
# $BLOCKS_FILE — the array-free accumulator (see the design note above).
# Plain globals throughout: this script is a single short-lived process, not
# a library, and POSIX sh has no `local`.
# ---------------------------------------------------------------------------
emit_heading() {
	heading_level=$1
	heading_text=$2
	inline_content=$(tokenize_inline "$heading_text") || return 1
	jq -n -c --argjson level "$heading_level" --argjson content "$inline_content" \
		'{type:"heading", attrs:{level:$level}, content:$content}' >>"$BLOCKS_FILE"
}

emit_paragraph() {
	paragraph_text=$1
	inline_content=$(tokenize_inline "$paragraph_text") || return 1
	jq -n -c --argjson content "$inline_content" \
		'{type:"paragraph", content:$content}' >>"$BLOCKS_FILE"
}

emit_rule() {
	jq -n -c '{type:"rule"}' >>"$BLOCKS_FILE"
}

# is_media_uuid VALUE -> 0 iff VALUE is exactly 36 chars of [a-f0-9-] (a v4
# media UUID). The value comes from --media-map and is about to become an ADF
# attribute — a sink-specific control (standard-security "think in taint"):
# anything else is rejected before it can reach the document.
is_media_uuid() {
	media_uuid_candidate=$1
	case "$media_uuid_candidate" in
		''|*[!a-f0-9-]*) return 1 ;;
	esac
	[ "${#media_uuid_candidate}" -eq 36 ]
}

# lookup_media_uuid PATH -> prints the mapped UUID (or nothing if PATH is not a
# key). PATH travels ONLY via --arg into a static program; the map file via
# --slurpfile. Never string-concatenated into jq source.
lookup_media_uuid() {
	lookup_path=$1
	# shellcheck disable=SC2016  # single-quoted: $m/$p are jq syntax, not shell
	jq -rn --slurpfile m "$MEDIA_MAP_FILE" --arg p "$lookup_path" '($m[0][$p]) // ""'
}

# emit_media UUID — appends the ONE verified-rendering mediaSingle block (see
# the header's "Inline images" note) to $BLOCKS_FILE. UUID is passed via --arg
# into a static program; collection is the EMPTY STRING "" (verified: null ->
# 400). The alt text is intentionally not carried (see the header note).
emit_media() {
	media_uuid=$1
	# shellcheck disable=SC2016  # single-quoted: $id is jq syntax, not shell
	jq -n -c --arg id "$media_uuid" \
		'{type:"mediaSingle", attrs:{layout:"center"},
		  content:[{type:"media", attrs:{type:"file", id:$id, collection:""}}]}' \
		>>"$BLOCKS_FILE" \
		|| { error "internal jq failure (media block assembly)"; exit 1; }
}

# emit_code_block — assembles $FENCE_BODY_FILE (raw, UNPARSED fence content)
# into one codeBlock node via `jq -Rs`: `-R` reads raw (non-JSON) input,
# `-s` slurps it all into ONE string, so `.` is the whole multi-line body
# with real newlines already correctly represented — the inline tokenizer
# is NEVER invoked here (landmine #3: no marks can ever reach fence text).
emit_code_block() {
	jq -Rs --arg lang "$FENCE_LANG" \
		'{type:"codeBlock",
		  attrs: (if $lang == "" then {} else {language:$lang} end),
		  content: (if (. | length) == 0 then [] else [{type:"text", text:.}] end)}' \
		<"$FENCE_BODY_FILE" >>"$BLOCKS_FILE" \
		|| { error "internal jq failure (code block assembly)"; exit 1; }
}

# append_list_item TEXT — adds one listItem (wrapping a paragraph) to the
# CURRENTLY OPEN (innermost) list level's buffer file.
append_list_item() {
	item_text=$1
	inline_content=$(tokenize_inline "$item_text") || return 1
	jq -n -c --argjson content "$inline_content" \
		'{type:"listItem", content:[{type:"paragraph", content:$content}]}' >>"$(list_top_buffer)"
}

# ---------------------------------------------------------------------------
# Nested-list stack — see the header's "Nested lists" design note. Encoded
# as one '|'-delimited string, innermost level last: "indent:type:buffer".
#
# Indent is always a plain decimal integer and type is
# always exactly "bulletList"/"orderedList" — both are internally
# generated, fixed-shape, colon-free, pipe-free. buffer is the one
# variable-content field: an `mktemp` path under $TMPDIR, which is
# EXTERNALLY supplied and could in principle contain a ':' or '|'.
# list_top_indent/_type/_buffer split on the FIRST two colons only (plain
# parameter expansion, not `cut -d: -fN`), so an extra ':' anywhere inside
# the buffer path is harmless — it just stays part of the (correctly
# extracted) path. A '|' inside the path is NOT similarly recoverable —
# the stack's OWN level separator is '|', so a path containing one would
# be indistinguishable from an entry boundary — which is why
# validate_tmpdir (below) fails closed on a ':' or '|' in $TMPDIR itself,
# rather than trying to structurally survive it.
# ---------------------------------------------------------------------------
LIST_STACK=""
LIST_DEPTH=0

list_top_entry()  { printf '%s' "${LIST_STACK##*|}"; }
list_top_indent() { entry=$(list_top_entry); printf '%s' "${entry%%:*}"; }
list_top_type()   { entry=$(list_top_entry); rest=${entry#*:}; printf '%s' "${rest%%:*}"; }
list_top_buffer() { entry=$(list_top_entry); rest=${entry#*:}; printf '%s' "${rest#*:}"; }

# validate_tmpdir — fails closed if ${TMPDIR:-/tmp} contains a ':' or '|'.
# Every mktemp path this script creates lives under this directory and
# ends up embedded in LIST_STACK (see above); a colon is survivable by
# construction, but a pipe is not, so this is the guard for that case
# rather than a parsing trick. Checked once, before anything is created.
validate_tmpdir() {
	tmpdir_to_check=${TMPDIR:-/tmp}
	case "$tmpdir_to_check" in
		*':'*|*'|'*)
			error "TMPDIR contains ':' or '|', which this script cannot safely use: $tmpdir_to_check"
			exit 1 ;;
	esac
}

# list_push INDENT TYPE — opens a new (deeper) list level.
list_push() {
	push_buffer=$(mktemp "${TMPDIR:-/tmp}/md-to-adf.list$LIST_DEPTH.XXXXXX")
	register_temp_file "$push_buffer"
	push_entry="$1:$2:$push_buffer"
	if [ -z "$LIST_STACK" ]; then
		LIST_STACK=$push_entry
	else
		LIST_STACK="${LIST_STACK}|${push_entry}"
	fi
	LIST_DEPTH=$((LIST_DEPTH + 1))
}

# list_pop — removes the top (innermost) level from the stack, WITHOUT
# assembling/folding it (see list_pop_and_fold, which wraps this).
list_pop() {
	pop_top=$(list_top_entry)
	if [ "$LIST_STACK" = "$pop_top" ]; then
		LIST_STACK=""
	else
		LIST_STACK=${LIST_STACK%|*}
	fi
	LIST_DEPTH=$((LIST_DEPTH - 1))
}

# fold_block_into_last_item PARENT_BUFFER BLOCK_JSON — splices BLOCK_JSON
# into the LAST NDJSON line of PARENT_BUFFER as a SECOND content element
# (a sibling of that item's paragraph) — the nested-list attachment point
# required by the spec. Portable "amend the last line": `sed '$d'` (drop
# the last line — POSIX, unlike GNU-only `head -n -1`) into a fresh temp
# file, then re-append the transformed line.
fold_block_into_last_item() {
	fold_parent_buffer=$1
	fold_block_json=$2
	[ -s "$fold_parent_buffer" ] || return 0
	fold_last_line=$(sed -n '$p' "$fold_parent_buffer")
	fold_tmp=$(mktemp "${TMPDIR:-/tmp}/md-to-adf.fold.XXXXXX")
	register_temp_file "$fold_tmp"
	sed '$d' "$fold_parent_buffer" >"$fold_tmp"
	printf '%s\n' "$fold_last_line" \
		| jq -c --argjson nested "$fold_block_json" '.content += [$nested]' >>"$fold_tmp" \
		|| { error "internal jq failure (nested-list fold)"; exit 1; }
	mv "$fold_tmp" "$fold_parent_buffer"
}

# list_pop_and_fold — assembles the current top level into one compact
# bulletList/orderedList block, pops it, and either folds it into the new
# top's last item (nested case) or appends it straight to $BLOCKS_FILE
# (the level was the outermost).
list_pop_and_fold() {
	fold_type=$(list_top_type)
	fold_buffer=$(list_top_buffer)
	ensure_nonempty_buffer "$fold_buffer" '{"type":"listItem","content":[{"type":"paragraph"}]}'
	fold_block=$(jq -s -c --arg type "$fold_type" '{type:$type, content:.}' "$fold_buffer") \
		|| { error "internal jq failure (list assembly)"; exit 1; }
	# Optional-perf note (reviewed, addressed): free the buffer the instant
	# it's fully consumed rather than leaving it for the final EXIT trap —
	# a deeply-nested-list document would otherwise accumulate one
	# already-unneeded temp file per level for the rest of the run. The
	# ALL_TEMP_FILES registry entry becomes a harmless no-op `rm -f` later.
	rm -f "$fold_buffer" 2>/dev/null || true
	list_pop
	if [ "$LIST_DEPTH" -eq 0 ]; then
		printf '%s\n' "$fold_block" >>"$BLOCKS_FILE"
	else
		fold_block_into_last_item "$(list_top_buffer)" "$fold_block"
	fi
}

# list_close_all — pops every open level (deepest first), fully flushing
# any in-progress list to $BLOCKS_FILE. Idempotent (a no-op when no list is
# open) — the drop-in replacement for every existing "flush the list" call
# site (blank line, heading, rule, fence/table/quote open, paragraph line,
# EOF), unchanged in shape from the single-level design this replaced.
list_close_all() {
	while [ "$LIST_DEPTH" -gt 0 ]; do
		list_pop_and_fold
	done
}

# list_open_item INDENT TYPE ITEM_TEXT — the nested-list state machine's
# entry point for one bullet/ordered line. See the header's design note for
# the pop/continue/replace/push decision table this implements.
list_open_item() {
	open_indent=$1
	open_type=$2
	open_item_text=$3

	while [ "$LIST_DEPTH" -gt 0 ] && [ "$(list_top_indent)" -gt "$open_indent" ]; do
		list_pop_and_fold
	done

	if [ "$LIST_DEPTH" -gt 0 ] && [ "$(list_top_indent)" -eq "$open_indent" ]; then
		if [ "$(list_top_type)" != "$open_type" ]; then
			list_pop_and_fold
			list_push "$open_indent" "$open_type"
		fi
	else
		list_push "$open_indent" "$open_type"
	fi

	append_list_item "$open_item_text"
}

# leading_ws_count RAW_LINE — sets $INDENT to the count of leading
# space/tab characters in RAW_LINE (a plain char-by-char parameter-
# expansion loop — no subprocess, POSIX-safe).
leading_ws_count() {
	ws_line=$1
	ws_count=0
	while :; do
		case $ws_line in
			' '*|'	'*) ws_count=$((ws_count + 1)); ws_line=${ws_line#?} ;;
			*) break ;;
		esac
	done
	INDENT=$ws_count
}

# ---------------------------------------------------------------------------
# Blockquote / panel assembly.
# ---------------------------------------------------------------------------

# detect_panel_type MARKER_TEXT — prints the ADF panelType and returns 0 if
# MARKER_TEXT is a recognized GitHub-alert marker; returns 1 (prints
# nothing) otherwise. panelType is ALWAYS one of this fixed enum — never a
# raw string derived from the input (landmine #5).
detect_panel_type() {
	panel_marker=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
	case "$panel_marker" in
		'[!INFO]')      printf 'info' ;;
		'[!NOTE]')      printf 'note' ;;
		'[!WARNING]')   printf 'warning' ;;
		'[!SUCCESS]')   printf 'success' ;;
		'[!ERROR]')     printf 'error' ;;
		'[!TIP]')       printf 'success' ;;
		'[!CAUTION]')   printf 'error' ;;
		'[!IMPORTANT]') printf 'warning' ;;
		*) return 1 ;;
	esac
}

# quote_flush_paragraph — mirrors flush_paragraph, but targets the
# blockquote/panel-in-progress paragraph buffer instead of $BLOCKS_FILE.
quote_flush_paragraph() {
	if [ -n "$QUOTE_PARA_TEXT" ]; then
		quote_inline=$(tokenize_inline "$QUOTE_PARA_TEXT") || exit 1
		jq -n -c --argjson content "$quote_inline" '{type:"paragraph", content:$content}' >>"$QUOTE_BUFFER_FILE" \
			|| { error "internal jq failure (blockquote paragraph)"; exit 1; }
	fi
	QUOTE_PARA_TEXT=""
}

# quote_close — flushes any pending paragraph, assembles $QUOTE_BUFFER_FILE
# into one blockquote or panel node (panelType from $QUOTE_PANEL_TYPE, set
# only via detect_panel_type), appends it to $BLOCKS_FILE, and resets all
# quote state. Idempotent when no quote is open.
quote_close() {
	[ "$QUOTE_OPEN" = "1" ] || return 0
	quote_flush_paragraph
	ensure_nonempty_buffer "$QUOTE_BUFFER_FILE" '{"type":"paragraph"}'
	if [ -n "$QUOTE_PANEL_TYPE" ]; then
		jq -s -c --arg panelType "$QUOTE_PANEL_TYPE" '{type:"panel", attrs:{panelType:$panelType}, content:.}' "$QUOTE_BUFFER_FILE" >>"$BLOCKS_FILE" \
			|| { error "internal jq failure (panel assembly)"; exit 1; }
	else
		jq -s -c '{type:"blockquote", content:.}' "$QUOTE_BUFFER_FILE" >>"$BLOCKS_FILE" \
			|| { error "internal jq failure (blockquote assembly)"; exit 1; }
	fi
	QUOTE_OPEN=0
	QUOTE_PANEL_TYPE=""
	: >"$QUOTE_BUFFER_FILE"
}

# ---------------------------------------------------------------------------
# Table assembly.
# ---------------------------------------------------------------------------

# is_table_delimiter_row ROW — true iff ROW (already trimmed) is a valid
# GFM header-separator row: only space/':'/'|'/'-' characters, with at
# least one '-' AND at least one '|' (requiring a pipe stops a
# bare "---" — a rule, or an unrelated dash run — directly under a
# '|'-prefixed candidate header line from being misread as a genuine GFM
# delimiter row; a real delimiter row always has at least one column
# separator). Used ONLY as a 1-line lookahead confirmation (via a direct
# `sed -n 'Np'` peek at $NORMALIZED_FILE — see the header's design note) —
# never to consume input.
is_table_delimiter_row() {
	delim_row=$1
	[ -n "$delim_row" ] || return 1
	printf '%s\n' "$delim_row" | grep -Eq '^[[:space:]:|-]+$' || return 1
	printf '%s\n' "$delim_row" | grep -Fq -- '-' || return 1
	printf '%s\n' "$delim_row" | grep -Fq -- '|'
}

# split_table_row_cells ROW -- prints a compact JSON ARRAY of cell TEXT
# strings for ROW, split on '|', with two protections a naive IFS='|'
# split misses:
#   - an escaped pipe \| is unescaped to a literal | WITHIN a cell,
#     never treated as a field boundary;
#   - a | inside a `code span` is likewise protected -- a table row with
#     an inline code cell like | `a|b` | splits into ONE cell, not two.
# Mechanism: two Unicode PRIVATE-USE-AREA characters, U+E000 and U+E001,
# temporarily stand in for a protected pipe so a plain split("|") only
# ever splits on a REAL boundary; both are restored to literal | in every
# resulting field afterward. These ARE two literal multi-byte UTF-8
# characters sitting in this file, not an ASCII backslash-u escape -- every
# attempt to author the escape-sequence FORM here got silently re-decoded
# back into the raw character by the editing tooling itself, so the raw
# character is what is actually on disk; grep/diff/a hex dump will show it
# as ordinary well-formed UTF-8, not a stray byte. This is a DIFFERENT
# risk profile than the earlier BEL-sentinel case, not the same mistake
# repeated: a PUA character is valid, renderable (if unusual) Unicode text
# that ordinary UTF-8-aware editors, git diff, and line-based filters
# preserve byte-for-byte -- unlike a bare C0 control byte (BEL), which
# some tools DO special-case and strip. If this ever needs re-verifying,
# use "sed -n 'Np' FILE | xxd" and look for the 3-byte sequences ee 80 80
# (U+E000) / ee 80 81 (U+E001) -- NOT od -c, which renders them as an
# unhelpful "**" and can look empty at a glance.
# Known limitation (documented, not fixed): a | inside a LINK's
# [text](url) portion is NOT protected -- that would need the full
# CommonMark inline grammar (link syntax, nested spans) ahead of table
# parsing, which this flat model does not implement. Escape it as \| if
# it matters.
split_table_row_cells() {
	row_text=$1
	jq -n -c --arg row "$row_text" '
		$row
		| gsub("[\\\\][|]"; "")
		| gsub("`(?<inner>[^`]*)`"; "`" + (.inner | gsub("[|]"; "")) + "`")
		| split("|")
		| map(gsub("|"; "|"))
	' || { error "internal jq failure (table row split)"; exit 1; }
}

# table_row_to_cells_json ROW CELL_TYPE — prints a compact JSON ARRAY of
# CELL_TYPE ("tableHeader"|"tableCell") node objects, one per field from
# split_table_row_cells. An empty cell gets {"type":"paragraph"} with NO
# content key (landmine #2) rather than a paragraph holding an empty text
# node. A stray "|"/"||" row strips to an EMPTY string, and jq's
# `"" | split("|")` yields `[]` (zero fields, NOT `[""]`) — so this IS the
# primary path through which the zero-field row is fixed: the
# `while read` loop below runs zero times, leaving $cells_buffer empty, and
# ensure_nonempty_buffer's CORRECTLY-TYPED fallback (a real tableCell/
# tableHeader wrapping an empty paragraph, not a bare paragraph) is what
# produces the one required child. There is no "already handled by the
# per-field loop" shortcut for this case — verify any future refactor of
# this function keeps that fallback correctly typed.
table_row_to_cells_json() {
	row_text=$1
	cell_node_type=$2

	row_stripped=$row_text
	case "$row_stripped" in '|'*) row_stripped=${row_stripped#'|'} ;; esac
	case "$row_stripped" in *'|') row_stripped=${row_stripped%'|'} ;; esac

	cells_buffer=$(mktemp "${TMPDIR:-/tmp}/md-to-adf.cells.XXXXXX")
	register_temp_file "$cells_buffer"

	cell_fields_json=$(split_table_row_cells "$row_stripped")

	printf '%s' "$cell_fields_json" | jq -r '.[]' | while IFS= read -r raw_cell; do
		cell_text=$(trim "$raw_cell")
		if [ -z "$cell_text" ]; then
			cell_para=$(jq -n -c '{type:"paragraph"}')
		else
			cell_inline=$(tokenize_inline "$cell_text") || exit 1
			cell_para=$(jq -n -c --argjson content "$cell_inline" '{type:"paragraph", content:$content}')
		fi
		jq -n -c --arg type "$cell_node_type" --argjson para "$cell_para" \
			'{type:$type, attrs:{}, content:[$para]}' >>"$cells_buffer"
	done

	cell_fallback=$(jq -n -c --arg type "$cell_node_type" '{type:$type, attrs:{}, content:[{type:"paragraph"}]}')
	ensure_nonempty_buffer "$cells_buffer" "$cell_fallback"
	cells_json=$(jq -s -c '.' "$cells_buffer") || { error "internal jq failure (table cell assembly)"; exit 1; }
	# Optional-perf note (reviewed, addressed): free the buffer as soon as
	# it's fully consumed — a many-column, many-row table would otherwise
	# accumulate one already-unneeded temp file per row for the rest of
	# the run (same rationale as list_pop_and_fold's rm above).
	rm -f "$cells_buffer" 2>/dev/null || true
	printf '%s\n' "$cells_json"
}

# table_open HEADER_ROW — starts a new table: the header row becomes one
# tableRow of tableHeader cells, appended to $TABLE_ROWS_BUFFER.
table_open() {
	header_cells=$(table_row_to_cells_json "$1" "tableHeader")
	jq -n -c --argjson cells "$header_cells" '{type:"tableRow", content:$cells}' >>"$TABLE_ROWS_BUFFER" \
		|| { error "internal jq failure (table header row)"; exit 1; }
	TABLE_STATE="AWAITING_DELIMITER"
}

# table_add_row ROW — appends ROW as one tableRow of tableCell cells.
table_add_row() {
	row_cells=$(table_row_to_cells_json "$1" "tableCell")
	jq -n -c --argjson cells "$row_cells" '{type:"tableRow", content:$cells}' >>"$TABLE_ROWS_BUFFER" \
		|| { error "internal jq failure (table data row)"; exit 1; }
}

# table_close — assembles $TABLE_ROWS_BUFFER into one table node (fixed
# attrs per spec) and appends it to $BLOCKS_FILE. Idempotent.
table_close() {
	[ "$TABLE_STATE" = "CLOSED" ] && return 0
	ensure_nonempty_buffer "$TABLE_ROWS_BUFFER" '{"type":"tableRow","content":[{"type":"tableCell","attrs":{},"content":[{"type":"paragraph"}]}]}'
	jq -s -c '{type:"table", attrs:{isNumberColumnEnabled:false, layout:"default"}, content:.}' "$TABLE_ROWS_BUFFER" >>"$BLOCKS_FILE" \
		|| { error "internal jq failure (table assembly)"; exit 1; }
	TABLE_STATE="CLOSED"
	: >"$TABLE_ROWS_BUFFER"
}

# flush_paragraph — if paragraph text has accumulated (possibly joined from
# several consecutive plain-text lines, matching the oracle's join-with-
# space behavior, or joined with a hardBreak sentinel — see
# line_has_hard_break), emit it as one paragraph block. Always resets,
# idempotent.
flush_paragraph() {
	if [ -n "$PARA_TEXT" ]; then
		emit_paragraph "$PARA_TEXT" || exit 1
	fi
	PARA_TEXT=""
	PARA_PENDING_HARD_BREAK=0
}

# ---------------------------------------------------------------------------
# Temp files + cleanup. A single growing registry (not one variable per
# file) — this script now creates a variable NUMBER of temp files (one per
# nested-list level, one per fold, ...), so a fixed set of named variables
# (the shape used before nesting/tables existed) no longer fits; a
# registry is the right data structure for "however many were created this
# run" (DRY vs YAGNI: 2+ real, present, growing use cases now justify it).
# ---------------------------------------------------------------------------
# NEWLINE-delimited, not space-delimited — a $TMPDIR
# containing a space (unusual but legal) would otherwise split one
# registered path into two garbage entries and leak the real file on
# cleanup. A literal newline in a path is not something POSIX filesystems
# forbid, but every path here is one WE generated via our own `mktemp`
# calls, never derived from markdown content, so this is a closed set we
# control — unlike $TMPDIR itself, which is externally supplied (see
# validate_tmpdir below, which rules out the one separator this registry
# still can't tolerate: a literal newline in $TMPDIR).
ALL_TEMP_FILES=""
register_temp_file() {
	ALL_TEMP_FILES="${ALL_TEMP_FILES}${1}
"
}

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	ec=$?
	printf '%s' "$ALL_TEMP_FILES" | while IFS= read -r temp_file; do
		[ -n "$temp_file" ] || continue
		rm -f "$temp_file" 2>/dev/null || true
	done
	exit "$ec"
}
trap cleanup EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_FILE=""
OPT_MEDIA_MAP=""

while [ $# -gt 0 ]; do
	case "$1" in
		--file)      need_arg "$1" "${2:-}"; OPT_FILE=$2; shift ;;
		--media-map) need_arg "$1" "${2:-}"; OPT_MEDIA_MAP=$2; shift ;;
		-h|--help)   usage; exit 0 ;;
		--)          shift; break ;;
		-*)          usage >&2; error "unknown option: $1"; exit 2 ;;
		*)           usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

if [ -n "$OPT_FILE" ] && { [ ! -f "$OPT_FILE" ] || [ ! -r "$OPT_FILE" ]; }; then
	usage >&2
	error "--file does not exist or is not readable: $OPT_FILE"
	exit 2
fi

if [ -n "$OPT_MEDIA_MAP" ] && { [ ! -f "$OPT_MEDIA_MAP" ] || [ ! -r "$OPT_MEDIA_MAP" ]; }; then
	usage >&2
	error "--media-map does not exist or is not readable: $OPT_MEDIA_MAP"
	exit 2
fi

# MEDIA_MAP_FILE is the resolved media map (empty when --media-map is absent).
# When present it must parse as a JSON OBJECT — the block parser reads it only
# via --slurpfile into a static jq program, but a clear error here beats an
# opaque internal jq failure later.
MEDIA_MAP_FILE=$OPT_MEDIA_MAP

# ---------------------------------------------------------------------------
# jq + Oniguruma preconditions
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
	error "jq is not installed"
	warn  "install it (e.g. https://jqlang.org) then re-run"
	exit 1
fi

assert_oniguruma
validate_tmpdir

# A --media-map must be a JSON OBJECT (path -> UUID). Validated here, after jq
# is confirmed present, so a malformed map is a clear named failure rather than
# an opaque jq abort at the first lookup.
if [ -n "$MEDIA_MAP_FILE" ] && ! jq -e 'type == "object"' "$MEDIA_MAP_FILE" >/dev/null 2>&1; then
	error "--media-map is not a JSON object: $MEDIA_MAP_FILE"
	exit 1
fi

# ---------------------------------------------------------------------------
# Read the input (file or stdin) into a real file, byte-exact — never held
# in a shell variable, so a trailing-newline or embedded-NUL surprise from
# `$(...)` never applies.
# ---------------------------------------------------------------------------
if [ -n "$OPT_FILE" ]; then
	RAW_INPUT_FILE=$OPT_FILE
else
	STDIN_TMP=$(mktemp "${TMPDIR:-/tmp}/md-to-adf.stdin.XXXXXX")
	register_temp_file "$STDIN_TMP"
	cat >"$STDIN_TMP"
	RAW_INPUT_FILE=$STDIN_TMP
fi

# ---------------------------------------------------------------------------
# Normalize literal "\n" sequences to real newlines (mirrors the oracle's
# `.replace('\\n', '\n')` — callers may hand us a JSON-string-shaped value
# with escaped newlines rather than real ones). `split`/`join` on a plain
# jq STRING (not a regex) — no Oniguruma dependency for this step.
#
# ALSO strips any literal BEL (U+0007) byte from the input here.
# The hardBreak sentinel (see line_has_hard_break / the tokenizer's
# `tokenize` function) relies on BEL never appearing in real text reaching
# the tokenizer — that claim was FALSE as originally written ("BEL cannot
# appear in real input read via `read` in POSIX sh"): `read` does not
# reject or strip arbitrary non-newline bytes, so a markdown file
# containing a literal BEL byte WOULD collide with the sentinel and
# degrade to a hardBreak between every character. Stripping BEL here,
# before anything else ever sees the text, removes the collision instead
# of merely asserting it away in a comment.
# ---------------------------------------------------------------------------
NORMALIZED_FILE=$(mktemp "${TMPDIR:-/tmp}/md-to-adf.norm.XXXXXX")
register_temp_file "$NORMALIZED_FILE"
jq -n -r --rawfile raw "$RAW_INPUT_FILE" '$raw | split("\\n") | join("\n") | split("\u0007") | join("")' >"$NORMALIZED_FILE" \
	|| { error "internal jq failure (input normalization)"; exit 1; }

BLOCKS_FILE=$(mktemp "${TMPDIR:-/tmp}/md-to-adf.blocks.XXXXXX")
register_temp_file "$BLOCKS_FILE"
FENCE_BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/md-to-adf.fence.XXXXXX")
register_temp_file "$FENCE_BODY_FILE"
QUOTE_BUFFER_FILE=$(mktemp "${TMPDIR:-/tmp}/md-to-adf.quote.XXXXXX")
register_temp_file "$QUOTE_BUFFER_FILE"
TABLE_ROWS_BUFFER=$(mktemp "${TMPDIR:-/tmp}/md-to-adf.table.XXXXXX")
register_temp_file "$TABLE_ROWS_BUFFER"

# ---------------------------------------------------------------------------
# The block parser — one pass, one line at a time. Stateful constructs
# (fence/table/quote/nested-lists) track OPEN/depth across iterations
# rather than using lookahead-with-pushback (see the header's design note).
# ---------------------------------------------------------------------------
PARA_TEXT=""
PARA_PENDING_HARD_BREAK=0
FENCE_OPEN=0
FENCE_LANG=""
TABLE_STATE="CLOSED"
QUOTE_OPEN=0
QUOTE_PANEL_TYPE=""
QUOTE_PARA_TEXT=""
LINE_NO=0

# shellcheck disable=SC2094  # the in-loop sed peek (table lookahead) only READS $NORMALIZED_FILE via its own fd; this redirection never writes it
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
	LINE_NO=$((LINE_NO + 1))

	# --- fenced code: highest priority, bypasses ALL other classification
	# (including blank-line handling) so fence content is captured
	# byte-verbatim, untrimmed, with no markdown parsing whatsoever. ---
	if [ "$FENCE_OPEN" = "1" ]; then
		fence_trimmed=$(trim "$raw_line")
		if [ "$fence_trimmed" = '```' ]; then
			emit_code_block
			FENCE_OPEN=0
			FENCE_LANG=""
			continue
		fi
		printf '%s\n' "$raw_line" >>"$FENCE_BODY_FILE"
		continue
	fi

	trimmed=$(trim "$raw_line")

	# --- table continuation: state persists across iterations; a
	# non-matching line ends the table and falls through (same iteration,
	# no pushback needed — see the header's design note). ---
	if [ "$TABLE_STATE" = "AWAITING_DELIMITER" ]; then
		TABLE_STATE="IN_BODY"
		continue
	fi
	if [ "$TABLE_STATE" = "IN_BODY" ]; then
		case "$trimmed" in
			'|'*) table_add_row "$trimmed"; continue ;;
			*) table_close ;;
		esac
	fi

	# --- blockquote/panel continuation: same fall-through pattern. ---
	if [ "$QUOTE_OPEN" = "1" ]; then
		case "$trimmed" in
			'>')
				quote_flush_paragraph
				continue ;;
			'> '*)
				quote_content=${trimmed#'> '}
				if [ -n "$QUOTE_PARA_TEXT" ]; then
					QUOTE_PARA_TEXT="$QUOTE_PARA_TEXT $quote_content"
				else
					QUOTE_PARA_TEXT=$quote_content
				fi
				continue ;;
			*) quote_close ;;
		esac
	fi

	if [ -z "$trimmed" ]; then
		flush_paragraph
		list_close_all
		continue
	fi

	case "$trimmed" in
		'###### '*)
			flush_paragraph
			list_close_all
			emit_heading 6 "${trimmed#"###### "}"
			continue ;;
		'##### '*)
			flush_paragraph
			list_close_all
			emit_heading 5 "${trimmed#"##### "}"
			continue ;;
		'#### '*)
			flush_paragraph
			list_close_all
			emit_heading 4 "${trimmed#"#### "}"
			continue ;;
		'### '*)
			flush_paragraph
			list_close_all
			emit_heading 3 "${trimmed#"### "}"
			continue ;;
		'## '*)
			flush_paragraph
			list_close_all
			emit_heading 2 "${trimmed#"## "}"
			continue ;;
		'# '*)
			flush_paragraph
			list_close_all
			emit_heading 1 "${trimmed#"# "}"
			continue ;;
		'---')
			flush_paragraph
			list_close_all
			emit_rule
			continue ;;
		'```'*)
			flush_paragraph
			list_close_all
			FENCE_LANG=$(trim "${trimmed#'```'}")
			: >"$FENCE_BODY_FILE"
			FENCE_OPEN=1
			continue ;;
	esac

	# --- own-line inline image (block-level media). ONLY when --media-map is
	# supplied: a line that is SOLELY `![alt](PATH)` with a LOCAL (non-http(s))
	# PATH found in the map becomes a mediaSingle block. Anything else (no map,
	# http(s) PATH, or PATH not in the map) falls through untouched to the
	# paragraph default below = today's behavior (see the header's fallback
	# note). A mapped-but-malformed UUID fails loud in emit_media's caller. ---
	if [ -n "$MEDIA_MAP_FILE" ]; then
		case "$trimmed" in
			'!['*']('*')')
				img_rest=${trimmed#'!['}
				img_after_alt=${img_rest#*']('}
				img_path=${img_after_alt%')'}
				case "$img_path" in
					http://*|https://*) : ;;
					*)
						img_uuid=$(lookup_media_uuid "$img_path")
						if [ -n "$img_uuid" ]; then
							if ! is_media_uuid "$img_uuid"; then
								error "--media-map value for '$img_path' is not a valid media UUID"
								exit 1
							fi
							flush_paragraph
							list_close_all
							emit_media "$img_uuid"
							continue
						fi
						;;
				esac
				;;
		esac
	fi

	# --- table header candidate: a genuine 1-line lookahead (peek only —
	# never consumes from the stream). ---
	case "$trimmed" in
		'|'*)
			# shellcheck disable=SC2094  # read-only peek via its own fd; $NORMALIZED_FILE is never written anywhere in this script
			next_raw=$(sed -n "$((LINE_NO + 1))p" "$NORMALIZED_FILE")
			next_trimmed=$(trim "$next_raw")
			if is_table_delimiter_row "$next_trimmed"; then
				flush_paragraph
				list_close_all
				table_open "$trimmed"
				continue
			fi
			;;
	esac

	# --- blockquote/panel open ---
	case "$trimmed" in
		'>'|'> '*)
			flush_paragraph
			list_close_all
			quote_marker=${trimmed#'>'}
			quote_marker=$(trim "$quote_marker")
			if panel_type=$(detect_panel_type "$quote_marker"); then
				QUOTE_PANEL_TYPE=$panel_type
			else
				QUOTE_PANEL_TYPE=""
				QUOTE_PARA_TEXT=$quote_marker
			fi
			QUOTE_OPEN=1
			continue ;;
	esac

	if printf '%s\n' "$trimmed" | grep -Eq '^[0-9]+\.[[:space:]]'; then
		flush_paragraph
		leading_ws_count "$raw_line"
		item_text=$(printf '%s\n' "$trimmed" | sed -E 's/^[0-9]+\.[[:space:]]+//')
		list_open_item "$INDENT" "orderedList" "$item_text"
		continue
	fi

	case "$trimmed" in
		'- '*|'* '*)
			flush_paragraph
			leading_ws_count "$raw_line"
			item_text=${trimmed#??}
			list_open_item "$INDENT" "bulletList" "$item_text"
			continue ;;
	esac

	# Anything else (a plain line, or a line whose markdown construct we
	# don't recognize) becomes paragraph text: this IS the degrade-to-
	# paragraph default, with no special-casing required. Consecutive such
	# lines join with a space (or a hardBreak sentinel — see
	# line_has_hard_break), matching the oracle's join-with-space behavior
	# for the no-hardBreak case.
	list_close_all
	if [ -n "$PARA_TEXT" ]; then
		if [ "$PARA_PENDING_HARD_BREAK" = "1" ]; then
			join_sep=$(printf '\a')
		else
			join_sep=' '
		fi
		PARA_TEXT="${PARA_TEXT}${join_sep}${trimmed}"
	else
		PARA_TEXT=$trimmed
	fi
	if line_has_hard_break "$raw_line"; then
		PARA_PENDING_HARD_BREAK=1
	else
		PARA_PENDING_HARD_BREAK=0
	fi
done <"$NORMALIZED_FILE"

# EOF: close out whatever was still open, in the same order a mid-document
# transition would (fence first — an unterminated fence auto-closes with
# whatever was collected, fail-soft rather than crash).
if [ "$FENCE_OPEN" = "1" ]; then
	emit_code_block
fi
[ "$TABLE_STATE" = "IN_BODY" ] && table_close
quote_close
flush_paragraph
list_close_all

# Empty or whitespace-only input leaves $BLOCKS_FILE
# empty (nothing was ever flushed). An ADF doc with content:[] is what
# Jira's API may reject as invalid — fall back to a single empty paragraph,
# the minimal always-valid ADF shape (see the header's divergence note #3).
if [ ! -s "$BLOCKS_FILE" ]; then
	jq -n -c '{type:"paragraph"}' >"$BLOCKS_FILE" \
		|| { error "internal jq failure (empty-input fallback)"; exit 1; }
fi

jq -s '{type:"doc", version:1, content:.}' "$BLOCKS_FILE" \
	|| { error "internal jq failure (document assembly)"; exit 1; }
