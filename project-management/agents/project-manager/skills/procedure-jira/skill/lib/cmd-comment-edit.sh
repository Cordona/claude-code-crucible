# shellcheck shell=sh
#
# cmd-comment-edit.sh — `comment-edit <KEY> --comment-id N --text-file PATH`:
#                       READ the existing comment, then convert the markdown to
#                       ADF (uploading any inline images first) and PUT it as the
#                       REPLACEMENT body of that comment.
#
# IT REPLACES THE BODY ENTIRELY — it never appends. PUT /rest/api/3/issue/<KEY>/
# comment/<ID> overwrites the comment's whole `body` with the document sent:
# whatever that comment said before is gone, with no Jira undo. This is the same
# replace-not-append semantics `update --description-file` carries (cmd-update.sh
# documents it there, and warns for the same reason on --labels), and it is
# stated here because the CONSENT GATE the calling flow shows a human before
# applying an edit must disclose that the old text is being discarded, not added
# to — the caller cannot infer that from the flag name.
#
# THE READ-BEFORE-WRITE GET IS MANDATORY, on every invocation, and is the FIRST
# network call this command makes. It closes two gaps a PUT-only implementation
# had, and each needs the GET for a different reason:
#   * DISCLOSURE. The target is chosen by nothing but a caller-supplied numeric
#     id, and a wrong-but-VALID id (a typo, a stale reference read off an old
#     `view --json`) destroys an unrelated comment's text. Without the read, the
#     strongest thing a consent gate could tell a human was "edit comment N" —
#     never WHAT is about to be discarded, nor who wrote it. `--plan` below turns
#     the fetched body, author and creation date into that disclosure.
#   * ORPHANED ATTACHMENTS. The inline-image pre-pass uploads each own-line local
#     image to the ISSUE before the comment body is built, and an upload is not
#     undone by a later failure. With the PUT as the first call that could ever
#     reject a bad --comment-id, a failed edit left those images permanently
#     attached — a side effect the consent gate never disclosed. Ordering the GET
#     ahead of resolve_inline_images makes a bad id fail while nothing has been
#     uploaded yet. This holds for EVERY invocation, not only --plan: an opt-in
#     preview would have left the default path carrying the same risk. That
#     ordering is anchored in the CODE rather than in this paragraph — see
#     comment_edit_require_existing for how, and why prose was not enough.
# Both hang on the same fact — a 200 from GET on the exact URL the PUT will use
# is what proves the target exists — so the two calls share one built URL below.
#
# comment-edit --plan (read this before wiring the P4/P5 consent gate):
#   `comment-edit <KEY> --comment-id N --text-file PATH --plan` performs EXACTLY
#   the one GET above and then RETURNS: no PUT, and — because the plan branch
#   sits ahead of resolve_inline_images — no attachment upload either, so a
#   preview cannot leave a trace on the issue. It prints the ticket, the comment
#   id, that comment's author/creation date, and the stored body it would
#   discard, closing on the engine's shared "NOTHING WAS WRITTEN (dry-run /
#   --plan)" line. `--plan --json` emits the same disclosure structurally
#   (including the raw stored ADF under .existingBody, so nothing is lossy) with
#   executed:false — the same executed flag `transition --plan` carries, for the
#   same reason: the orchestrator runs --plan, shows the human exactly what would
#   be destroyed, and only THEN (on explicit consent) re-invokes WITHOUT --plan.
#   Unlike transition, the shapes of --plan --json and a real edit's --json
#   deliberately DIVERGE rather than route through one renderer: a real edit
#   passes Jira's own updated-comment object straight through (there is a write
#   response, and it IS the answer), while a plan has no write response at all
#   and must synthesize one — the same passthrough-vs-synthesized split
#   cmd_comment and cmd_update already sit on either side of.
#
#   Note also what --plan does NOT change: the read-only gate still classifies
#   `comment-edit --plan` an unconditional WRITE and refuses it under
#   $JIRA_READ_ONLY, alongside bulk/schedule/version --delete and unlike
#   `transition --plan`. See readonlygate.sh's --plan note for why that
#   asymmetry is deliberate rather than an oversight.
#
# There is deliberately NO --append-file counterpart. `update` has one because a
# DESCRIPTION is a living document that grows; a comment is a dated statement,
# and one that silently grew would misrepresent what was said when. A caller who
# wants to add to a discussion posts a new `comment`.
#
# There is likewise no --text string flag, for the identical reason `comment` has
# none: large/arbitrary content must never be interpolated into a caller's shell
# command.
#
# WHY ITS OWN UNIT rather than a second function inside cmd-comment.sh: one file
# per command is the engine's layout rule (see jira.sh's SHAPE note), and the
# closest precedent is link/link-types — two commands over one Jira concept, two
# units.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# comment-edit — GET then PUT /rest/api/3/issue/<KEY>/comment/<ID>
# ---------------------------------------------------------------------------

# COMMENT_EDIT_VERIFIED_KEY — comment_edit_require_existing's structural anchor
# (see there for what it protects), pre-seeded EMPTY so it can never be INHERITED
# FROM THE ENVIRONMENT. Left undeclared, an exported COMMENT_EDIT_VERIFIED_KEY
# satisfied the `${…:?}` at the upload call site without the mandatory GET having
# run, silently reopening the orphaned-attachment bug that guard exists to close.
# Seeding costs nothing because `:?` fires on NULL as well as unset, so the
# tripwire still trips. The two FILE globals that function also publishes are
# deliberately NOT seeded — for a path, empty is a silently wrong value, so a
# premature read must stay a loud `set -u` abort. Do not "fix" that asymmetry.
COMMENT_EDIT_VERIFIED_KEY=""

# extract_comment_body_text COMMENT_JSON_FILE -> prints the stored comment's ADF
# body as plain text, ONE LINE PER INNERMOST TEXT-BEARING NODE, empty lines
# dropped, and NOTHING AT ALL (zero bytes, not a blank line) when the body holds
# no text. That last property is what lets both callers below distinguish "no
# text to disclose" from "one empty line of text" with a plain `[ -s FILE ]` —
# `join("\n")` on an empty list would have printed a newline and made the two
# look identical. It is what makes the discarded text legible to a human at a
# consent gate; the raw ADF travels alongside it under --json for anything that
# needs it losslessly.
#
# THE GRANULARITY IS THE INNERMOST BLOCK, not the top-level one. Flattening every
# descendant text node under one top-level block ran NESTED blocks together into
# word soup: a bulletList read as "fix authfix db", a table's cells concatenated,
# and a hardBreak — which carries no text of its own — merged the very two lines
# it exists to separate. Since the human --plan render is the only disclosure a
# non---json caller sees before approving an irreversible overwrite, legibility
# there is part of the disclosure being trustworthy. So each node whose OWN
# .content array directly holds inline nodes emits its own line, and a hardBreak
# emits a break. Marks are ATTRIBUTES rather than nesting in ADF, so bold-plus-
# plain within one paragraph still joins into the single line it really is.
#
# Text nodes are joined in document order, so marks/links/mentions flatten to
# their own text — the question this answers is "what words am I about to
# destroy", not "how were they formatted". One consequence worth knowing: a
# mention carries no text, so a mention-only block reads as empty here and drops
# out; the raw .existingBody is where a caller sees the node itself.
#
# THE JQ PROGRAM IS TOTAL, and its EXIT STATUS IS CHECKED. Both guard the same
# failure, and neither is theoretical. require_json_body proves the response is
# valid JSON, never that it is ADF-SHAPED: `.body` can be a rendered STRING
# (`"str".content` is a hard jq error), and `.content` at ANY level can come back
# a string or a number instead of an array — so every step is type-guarded rather
# than trusting the shape. And jq's output lands in a FILE before
# strip_control_ansi touches it, because a pipeline's status is its LAST
# command's: `jq | strip_control_ansi` reported `tr`'s success even when jq had
# died, leaving an EMPTY file under `set -e`. --plan then rendered "(no
# renderable text …)" for a comment that DID have text — the consent gate
# disclosing the opposite of the truth, silently, exit 0. A real extraction
# failure now aborts the command instead of rendering as "empty".
#
# The result is piped through strip_control_ansi for the reason every API-sourced
# string in this engine is: it is UNTRUSTED text, and this copy is headed for an
# agent's context. The intermediate file lives in $WORKDIR, so ensure_workdir
# must already have run in the MAIN shell — cmd_comment_edit's first statement
# guarantees that for the one call path there is.
#
# UNICODE LINE TERMINATORS ARE NEUTRALISED IN JQ, deliberately not in `tr`. Every
# quoted body line renders behind a "  | " prefix precisely so attacker-authorable
# text can never reach column 0 (see render_comment_edit_plan_human), and the LF
# half of that guard is byte-level `tr -d`. But U+0085 (NEL), U+2028 (LINE
# SEPARATOR) and U+2029 (PARAGRAPH SEPARATOR) are MULTIBYTE in UTF-8, so under
# this engine's LC_ALL=C they pass through both strip_control_ansi and `tr -d`
# untouched — and a renderer that honours them starts a new visual line with no
# prefix on it, which is the forgery the prefix exists to prevent. They also
# cannot be removed byte-wise: deleting their bytes with `tr -d` would corrupt
# every unrelated multibyte character that shares one. So the substitution happens
# while the data is still CHARACTERS, inside jq, and each becomes a SPACE rather
# than vanishing — untrusted content is made inert and stays visible, never
# silently dropped. The same def guards .author/.created (see
# extract_comment_author_name) and the write receipt's own .id (see
# extract_edited_comment_id) — every field this command puts at column 0.
extract_comment_body_text() {
	ecbt_json_file=$1
	ecbt_raw_file="$WORKDIR/comment-edit-existing-body.raw"
	if ! jq -r '
		def neutralize_line_separators:
			# U+0085 NEL, U+2028 LINE SEP, U+2029 PARAGRAPH SEP -> U+0020 SPACE
			explode | map(if . == 133 or . == 8232 or . == 8233 then 32 else . end) | implode;
		def node_text:
			if .type == "text" then (if (.text | type) == "string" then (.text | neutralize_line_separators) else "" end)
			elif .type == "hardBreak" then "\n"
			else "" end;
		(.body | if type == "object" then .content else null end)
		| (if type == "array" then . else [] end)
		| [ .[] | objects
			| recurse(.content[]? | objects)
			| select((.content | type) == "array")
			| [ .content[] | objects | node_text ] | join("") ]
		| join("\n") | split("\n") | map(select(length > 0)) | .[]
	' "$ecbt_json_file" >"$ecbt_raw_file"; then
		error "read the stored body of comment $OPT_COMMENT_ID on $TICKET_KEY: unreadable comment body"
		exit 1
	fi
	strip_control_ansi <"$ecbt_raw_file"
}

# comment_edit_require_existing URL — THE mandatory read-before-write GET, and
# the structural anchor that keeps it ahead of every upload. It publishes three
# globals: the fetched comment JSON ($COMMENT_EDIT_EXISTING_FILE — captured here
# because a later PUT overwrites $JIRA_HTTP_BODY_FILE), the flattened body text
# ($COMMENT_EDIT_BODY_TEXT_FILE), and $COMMENT_EDIT_VERIFIED_KEY.
#
# THAT THIRD GLOBAL IS THE ANCHOR, not a spare copy of $TICKET_KEY. The ordering
# it protects — GET strictly before resolve_inline_images, so a bad --comment-id
# fails while nothing has been uploaded (see this file's header) — used to rest
# on nothing but statement order plus a prose comment, which a refactor sharing
# code with cmd-comment.sh could silently undo with no code failing. So the
# upload call site consumes THIS function's output as the key it uploads against,
# via `${COMMENT_EDIT_VERIFIED_KEY:?…}`: the value only exists once the GET has
# succeeded, and reordering the two statements makes that expansion abort with a
# named diagnostic rather than quietly reopening the orphaned-attachment bug.
#
# THE TWO FILE GLOBALS ARE DELIBERATELY NOT PRE-DECLARED at the top of this unit,
# unlike agile-paging.sh's AGILE_COLLECTED or jql.sh's JQL_CLAUSES. runtime.sh's
# own reason for initialising a global is so cleanup() can ask "was this created"
# on any exit path, and cleanup() touches neither; initialising them to empty
# would instead turn a premature read of either PATH from a loud `set -u` abort
# into a silent empty string. Leave those two undeclared.
#
# THE ANCHOR IS THE EXCEPTION and IS pre-declared — see COMMENT_EDIT_VERIFIED_KEY
# at the top of this unit for why the same reasoning inverts for it: `:?` fires on
# null as well as unset, so seeding it keeps the tripwire intact while closing the
# one channel left open — an inherited value from the caller's environment.
comment_edit_require_existing() {
	cere_url=$1
	jira_curl GET "$cere_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch comment $OPT_COMMENT_ID on $TICKET_KEY"
	require_json_body "fetch comment $OPT_COMMENT_ID on $TICKET_KEY"
	COMMENT_EDIT_EXISTING_FILE=$JIRA_HTTP_BODY_FILE
	COMMENT_EDIT_BODY_TEXT_FILE="$WORKDIR/comment-edit-existing-body.txt"
	extract_comment_body_text "$COMMENT_EDIT_EXISTING_FILE" >"$COMMENT_EDIT_BODY_TEXT_FILE"
	COMMENT_EDIT_VERIFIED_KEY=$TICKET_KEY
}

# extract_comment_author_name COMMENT_JSON_FILE -> prints the stored comment's
# author display name (or `unknown`) on ONE line, ready for a column-0 render;
# extract_comment_created_date below is its twin for `.created`. Both hold
# extract_comment_body_text's two contracts, and neither is theoretical here
# either:
#   * THE JQ PROGRAM IS TOTAL. `.author.displayName` is a HARD jq error whenever
#     `.author` came back a non-null NON-OBJECT — a rendered string, a number —
#     and require_json_body proves only that the response is valid JSON, never
#     that it is shaped the way Jira documents. The type guard covers that;
#     `tostring` covers the mirror case, a displayName that is not a string,
#     without discarding what it did say.
#   * ITS EXIT STATUS IS CHECKED, via a file. A pipeline's status is its LAST
#     command's, so `jq | strip_control_ansi | tr` reported `tr`'s success even
#     when jq had died — and the resulting empty value rendered the consent gate's
#     own disclosure line as "written by:   on: ", blank, silently, exit 0, while
#     render_comment_edit_plan_json crashed jq outright on the identical input.
#     Neither disclosure is silent now, though the two answers differ by design:
#     this path aborts with a named diagnostic, and the --json path renders the
#     field null (see render_comment_edit_plan_json for why).
# `.created` gets the same treatment despite being a plain scalar: a per-field
# judgement about which extraction "can" fail is exactly the kind of reasoning
# that decays, and uniformity costs one function.
extract_comment_author_name() {
	ecan_json_file=$1
	ecan_raw_file="$WORKDIR/comment-edit-existing-author.raw"
	if ! jq -r '
		def neutralize_line_separators:
			# U+0085 NEL, U+2028 LINE SEP, U+2029 PARAGRAPH SEP -> U+0020 SPACE
			explode | map(if . == 133 or . == 8232 or . == 8233 then 32 else . end) | implode;
		(.author | if type == "object" then (.displayName // null) else null end) // "unknown"
		| tostring | neutralize_line_separators
	' "$ecan_json_file" >"$ecan_raw_file"; then
		error "read the author of comment $OPT_COMMENT_ID on $TICKET_KEY: unreadable comment metadata"
		exit 1
	fi
	strip_control_ansi <"$ecan_raw_file" | tr -d '\012'
}

extract_comment_created_date() {
	eccd_json_file=$1
	eccd_raw_file="$WORKDIR/comment-edit-existing-created.raw"
	if ! jq -r '
		def neutralize_line_separators:
			# U+0085 NEL, U+2028 LINE SEP, U+2029 PARAGRAPH SEP -> U+0020 SPACE
			explode | map(if . == 133 or . == 8232 or . == 8233 then 32 else . end) | implode;
		(.created // "unknown") | tostring | neutralize_line_separators
	' "$eccd_json_file" >"$eccd_raw_file"; then
		error "read the creation date of comment $OPT_COMMENT_ID on $TICKET_KEY: unreadable comment metadata"
		exit 1
	fi
	strip_control_ansi <"$eccd_raw_file" | tr -d '\012'
}

# render_comment_edit_plan_human KEY COMMENT_ID COMMENT_JSON_FILE BODY_TEXT_FILE
# REPLACEMENT_FILE — the --plan human render: WHICH comment would be replaced,
# WHO wrote it and WHEN (the cheapest signal that a valid-but-wrong id was
# passed), and the body text that would be lost.
#
# Every quoted body line is emitted with a "  | " PREFIX. That is not decoration:
# the body is attacker-authorable text landing in the same stream as this
# command's own machine-readable lines, so a comment whose text reads
# "NOTHING WAS WRITTEN (dry-run / --plan)." must not be able to forge one. The
# prefix keeps every byte of quoted content off column 0, where all of this
# command's own lines start.
#
# THE AUTHOR AND DATE PRINT UNPREFIXED, AT COLUMN 0, so they need the same
# protection by a different mechanism. `.author.displayName` is authored by
# whoever holds the Jira account, exactly as attacker-influenced as the body, and
# strip_control_ansi deliberately does NOT delete `\012` (LF) — it keeps newlines
# so multi-line values elsewhere in the engine survive. A display name carrying
# an embedded newline would therefore have put attacker text at column 0 in this
# same stream, forging e.g. a `JIRA_COMMENT_EDITED=…` line and making a plan look
# like a completed write — precisely the class of forgery the body's prefix
# exists to prevent. Both fields are stripped of LF (CR is already gone with the
# other control bytes). `tr -d`, not a translation to a space: jq -r's own
# trailing newline would otherwise become a trailing space and change the normal,
# non-adversarial rendering of every plan. The cost is that a name genuinely
# spanning two lines reads joined — acceptable for a degenerate value whose
# legibility is not what the disclosure turns on. The multibyte line terminators
# `tr` cannot see are handled a step earlier, inside jq — see
# extract_comment_author_name, which owns both fields' extraction along with the
# totality and exit-status guards a blank disclosure line used to hide behind.
render_comment_edit_plan_human() {
	ceph_key=$1
	ceph_comment_id=$2
	ceph_json_file=$3
	ceph_body_text_file=$4
	ceph_replacement_file=$5

	ceph_author=$(extract_comment_author_name "$ceph_json_file")
	ceph_created=$(extract_comment_created_date "$ceph_json_file")

	# The machine line is DISTINCT from the real edit's JIRA_COMMENT_EDITED= (it
	# is not a prefix of it either way), so a caller grepping for the write can
	# never match a plan, and vice versa.
	printf 'JIRA_COMMENT_EDIT_PLANNED=%s (%s)\n' "$ceph_key" "$ceph_comment_id"
	printf 'PLAN for %s: REPLACE the ENTIRE body of comment %s\n' "$ceph_key" "$ceph_comment_id"
	printf 'That comment was written by: %s  on: %s\n' "$ceph_author" "$ceph_created"
	printf 'Replacement body would come from: %s\n' "$ceph_replacement_file"
	printf 'Existing body — WILL BE DISCARDED, no Jira undo; UNTRUSTED text quoted as data:\n'
	if [ -s "$ceph_body_text_file" ]; then
		while IFS= read -r ceph_body_line || [ -n "$ceph_body_line" ]; do
			printf '  | %s\n' "$ceph_body_line"
		done <"$ceph_body_text_file"
	else
		printf '  | (no renderable text — the stored body is empty or carries no text nodes)\n'
	fi
	printf 'NOTHING WAS WRITTEN (dry-run / --plan).\n'
}

# render_comment_edit_plan_json — the --json twin of the render above, same
# arguments. SYNTHESIZED, not passthrough: --plan never calls the write endpoint,
# so there is no Jira response to pass through (the real edit's --json is a
# passthrough for the mirror-image reason — see cmd_comment_edit below).
#
# .existingBody carries the stored ADF VERBATIM so the disclosure is lossless
# where the flattened .existingBodyLines is not; .executed is false, matching
# render_transition_summary_json's own plan/execute flag rather than inventing a
# second way to say the same thing.
#
# It needs NO counterpart to the human render's LF strip on .author/.created.
# Every value here leaves through jq's own JSON encoder — the `--arg`/`--rawfile`
# bindings arrive as opaque strings and the fetched fields are re-encoded on the
# way out — and that encoder escapes a newline as the two
# characters `\n` INSIDE the string literal. So an embedded newline cannot break
# out of its own value and start a line of its own: the structure a JSON consumer
# parses is unforgeable here for the same reason the human stream's was not.
#
# THE JQ PROGRAM IS TOTAL, for the same reason extract_comment_author_name's is:
# `.author.displayName` is a HARD jq error whenever `.author` came back a non-null
# NON-OBJECT, and a dying jq exits 5 — outside the 0/1/2 contract jira.sh's header
# documents — so a raw jq message replaced the engine's own diagnostic on the exact
# response shape the human render degrades to "unknown". Every field is
# optional-indexed and falls back to null, so a malformed shape reads as a MISSING
# value in the disclosure instead of crashing the preview. There is deliberately no
# `tostring` counterpart to the human render's: this path's job is fidelity (it
# ships the raw ADF under .existingBody, so a caller sees whatever came back), and
# coercing would have to special-case null anyway — `null | tostring` is the STRING
# "null", which would report a missing author as a present one.
render_comment_edit_plan_json() {
	cepj_key=$1
	cepj_comment_id=$2
	cepj_json_file=$3
	cepj_body_text_file=$4
	cepj_replacement_file=$5
	jq -n --arg key "$cepj_key" --arg commentId "$cepj_comment_id" \
		--arg replacementFile "$cepj_replacement_file" \
		--rawfile bodyText "$cepj_body_text_file" \
		--slurpfile existing "$cepj_json_file" \
		'{key: $key, commentId: $commentId,
		  author: (($existing[0].author? | objects | .displayName?) // null),
		  created: ($existing[0].created? // null),
		  existingBody: ($existing[0].body? // null),
		  existingBodyLines: ($bodyText | split("\n") | map(select(length > 0))),
		  replacementFile: $replacementFile,
		  executed: false}'
}

# extract_edited_comment_id PUT_RESPONSE_FILE -> prints the id the server says it
# edited, on ONE line, ready for the column-0 JIRA_COMMENT_EDITED= receipt. It
# neutralises the multibyte line terminators and strips LF exactly as
# extract_comment_author_name does, and for the identical reason: this is an
# UNTRUSTED response field printed at column 0, in the same stream as this
# command's own machine lines, so an embedded terminator could forge a second one.
#
# IT IS TOTAL, BUT ITS EXIT STATUS IS DELIBERATELY NOT CHECKED — the one place
# this file diverges from the three extractors above, because those run BEFORE the
# write and this one runs after. Totality is what removes the need: `.id?` yields
# nothing where the bare `.id` those three had to guard would raise a hard error
# on a non-object 200 body, so the `| strip_control_ansi | tr` pipeline (whose
# status is its LAST command's) has no jq failure left to swallow. Checking it
# would be strictly worse than pointless here: the PUT has already landed and
# cannot be undone, so aborting over an unreadable RECEIPT would report a
# completed, irreversible edit as a failure and invite a retry of it.
extract_edited_comment_id() {
	eeci_json_file=$1
	jq -r '
		def neutralize_line_separators:
			# U+0085 NEL, U+2028 LINE SEP, U+2029 PARAGRAPH SEP -> U+0020 SPACE
			explode | map(if . == 133 or . == 8232 or . == 8233 then 32 else . end) | implode;
		(.id? // "") | tostring | neutralize_line_separators
	' "$eeci_json_file" | strip_control_ansi | tr -d '\012'
}

cmd_comment_edit() {
	# TICKET_KEY/--comment-id/--text-file presence and shape are validated up
	# front — see the main dispatch section's per-command required-argument
	# validation.
	#
	# ensure_workdir MUST run here, in the MAIN shell, before
	# convert_markdown_file_to_adf() below — the same subshell/WORKDIR leak
	# cmd_comment documents in full (that conversion reaches jira_curl() from
	# inside its own `$(...)` command substitution, and a WORKDIR created there
	# dies with the substitution). Calling it here makes the inner call a no-op.
	ensure_workdir

	require_readable_file "$OPT_TEXT_FILE" "--text-file"

	# ONE url for both calls — the GET's 200 is what proves the PUT's target
	# exists, which only holds while they address the same resource.
	comment_edit_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}/comment/${OPT_COMMENT_ID}"

	# The mandatory read-before-write, FIRST — see this file's header for the two
	# gaps it closes. A bad/stale --comment-id fails here, with nothing uploaded
	# and nothing replaced.
	comment_edit_require_existing "$comment_edit_url"

	if [ "$OPT_PLAN" -eq 1 ]; then
		if [ "$OPT_JSON" -eq 1 ]; then
			render_comment_edit_plan_json "$TICKET_KEY" "$OPT_COMMENT_ID" \
				"$COMMENT_EDIT_EXISTING_FILE" "$COMMENT_EDIT_BODY_TEXT_FILE" "$OPT_TEXT_FILE"
		else
			render_comment_edit_plan_human "$TICKET_KEY" "$OPT_COMMENT_ID" \
				"$COMMENT_EDIT_EXISTING_FILE" "$COMMENT_EDIT_BODY_TEXT_FILE" "$OPT_TEXT_FILE"
		fi
		return 0
	fi

	# Inline-image pre-pass, identical to cmd_comment's: each own-line local
	# image is uploaded to THIS issue and mapped, then the conversion runs WITH
	# that map so the images become mediaSingle blocks. An upload to a
	# nonexistent KEY fails loud here (the attachments POST 404s), and a bad
	# --comment-id can no longer reach this point at all — the GET above already
	# rejected it, which is what keeps a failed edit from orphaning uploads.
	#
	# The key uploaded against is comment_edit_require_existing's OUTPUT, not
	# $TICKET_KEY, and `:?` is what makes the ordering structural: hoisting this
	# line above that call aborts here, named, instead of silently reopening the
	# orphaned-attachment bug. See that function for the full reasoning.
	comment_edit_media_map=$(resolve_inline_images \
		"${COMMENT_EDIT_VERIFIED_KEY:?comment-edit: the read-before-write GET must run before any attachment upload}" \
		"$OPT_TEXT_FILE")
	comment_edit_adf_file=$(convert_markdown_file_to_adf "$OPT_TEXT_FILE" "$comment_edit_media_map")

	comment_edit_request_file="$WORKDIR/comment-edit-request.json"
	jq -n --slurpfile body "$comment_edit_adf_file" '{body: $body[0]}' >"$comment_edit_request_file"

	jira_curl PUT "$comment_edit_url" "$comment_edit_request_file"
	handle_http_status "$JIRA_HTTP_CODE" "edit comment $OPT_COMMENT_ID on $TICKET_KEY"
	# Unlike `update`'s PUT /issue (204, no body), this PUT returns the UPDATED
	# comment object, so a JSON body is genuinely expected here.
	require_json_body "edit comment $OPT_COMMENT_ID on $TICKET_KEY"

	if [ "$OPT_JSON" -eq 1 ]; then
		# PASSTHROUGH, not synthesized — same reasoning as comment's --json
		# (see cmd_comment): Jira's response body IS the answer.
		cat "$JIRA_HTTP_BODY_FILE"
		return 0
	fi
	# The RESPONSE's id, not the one the caller passed: echoing back the id the
	# server says it edited makes this line evidence of the write rather than a
	# restatement of the request. A Jira-assigned comment id is numeric, so the
	# sanitising extract_edited_comment_id does is defence in depth rather than a
	# live hole — but a machine line whose forgeability depends on trusting the
	# server's field shape is not the property this command claims elsewhere.
	comment_edit_result_id=$(extract_edited_comment_id "$JIRA_HTTP_BODY_FILE")
	printf 'JIRA_COMMENT_EDITED=%s (%s)\n' "$TICKET_KEY" "$comment_edit_result_id"
}

# validate_comment_edit_args() — `comment-edit`'s per-command argument
# validation, called by jira.sh BEFORE any tool/site/credential check so a
# caller's own typo surfaces as a usage error (exit 2) first.
#
# --comment-id is shape-checked here, not merely tested for presence, because it
# becomes a REST URL PATH SEGMENT — the same rule every other id in this engine
# follows (validate_numeric_id's own note). Nothing downstream re-checks it.
validate_comment_edit_args() {
	require_ticket_positional comment-edit
	[ -n "$OPT_COMMENT_ID" ] || { usage >&2; error "comment-edit requires --comment-id"; exit 2; }
	validate_numeric_id "$OPT_COMMENT_ID" || { usage >&2; error "invalid --comment-id (must be a numeric comment id): $OPT_COMMENT_ID"; exit 2; }
	[ -n "$OPT_TEXT_FILE" ] || { usage >&2; error "comment-edit requires --text-file"; exit 2; }
	return 0
}
