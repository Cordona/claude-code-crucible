# review-aggregates.jq — flow-review's shared artifact definitions, in seven
# sections:
#   1. Verdict arithmetic — the ONE definition of which open findings count,
#      the open-by-severity tally, the summary built from it, and the overall
#      verdict derived from that summary.
#   2. Speculative list, keys and re-checks — the deduplicated view of every
#      round's speculative concerns, their keys, what a repeat carries, and
#      the re-check statuses.
#   3. Realism-field validation — the value domain of the optional
#      realism/trigger/realism_reason/relates_to/proof/unproven/speculative
#      fields a fields-file may carry, the category vocabulary and the
#      security floor, the evidence rules, the proof forms, and the proof
#      references a writer resolves (file:line locators, test numbers).
#   4. Rejection explainers — the fields-file diagnostics' message helpers,
#      and the security floor's write-time rule, which names entries with
#      them.
#   5. Diff scope — the diff-files list, the rule that every location a
#      fields-file cites names a file in it or is anchored by a relates_to on
#      a changed line, the cumulative diff_files, and the rule that a carried
#      finding is resolved only against a diff that covers it, with its
#      resolution_proof.
#   6. Handoffs — the shape of a concern passed between reviewer seats and
#      of its ruling, and the artifact handoffs after a write.
#   7. Needs your decision — the open items that return to the human, and
#      the tally of re-checked open items.
#
# A jq module included (`include "review-aggregates" {search: <this lib dir,
# absolute>};`) by review-create.sh, review-add-round.sh, review-update-status.sh and
# render-md.sh, so the three writers and the renderer can never disagree
# about what counts as blocking, and the writers never word a rejection
# differently. It includes security-terms.jq, which imports
# review-categories.json, each pinned to this module's own directory
# (`search: "./"`) because an unpinned lookup searches the process's working
# directory first, where a reviewed repository could plant a same-named
# module; nothing here touches a file, takes a $-argument, or
# has a side effect.
#
# WHY an out-of-domain severity is COUNTED AS CRITICAL rather than dropped:
# the tally is keyed by `.severity | ascii_downcase`, so a value outside
# CRITICAL/HIGH/MEDIUM/LOW would add a FIFTH key and produce a summary that
# finding-summary.schema.json rejects (its `open` object is closed) — it
# cannot be tallied verbatim. But silently EXCLUDING it would let a tampered
# or corrupt severity on an OPEN finding vanish from the count, so a recompute
# could still report APPROVED while that finding is genuinely open. Folding it
# into the highest bucket keeps the summary schema-valid and makes the failure
# mode fail-CLOSED: an unrecognized severity can only ever raise the verdict,
# never lower it. A missing/non-string severity lands here for the same reason.
#
# WHY the security floor fails closed: an item from lens-security-reviewer,
# or one whose category the vocabulary flags security, is set aside only with
# proof. A category outside the vocabulary is rejected at write time, so a
# misspelled or invented category can never take an item out from under the
# floor, and an item naming a security weakness (x-security-terms) under a
# category that is not a security one is rejected, so a misfiled security
# concern cannot either. An item stays under it once it has been there:
# every writer records security_floor: true on it, a later category change
# to a non-security one is refused, unproven is refused on it whatever its
# realism, and an update never changes the reviewer.

include "security-terms" {search: "./"};

# ---------------------------------------------------------------------------
# 1. Verdict arithmetic
# ---------------------------------------------------------------------------

def severity_bucket:
  if (type == "string") and (ascii_downcase | IN("critical", "high", "medium", "low"))
  then ascii_downcase
  else "critical"
  end;

# WHY a finding leaves the open tally ONLY on an explicitly CLOSED status
# (RESOLVED or ACK), rather than entering it only on NEW/OPEN/REGRESSED: the
# same fail-CLOSED principle as severity_bucket above. Selecting by the open
# statuses would let a tampered or corrupt status on an OPEN finding (an array,
# null, a misspelling, a missing key) drop it out of every bucket, so a
# recompute could report APPROVED while that finding is genuinely open.
# Selecting by the closed statuses means an unrecognized status can only ever
# raise the verdict, never lower it. The resolved/new/ack counts in summary
# stay exact-match: none of them gates the verdict.
def is_open_finding: .status | IN("RESOLVED", "ACK") | not;

# The same fail-CLOSED rule for realism: only the explicit value "edge-case"
# makes a finding an edge case. An absent realism and any unrecognized value
# count as realistic, so a corrupt realism can only ever raise the verdict.
def is_edge_case_finding: .realism == "edge-case";

# A human confirmation (review-update-status.sh --confirm-edge-case) covers
# the severity it was given at, recorded in realism_confirmed_severity.
def is_confirmed_at_current_severity:
  .realism_confirmed == true and .realism_confirmed_severity == .severity;

# An edge-case CRITICAL/HIGH keeps blocking until the human confirms it at its
# current severity. Fail-CLOSED on every input: an out-of-domain severity
# buckets as critical, and only a literal `true` recorded at the current
# severity confirms.
def awaits_edge_case_decision:
  is_edge_case_finding
  and (.severity | severity_bucket | IN("critical", "high"))
  and (is_confirmed_at_current_severity | not);

# Whether an open finding counts toward the open tally and the verdict: every
# realistic one, plus an edge case still awaiting the human's decision.
def counts_toward_verdict:
  is_open_finding and ((is_edge_case_finding | not) or awaits_edge_case_decision);

# The open-by-severity tally the verdict reads.
def open_counts(findings):
  reduce (findings[] | select(counts_toward_verdict)) as $f
    ({critical: 0, high: 0, medium: 0, low: 0}; .[$f.severity | severity_bucket] += 1);

# Open edge cases left out of the verdict, and those still awaiting a
# decision. Reported beside the verdict, never stored: finding-summary's
# shape is closed.
def edge_case_open_count(findings):
  [findings[] | select(is_open_finding and is_edge_case_finding and (counts_toward_verdict | not))] | length;
def edge_case_awaiting_count(findings):
  [findings[] | select(is_open_finding and awaits_edge_case_decision)] | length;

# A confirmation survives only on an edge case still at the severity it was
# given at: reclassifying away from edge-case, or any severity change, drops it.
def drop_stale_confirmation:
  if is_edge_case_finding and ((has("realism_confirmed") | not) or is_confirmed_at_current_severity)
  then .
  else del(.realism_confirmed, .realism_confirmed_severity) end;

def summary(findings):
  { open: open_counts(findings),
    resolved: ([findings[] | select(.status == "RESOLVED")] | length),
    new: ([findings[] | select(.status == "NEW")] | length),
    ack: ([findings[] | select(.status == "ACK")] | length)
  };

def verdict($s):
  if ($s.open.critical > 0 or $s.open.high > 0) then "CHANGES_REQUIRED"
  elif ($s.open.medium > 0 or $s.open.low > 0) then "APPROVED_WITH_FOLLOWUPS"
  else "APPROVED" end;

# ---------------------------------------------------------------------------
# 2. Speculative list, keys and re-checks
# ---------------------------------------------------------------------------

# A re-check (review-update-status.sh --recheck) records whether a set-aside
# item was looked at again: pending, survived or cleared with the proof of
# the outcome, or escalated to the human with the reason the re-check could
# not settle it (the verifier's or the adversary's unresolved disagreement).
# An outcome is recorded once per item, except that the human closes an
# escalated speculative entry by dismissing it, with their reason (dismissed).
def recheck_statuses: ["pending", "survived", "cleared", "escalated", "dismissed"];
def terminal_recheck_statuses: ["survived", "cleared", "escalated", "dismissed"];
def has_terminal_recheck: (.recheck | type == "object") and (.recheck.status | IN(terminal_recheck_statuses[]));
def has_recheck_status($status): (.recheck | type == "object") and .recheck.status == $status;

# The keys only the human sets on a speculative entry, through
# review-update-status.sh: its re-check, and the finding it was promoted to.
def speculative_human_keys: ["recheck", "promoted_to"];

# A speculative entry's key: the first 12 hex digits of the SHA-256 of its
# key input, computed by the writer (jq has no hash) and stored as key. It
# names the entry in render-md.sh's item map (speculative:<key>) and in
# review-update-status.sh --speculative-key, whichever round repeats it.
def speculative_key_input: "\(.reviewer)|\(.location)|\(.concern)";
def is_speculative_key: type == "string" and test("\\A[0-9a-f]{12}\\z");

# The input of every speculative entry stored without a key, one per line,
# for the writer to hash.
def unkeyed_speculative_key_inputs:
  [.rounds[]? | .speculative // [] | .[] | objects | select(has("key") | not) | speculative_key_input]
  | unique[];

# The input of every entry of a fields-file's speculative list.
def fields_file_speculative_key_inputs:
  [.speculative // [] | .[] | objects | speculative_key_input] | unique[];

# The artifact with every speculative entry stored without a key given the
# one $keys (key input -> key) holds for it.
def keyed_speculative_rounds($keys):
  .rounds |= map(
    if has("speculative") then
      .speculative |= map(
        if has("key") then .
        else ($keys[speculative_key_input]) as $key | if $key == null then . else {key: $key} + . end end)
    else . end);

def speculative_identity: .key // ([.reviewer, .location, .concern] | tojson);

# What a repeat of an entry in a later round keeps from the copy before it:
# nothing when its evidence (proof, unproven) or category changed — it is a
# new claim and starts fresh; else a pending re-check, and the finding it was
# promoted to while that finding is open. A recorded outcome is never
# carried, so the repeat is looked at again.
def speculative_evidence_view: {proof, unproven, category};
def carry_human_record($earlier; $findings):
  if $earlier == null or (.entry | speculative_evidence_view) != ($earlier.entry | speculative_evidence_view) then .
  else
    (if (.entry | has("recheck") | not) and ($earlier.entry | has_recheck_status("pending"))
     then .entry.recheck = $earlier.entry.recheck else . end)
    | (if (.entry | has("promoted_to") | not) and ($earlier.entry | has("promoted_to"))
          and any($findings[]; .id == $earlier.entry.promoted_to and is_open_finding)
       then .entry.promoted_to = $earlier.entry.promoted_to else . end)
  end;

# Every round's speculative entries, one per key: a repeat in a later round
# replaces the earlier copy, carrying what carry_human_record allows. Ordered
# by the round that last recorded it, then by reviewer. Each ref also names
# where its entry is stored, rounds[position].speculative[index]: the copy
# review-update-status.sh --speculative-key writes to.
def speculative_entry_refs:
  (.findings // []) as $findings
  | [ .rounds | to_entries[] | .key as $position
      | (.value.speculative // []) | to_entries[]
      | {position: $position, index: .key, entry: .value} ]
  | reduce .[] as $item ({};
      ($item.entry | speculative_identity) as $identity
      | .[$identity] as $earlier
      | .[$identity] = ($item | carry_human_record($earlier; $findings)))
  | [.[]] | sort_by(.position, .entry.reviewer);

def speculative_entries: speculative_entry_refs | map(.entry);

# A speculative entry promoted to a finding (review-update-status.sh
# --promote-to-id) is carried by that finding: it is no longer listed,
# counted or re-checked as speculative.
def is_promoted_speculative: has("promoted_to");
def unpromoted_speculative_entries: speculative_entries | map(select(is_promoted_speculative | not));

# Two entries with different key inputs but one key would be one item to the
# scripts, so a writer refuses the write. Run on the artifact as staged.
def speculative_key_collision_problems:
  [.rounds[] | .speculative // [] | .[]] | group_by(.key)[]
  | select((map([.reviewer, .location, .concern]) | unique | length) > 1)
  | "two speculative entries with a different reviewer, location or concern share key \(.[0].key): reword one concern";

# ---------------------------------------------------------------------------
# 3. Realism-field validation (review-create.sh, review-add-round.sh,
#    review-update-status.sh)
#
# Problem lines name the field and the rule but never echo the caller's
# value, so no caller-supplied text reaches stderr from here.
# ---------------------------------------------------------------------------

def realism_values: ["realistic", "edge-case"];

# Requires a STRING before testing membership: `index($v)` treats an ARRAY $v
# as a subsequence to search for, so ["edge-case"] would otherwise pass.
def is_realism: type == "string" and (. as $v | realism_values | index($v) != null);

# Non-empty, with no C0/C1 control character or DEL, so never a line break.
def is_one_line_text: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);

def one_line_rule: "must be a non-empty single-line string with no control characters";

# A finding's locations: each one line, so a location can never carry a
# second path past the diff-scope check (section 5).
def is_one_line_text_array: type == "array" and length > 0 and all(.[]; is_one_line_text);

# Characters that display differently than they read: C0/C1 controls and DEL,
# the soft hyphen, bidi marks, overrides and isolates, zero-width and other
# invisible format characters, line/paragraph separators, variation
# selectors, the BOM, interlinear annotation marks and tag characters. The
# same set flow-testing's test-plan-validate.jq forbids in plan text.
def forbidden_characters:
  "[\\x{0}-\\x{1F}\\x{7F}-\\x{9F}\\x{AD}\\x{61C}\\x{180E}\\x{200B}-\\x{200F}\\x{2028}-\\x{202E}\\x{2060}-\\x{2064}\\x{2066}-\\x{206F}\\x{FE00}-\\x{FE0F}\\x{FEFF}\\x{FFF9}-\\x{FFFB}\\x{E0000}-\\x{E007F}\\x{E0100}-\\x{E01EF}]";

# The one-line explanations a human reads beside a finding or speculative
# entry (realism_reason, real_if, a proof) are also capped, so each rendered
# sub-line stays scannable, and carry none of forbidden_characters. jq length
# counts code points, as JSON Schema maxLength does.
def short_text_max: 100;
def is_short_one_line_text:
  is_one_line_text and length <= short_text_max and (test(forbidden_characters) | not);
def short_one_line_rule:
  "\(one_line_rule) or invisible format characters, at most \(short_text_max) characters";

# A reason in plain words — why a re-check escalated an item, the human's
# reason for a waiver or a dismissal — is free text, not a proof form, and
# gets more room than a proof.
def reason_text_max: 200;
def is_reason_text:
  is_one_line_text and length <= reason_text_max and (test(forbidden_characters) | not);
def reason_text_rule:
  "\(one_line_rule) or invisible format characters, at most \(reason_text_max) characters";

# relates_to: ONE location (file:LINE[-END]) inside one changed hunk, in the
# code that relies on or exposes a defect located outside the diff (section
# 5).
# Capped like a path, not like prose.
def relates_to_max: 300;
def is_relates_to:
  is_one_line_text and length <= relates_to_max and (test(forbidden_characters) | not);
def relates_to_rule:
  "\(one_line_rule) or invisible format characters, at most \(relates_to_max) characters (one file:LINE[-END] location)";

# The category vocabulary (lib/review-categories.json, a copy of
# contracts/review-category.schema.json): the union of every reviewer's
# vocabulary, each category flagged security or not, and each reviewer's own
# list (x-reviewers). A reviewer x-reviewers names gives a category from its
# own list; any other reviewer is checked against the union.
def review_categories: review_category_data["x-categories"];
def is_review_category: type == "string" and (. as $category | review_categories | has($category));
def review_category_rule: "must be a category in a reviewer vocabulary (contracts/review-category.schema.json)";
def reviewer_vocabularies: review_category_data["x-reviewers"];
def has_own_vocabulary: type == "string" and (. as $reviewer | reviewer_vocabularies | has($reviewer));
def is_reviewer_category($reviewer):
  is_review_category
  and (($reviewer | has_own_vocabulary | not)
       or (. as $category | reviewer_vocabularies[$reviewer] | index($category) != null));
# Names the reviewer only when it is one of the contract's own (never caller
# text).
def reviewer_category_rule($reviewer):
  if $reviewer | has_own_vocabulary
  then "must be a category in \($reviewer)'s own vocabulary (x-reviewers in contracts/review-category.schema.json)"
  else "\(review_category_rule); the reviewer has no vocabulary of its own in x-reviewers, so the union of every vocabulary applies" end;

# The security floor (see the header WHY). security_floor is the writers'
# record that the item has been under it.
def security_reviewer: "lens-security-reviewer";
def is_security_category: type == "string" and (. as $category | review_categories[$category].security == true);
def is_security_concern:
  .security_floor == true or .reviewer == security_reviewer or (.category | is_security_category);
def stamp_security_floor: if is_security_concern then .security_floor = true else . end;
def stamp_artifact_security_floor:
  .findings |= map(if type == "object" then stamp_security_floor else . end)
  | .rounds |= map(if (.speculative | type) == "array"
                   then .speculative |= map(if type == "object" then stamp_security_floor else . end)
                   else . end);
def floored_category_rule:
  "the item is under the security floor (security_floor), so its category stays a security category (contracts/review-category.schema.json)";
def floored_unproven_rule:
  "the item is under the security floor (security_floor): unproven is never accepted on it; give proof";

# A security concern filed under a category that is not a security one would
# escape the floor, so a finding whose problem or trigger, or a speculative
# entry whose concern, names a weakness (named_security_term,
# lib/security-terms.jq) is refused there. lens-test-quality-reviewer judges
# whether security behavior is tested, so its item naming a security subject
# (named_security_subject) belongs in untested-security.
def test_quality_reviewer: "lens-test-quality-reviewer";
def test_quality_security_category: "untested-security";

def reviewer_security_categories($reviewer):
  if $reviewer | has_own_vocabulary then [reviewer_vocabularies[$reviewer][] | select(is_security_category)]
  else null end;
def security_handoff_rule: "hand it to \(security_reviewer) as a handoff";
def refile_security_rule($reviewer):
  reviewer_security_categories($reviewer) as $own
  | if $own == null then "re-file it under a security category (flagged security in x-categories of contracts/review-category.schema.json), or, if none fits, \(security_handoff_rule)"
    elif $own == [] then "\($reviewer) has no security category of its own: pass it to \(security_reviewer) as a handoff"
    else "re-file it under one of \($reviewer)'s own security categories (\($own | join(", "))), or, if none fits, \(security_handoff_rule)" end;

# One line for an item in a valid category that is not a security one whose
# $fields name a security weakness, or, from lens-test-quality-reviewer, a
# security subject; empty otherwise.
def misfiled_security_problem($fields):
  . as $item
  | select((.category | is_review_category) and (.category | is_security_category | not))
  | first(
      ($fields[] as $field | $item[$field] | strings | named_security_term | select(. != null)
       | "\($field) names a security weakness (\(.)) but category \($item.category) is not a security category: \(refile_security_rule($item.reviewer))"),
      (select($item.reviewer == test_quality_reviewer)
       | $fields[] as $field | $item[$field] | strings | named_security_subject | select(. != null)
       | "\($field) names a security subject (\(.)) but category \($item.category) is not a security category: file it as \(test_quality_security_category)"));

# realism_confirmed is the human's decision, recheck the human's record of a
# re-check, and ack_reason the human's reason for a waiver, each set only
# through the script; a fields-file (built from reviewer reports) may never
# carry any of them.
def human_only_confirmation_keys: ["realism_confirmed", "realism_confirmed_severity", "recheck", "ack_reason", "security_floor"];
def human_only_confirmation_rule:
  if . == "recheck" then "recheck is set only by the human, via review-update-status.sh --recheck"
  elif . == "ack_reason" then "ack_reason is set only by the human, via review-update-status.sh --status ACK --reason"
  elif . == "security_floor" then "security_floor is recorded by the writer, never given"
  else "\(.) is set only by the human, via review-update-status.sh --confirm-edge-case" end;

# Every proof names checkable evidence, in a form that depends on who writes
# it:
#   locator  a file:line (or file:start-end) whose file is path-like: it holds
#            a letter and has an extension, a "/", or is one of
#            extensionless_file_names, and it is no part of a URL. 10:30 or
#            1:1000 is not one. The writer resolves the file under
#            --repo-root and the line against its length.
#   ran      text starting "ran ": a command that was run and what it showed.
#            Recorded only by the orchestrator, through review-update-status.sh
#            --proof or --resolution-proof; a reviewer has no shell, and a
#            re-check or a handoff ruling carries the reviewer's or the
#            review-arbiter's evidence.
#   test     a test number of the plan a test-plan review covers (test 3,
#            Covered by test 3), resolved against the writer's --plan.
# A proof stored earlier is carried as written (carried_proof_forms), so an
# update that leaves it alone is not re-judged. The locator rule is the same
# in test-plan-validate.jq (each flow loads only the libs under its own
# scripts/ directory, so the two copies change together).
def reviewer_proof_forms($plan_review): ["locator"] + (if $plan_review then ["test"] else [] end);
def orchestrator_proof_forms($plan_review): reviewer_proof_forms($plan_review) + ["ran"];
def carried_proof_forms: ["locator", "ran", "test"];

def extensionless_file_names: ["Makefile", "Dockerfile", "Justfile", "Rakefile", "Gemfile", "Procfile"];
def is_path_like_file:
  test("[A-Za-z]")
  and (contains("/")
       or test("\\.[A-Za-z0-9_-]*[A-Za-z][A-Za-z0-9_-]*\\z")
       or IN(extensionless_file_names[]));

# A locator starts a word (or follows "(", "[" or a backtick), so the tail of
# a URL (https://host/a.rs:3) never reads as one.
def file_line_locator_pattern:
  "(?<![^\\s(\\[`])(?<file>[^\\s:`()\\[\\]]+):(?<start>[0-9]+)(?:-(?<end>[0-9]+))?(?![0-9])";

# The file:line locators of a proof, each {file, start, end} with the line
# numbers as written (digit strings, so a huge one is never rounded).
def proof_locators:
  [capture(file_line_locator_pattern; "g") | select(.file | is_path_like_file)
   | {file, start, end: (.end // .start)}];
def has_file_line_locator: proof_locators != [];

def proof_test_numbers: [scan("(?<![A-Za-z])[Tt]est ([0-9]+)(?![0-9])") | .[0]];

def proof_form_matches($form):
  if $form == "locator" then has_file_line_locator
  elif $form == "ran" then startswith("ran ")
  else proof_test_numbers != [] end;

def is_proof_format($forms):
  type == "string" and (. as $proof | any($forms[]; . as $form | $proof | proof_form_matches($form)));

def proof_form_text:
  {locator: "a file:line locator (src/a.rs:42, src/a.rs:42-50, Makefile:3; the file has an extension or a \"/\", or is \(extensionless_file_names | join(", ")); never a URL or a bare number like 10:30)",
   ran: "\"ran \" then the command and its result",
   test: "a test number of the plan under review (test 3, Covered by test 3)"}[.];
def proof_format_rule($forms):
  "must name its evidence in an accepted form: \($forms | map(proof_form_text) | join(", or "))"
  + (if any($forms[]; . == "ran") then "" else " (a \"ran ...\" proof is recorded only through review-update-status.sh --proof or --resolution-proof)" end);

# A proof field: one short line, in one of $forms.
def proof_problems($field; $forms):
  if is_short_one_line_text | not then "\($field) \(short_one_line_rule)"
  elif is_proof_format($forms) | not then "\($field) \(proof_format_rule($forms))"
  else empty end;

# The proofs a fields-file records, as {path, proof}: each finding's proof and
# resolution_proof, each speculative entry's proof, each handoff's proof.
# A list that is not an array yields nothing, so a writer reporting every
# rejection class reads a malformed fields-file without failing.
def list_entries: if type == "array" then to_entries[] else empty end;

def fields_file_proofs:
  ((.findings // []) | list_entries | .key as $index | .value | objects
   | (select(has("proof")) | {path: "findings[\($index)].proof", proof}),
     (select(has("resolution_proof")) | {path: "findings[\($index)].resolution_proof", proof: .resolution_proof})),
  ((.speculative // []) | list_entries | .key as $index | .value | objects
   | select(has("proof")) | {path: "speculative[\($index)].proof", proof}),
  ((.handoffs // []) | list_entries | .key as $index | .value | objects
   | select(has("proof")) | {path: "handoffs[\($index)].proof", proof});

# Input: an array of {path, proof}. One "<path><TAB><file><TAB><start><TAB><end>"
# line per file:line locator, which the writer resolves under --repo-root.
def proof_locator_lines:
  .[] | .path as $path | .proof | strings | proof_locators[]
  | "\($path)\t\(.file)\t\(.start)\t\(.end)";

# Input: an array of {path, proof}; $test_count: the number of tests in the
# plan a test-plan review covers, or null without --plan. One line per test
# number a proof names that the plan does not hold.
def proof_test_problems($test_count):
  .[] | .path as $path | .proof | strings | proof_test_numbers[] | tonumber
  | select($test_count == null or . < 1 or . > $test_count)
  | if $test_count == null then "\($path) names test \(.): pass --plan (the test plan this review covers) to resolve it"
    else "\($path) names test \(.), which the plan does not hold (its tests are numbered 1-\($test_count))" end;

# proof / unproven: the evidence behind setting an item aside. proof is one
# line naming it, in one of $forms; unproven, when given, is the literal true.
# Never both.
def evidence_shape_problems($forms):
  (select(has("proof")) | .proof | proof_problems("proof"; $forms)),
  (select(has("unproven") and .unproven != true)
   | "unproven must be true when given (omit it otherwise)"),
  (select(has("proof") and has("unproven"))
   | "proof and unproven are mutually exclusive: give exactly one");

# What an item set aside (an edge-case finding, a speculative entry) must
# carry: exactly one of proof or unproven, and proof alone under the security
# floor ($security). Run on an entry whose evidence shape is already valid.
def evidence_rule_problems($security):
  if $security then
    select(has("proof") | not)
    | "a security concern stays realistic until proven harmless: proof is required (unproven is not accepted) for an item from \(security_reviewer) or in a security category (contracts/review-category.schema.json)"
  else
    select((has("proof") or has("unproven")) | not)
    | "needs exactly one of proof (one line of at most \(short_text_max) characters naming a file:line) or unproven: true"
  end;

# A finding's evidence is re-supplied whole: an update that gives any of
# evidence_keys replaces all of them, so one it omits is removed rather than
# kept from the stored copy (a finding re-filed as realistic keeps no stale
# unproven, and proof and unproven never coexist). An update that gives none
# leaves the stored evidence as it is. relates_to is not evidence but scope:
# it anchors the stored locations outside the diff, so an update replaces it
# only by giving one and otherwise keeps it.
def evidence_keys: ["realism", "trigger", "realism_reason", "proof", "unproven"];
def gives_evidence: any(keys_unsorted[]; IN(evidence_keys[]));
def drop_resupplied_evidence($update):
  if $update | gives_evidence then delpaths([evidence_keys[] | [.]]) else . end;

# A stored finding with an update applied, as a writer stores it (first_seen
# is frozen at creation).
def updated_finding($update): drop_resupplied_evidence($update) + ($update | del(.first_seen));

# The evidence problems of ONE finding as it will be stored: the shape of
# proof/unproven, its proof in one of $forms, and the evidence rule when it
# is an edge case, under the security floor when $security.
def finding_evidence_problems($forms; $security):
  evidence_shape_problems($forms),
  (select(is_edge_case_finding and ([evidence_shape_problems($forms)] == [])) | evidence_rule_problems($security));

# Problems with ONE finding entry's category and optional fields — realism,
# trigger, realism_reason, relates_to, proof, unproven — and the human-only
# keys; empty when they are absent or valid. An explicit null counts as given
# and is rejected.
def finding_optional_field_problems($forms):
  (select(has("category")) | . as $finding | .category
   | select(is_reviewer_category($finding.reviewer) | not)
   | "category \(reviewer_category_rule($finding.reviewer))"),
  (select(has("realism") and (.realism | is_realism | not))
   | "realism must be one of \(realism_values | join(" | "))"),
  (select(has("trigger") and (.trigger | is_one_line_text | not))
   | "trigger \(one_line_rule)"),
  (select(has("realism_reason") and (.realism_reason | is_short_one_line_text | not))
   | "realism_reason \(short_one_line_rule)"),
  (select(has("relates_to") and (.relates_to | is_relates_to | not))
   | "relates_to \(relates_to_rule)"),
  finding_evidence_problems($forms; is_security_concern),
  (keys_unsorted[] | select(IN(human_only_confirmation_keys[])) | human_only_confirmation_rule);

# category decides whether the security floor applies, so every entry a
# writer records carries one; a stored entry without one is read as it is.
def speculative_required_keys: ["reviewer", "location", "concern", "why_speculative", "category"];
def speculative_optional_keys: ["real_if", "relates_to", "proof", "unproven"];
def speculative_keys: speculative_required_keys + speculative_optional_keys;

def speculative_human_key_rule:
  if . == "recheck" or . == "security_floor" then human_only_confirmation_rule
  else "promoted_to is set only by the human, via review-update-status.sh --promote-to-id" end;

# Every speculative entry is set aside, so each carries proof or unproven;
# one in a security category, or from the security lens, carries proof.
def speculative_entry_problems($forms):
  if type != "object" then "is not a JSON object"
  else
    . as $entry
    | ((keys_unsorted - speculative_keys - speculative_human_keys - ["key", "security_floor"]) | length) as $unknown
    | (select($unknown > 0)
       | "has \($unknown) unknown field(s) (known fields: \(speculative_keys | join(", ")))"),
      (select(has("key")) | "key is computed by the writer from reviewer, location and concern; omit it"),
      (keys_unsorted[] | select(IN(speculative_human_keys[], "security_floor")) | speculative_human_key_rule),
      (speculative_required_keys[] as $key
       | if ($entry | has($key) | not) then "is missing required field \"\($key)\""
         elif ($entry[$key] | is_one_line_text | not) then "\($key) \(one_line_rule)"
         elif $key == "category" and ($entry.category | is_reviewer_category($entry.reviewer) | not)
         then "category \(reviewer_category_rule($entry.reviewer))"
         else empty end),
      (select(has("real_if") and (.real_if | is_short_one_line_text | not))
       | "real_if \(short_one_line_rule)"),
      (select(has("relates_to") and (.relates_to | is_relates_to | not))
       | "relates_to \(relates_to_rule)"),
      evidence_shape_problems($forms),
      (select([evidence_shape_problems($forms)] == []) | evidence_rule_problems(is_security_concern))
  end;

# Problems with a fields-file top-level `speculative`, one line each, prefixed
# with the entry position; empty when the key is absent or valid.
def speculative_problems($forms):
  if has("speculative") | not then empty
  elif (.speculative | type) != "array" then "speculative must be an array (may be [])"
  else .speculative | to_entries[] | .key as $index | .value
    | speculative_entry_problems($forms) | "speculative[\($index)] \(.)"
  end;

# The persisted speculative list for a rounds[] entry: rebuilt field by field
# so no stray key survives (an absent optional key stays absent, never null),
# each entry led by the key $keys (key input -> key) holds for it, and
# omitted entirely when the round recorded none.
def speculative_round_fields($fields; $keys):
  ($fields.speculative // []) as $entries
  | if ($entries | length) == 0 then {}
    else {speculative: ($entries | map(. as $entry
                                       | {key: $keys[$entry | speculative_key_input]}
                                       + (reduce speculative_required_keys[] as $key ({}; .[$key] = $entry[$key]))
                                       + (reduce speculative_optional_keys[] as $key ({};
                                            if $entry | has($key) then .[$key] = $entry[$key] else . end))))}
    end;

# ---------------------------------------------------------------------------
# 4. Rejection explainers
#
# Used ONLY after a validation predicate has already said no. They describe a
# rejection; they never make one.
#
# `shown` is the one way a caller-supplied value reaches a message: tojson
# quotes it and escapes C0 controls and DEL, and every other character of
# forbidden_characters (C1, including the 8-bit CSI terminal escape, bidi
# overrides, zero-width and tag characters) is escaped on top as \uXXXX
# because tojson leaves it raw. Long strings are cut so one value cannot flood
# stderr.
#
# is_nonempty_string is the scripts' value predicate, defined here rather than
# in each script because string_array_problems calls it and jq binds a name
# only to a def that precedes it: the scripts prepend this lib to their own
# value defs, so a script-side copy would come too late.
# ---------------------------------------------------------------------------

def is_nonempty_string: type == "string" and length > 0;

def hex4: . as $n | [3, 2, 1, 0] | map(($n / pow(16; .) | floor) % 16 | "0123456789abcdef"[.:. + 1]) | add;
# A code point as JSON writes it: \uXXXX, or a surrogate pair above U+FFFF.
def unicode_escape:
  if . < 65536 then "\\u" + hex4
  else (. - 65536) as $v
    | "\\u" + (55296 + ($v / 1024 | floor) | hex4) + "\\u" + (56320 + $v % 1024 | hex4) end;
def escape_invisible: gsub("(?<c>" + forbidden_characters + ")"; .c | explode[0] | unicode_escape);
def shown:
  if type == "string" then
    (if length > 80 then (.[:80] | tojson | escape_invisible) + " (truncated)" else tojson | escape_invisible end)
  elif type == "array" then (if length == 0 then "an empty array" else "a JSON array" end)
  elif type == "object" then "a JSON object"
  else tojson end;
def got: " (got \(shown))";
def presence_problem($object; $key):
  if ($object | has($key)) | not then "missing required field \"\($key)\""
  else "\($key) is null (an explicit null is rejected)" end;
def string_array_problems($key):
  if type != "array" or length == 0 then "\($key) must be a non-empty array of non-empty strings\(got)"
  else to_entries[] | select(.value | is_nonempty_string | not)
    | "\($key)[\(.key)] must be a non-empty string (got \(.value | shown))"
  end;

def one_line_array_problems($key):
  if type != "array" or length == 0 then "\($key) must be a non-empty array of one-line strings\(got)"
  else to_entries[] | select(.value | is_one_line_text | not)
    | "\($key)[\(.key)] \(one_line_rule) (got \(.value | shown))"
  end;

# One line per fields-file entry that would take an item out from under the
# security floor: a finding update, or a speculative repeat (same reviewer,
# location and concern) of an earlier round's entry, changing a floored
# item's category to a non-security one; and unproven on a finding that is
# or becomes floored. An edge case's unproven is left to its evidence rule.
# $stored_findings and $stored_speculative: the artifact's before the write.
def floored_item_problems($stored_findings; $stored_speculative):
  ((.findings // []) | list_entries
   | .key as $index | .value | objects | . as $entry
   | ([$stored_findings[] | objects | select(.id == $entry.id)] | first) as $stored
   | (if $stored == null then $entry else $stored | updated_finding($entry) end) as $merged
   | ($stored != null and ($stored | is_security_concern)) as $was_floored
   | (select($was_floored and has("category") and .category != $stored.category
             and (.category | is_security_category | not))
      | "findings[\($index)] id \($entry.id | shown) — category: \(floored_category_rule)"),
     (select(has("unproven") and ($merged | is_edge_case_finding | not)
             and ($was_floored or ($merged | is_security_concern)))
      | "findings[\($index)] id \($entry.id | shown) — \(floored_unproven_rule)")),
  ((.speculative // []) | list_entries
   | .key as $index | .value | objects | . as $entry
   | [$stored_speculative[] | objects | select(speculative_key_input == ($entry | speculative_key_input))] as $earlier
   | select(any($earlier[]; is_security_concern) and .category != ($earlier | last | .category)
            and (.category | is_security_category | not))
   | "speculative[\($index)] repeats an earlier round's entry (same reviewer, location and concern) — category: \(floored_category_rule)");

# One line per fields-file entry filing a security concern under a category
# that is not a security one (misfiled_security_problem): a NEW finding, an
# UPDATE that gives problem, trigger or category (judged as it will be
# stored, under the stored reviewer), and every speculative entry.
# $stored_findings: the artifact's before the write ([] when creating one).
def misfiled_security_problems($stored_findings):
  ((.findings // []) | list_entries
   | .key as $index | .value | objects | . as $entry
   | ([$stored_findings[] | objects | select(.id == $entry.id)] | first) as $stored
   | select($stored == null or any($entry | keys_unsorted[]; IN("problem", "trigger", "category")))
   | (if $stored == null then $entry
      else $stored | updated_finding($entry) | .reviewer = $stored.reviewer end)
   | misfiled_security_problem(["problem", "trigger"])
   | "findings[\($index)] id \($entry.id | shown) — \(.)"),
  ((.speculative // []) | list_entries
   | .key as $index | .value | objects
   | misfiled_security_problem(["concern"])
   | "speculative[\($index)] — \(.)");

# ACK is the human's waiver (review-update-status.sh --status ACK); a report
# repeats it only on a finding already stored ACK.
def report_ack_rule:
  "status ACK is the human waiver, set only through review-update-status.sh --status ACK; a report carries ACK only on a finding already ACK";

# ---------------------------------------------------------------------------
# 5. Diff scope (review-create.sh, review-add-round.sh,
#    review-update-status.sh)
#
# A review covers the diff, and a finding is scoped by its effect on it:
# every location a fields-file introduces — each NEW finding location, each
# location an UPDATE adds, each speculative location and each new handoff
# location — names a file in the list diff-scope.sh wrote, or is anchored by
# its own entry's relates_to: one location whose line or whole range lies
# inside one hunk the diff changed (diff-hunks.tsv), in the code that relies
# on or exposes the defect. An
# UPDATE that adds a location outside the diff gives its own relates_to;
# the stored one anchors only the locations stored with it. A location is a
# repo-relative path, optionally followed by :LINE or :START-END. An
# observation outside the diff that no changed code relies on or exposes
# belongs in the report notes as pre-existing. Findings carried from earlier
# rounds were checked when written and are not re-checked.
#
# The list is diff-files.txt (one path per line) or diff-files.tsv
# (path<TAB>blob-sha per line). The same parse lives in flow-testing's
# test-plan-validate.jq: each flow loads only the libs under its own
# scripts/ directory, so the two copies change together.
# ---------------------------------------------------------------------------

# A diff-files.tsv line: the path is everything before the last tab, the sha
# a 40- or 64-hex git object id, or "-" for a path with no blob (a deleted
# path or a non-file entry such as a submodule).
def diff_file_tsv_line: "\\A(?<path>.+)\\t(?<sha>[0-9a-f]{40}|[0-9a-f]{64}|-)\\z";

# The --diff-files content, read with `jq -R -s`, as a sorted array of unique
# entries: {path, sha} objects when every line is a diff-files.tsv line,
# else the plain path strings.
def diff_file_list:
  split("\n") | map(select(length > 0))
  | if length > 0 and all(.[]; test(diff_file_tsv_line))
    then map(capture(diff_file_tsv_line))
    else . end
  | unique;

# The path of one diff_file_list entry, whichever form it holds.
def diff_file_path: if type == "object" then .path else . end;
def diff_file_paths: map(diff_file_path);

# The set of $diff_files paths, as an object for constant-time lookup.
def diff_path_set($diff_files):
  reduce ($diff_files | diff_file_paths)[] as $path ({}; .[$path] = true);

# The artifact's diff_files after a round: the union by path of the stored
# list and this round's, this round's entry winning for a path in both
# (its sha is the newer one), sorted by path. An artifact without a stored
# list gains one.
def cumulative_diff_files($stored; $round):
  (($stored // []) + $round)
  | reduce .[] as $entry ({}; .[$entry | diff_file_path] = $entry)
  | to_entries | sort_by(.key) | map(.value);

# A location as {file, start, end}: start and end are null without a line.
# null when it is not a one-line string.
def location_parts:
  if type == "string" then
    [capture("\\A(?<file>.+?)(?::(?<start>[0-9]+)(?:-(?<end>[0-9]+))?)?\\z")][0]
    | if . == null then null else {file, start, end: (.end // .start)} end
  else null end;

def location_file: location_parts | if . == null then null else .file end;

# Fail-closed: a location whose file cannot be read off it counts as outside.
def is_outside_diff($in_diff):
  location_file as $file | $file == null or $in_diff[$file] != true;

# A test-plan review (review-create.sh --plan-review) also locates an item
# in the plan it reviews: plan:<item>, e.g. plan:test-3, plan:not_tested-1,
# plan:B2. Such a locator is in scope without naming a diff file.
def is_plan_locator: type == "string" and test("\\Aplan:[A-Za-z0-9_-]+\\z");
def is_outside_review_scope($in_diff; $plan_review):
  ($plan_review and is_plan_locator | not) and is_outside_diff($in_diff);

# The locations of a fields-file finding entry that the diff-scope check
# judges: all of them for an entry whose id is not among $stored_findings
# (NEW), and for an UPDATE only those not already among the stored finding's
# locations. A carried finding keeps the locations it was accepted with, so an
# UPDATE that repeats or omits them is not re-checked against a later diff.
def checked_locations($stored_findings):
  . as $entry
  | ([$stored_findings[] | select(type == "object" and .id == $entry.id) | .locations
      | if type == "array" then .[] else empty end]) as $stored_locations
  | (.locations // [] | if type == "array" then .[] else empty end)
  | . as $location
  | select(($stored_locations | index([$location])) == null);

# Whether $relates_to anchors a location outside the diff: given, and in it.
def anchors_outside_location($relates_to; $in_diff):
  $relates_to != null and ($relates_to | is_outside_diff($in_diff) | not);

def relates_to_outside_rule:
  "is not in the diff (relates_to names the changed code that relies on or exposes the defect)";
def unanchored_location_rule:
  "is not in the diff, and no in-diff relates_to on the same entry anchors it";

# One line per relates_to outside the diff and per out-of-diff location no
# in-diff relates_to of its own entry anchors, naming the finding id or the
# entry; empty when every checked location is in scope. $stored_findings:
# the artifact's findings before this write ([] when creating one);
# $plan_review: whether plan:<item> locators are in scope.
def out_of_diff_problems($diff_files; $stored_findings; $plan_review):
  diff_path_set($diff_files) as $in_diff
  | ((.findings // []) | to_entries[] | .key as $index | .value
     | select(type == "object") | . as $finding
     | (select(has("relates_to")) | .relates_to | select(is_outside_diff($in_diff))
        | "findings[\($index)] id \($finding.id | shown) — relates_to \(shown) \(relates_to_outside_rule)"),
       (checked_locations($stored_findings)
        | select(is_outside_review_scope($in_diff; $plan_review) and (anchors_outside_location($finding.relates_to; $in_diff) | not))
        | "findings[\($index)] id \($finding.id | shown) — location \(shown) \(unanchored_location_rule)")),
    ((.speculative // []) | if type == "array" then to_entries[] else empty end
     | .key as $index | .value
     | select(type == "object") | . as $entry
     | (select(has("relates_to")) | .relates_to | select(is_outside_diff($in_diff))
        | "speculative[\($index)] — relates_to \(shown) \(relates_to_outside_rule)"),
       (.location
        | select(is_outside_review_scope($in_diff; $plan_review) and (anchors_outside_location($entry.relates_to; $in_diff) | not))
        | "speculative[\($index)] — location \(shown) \(unanchored_location_rule)")),
    ((.handoffs // []) | if type == "array" then to_entries[] else empty end
     | .key as $index | .value
     | select(type == "object" and (has("index") | not)) | . as $handoff
     | (select(has("relates_to")) | .relates_to | select(is_outside_diff($in_diff))
        | "handoffs[\($index)] — relates_to \(shown) \(relates_to_outside_rule)"),
       (.location
        | select(is_outside_review_scope($in_diff; $plan_review) and (anchors_outside_location($handoff.relates_to; $in_diff) | not))
        | "handoffs[\($index)] — location \(shown) \(unanchored_location_rule)"));

# Whether a fields-file gives any relates_to (the writer then needs
# --diff-hunks).
def fields_file_has_relates_to:
  any((.findings, .speculative, .handoffs | arrays | .[]); type == "object" and has("relates_to"));

# diff-hunks.tsv (diff-scope.sh), read with `jq -R -s`: one
# "<path><TAB><start><TAB><end>" line per new-side hunk, "0 0" for a change
# with no lines to point at (a deleted or binary file). null when a line is
# not one.
def diff_hunk_tsv_line: "\\A(?<path>.+)\\t(?<start>[0-9]{1,9})\\t(?<end>[0-9]{1,9})\\z";
def diff_hunk_list:
  split("\n") | map(select(length > 0))
  | if all(.[]; test(diff_hunk_tsv_line))
    then map(capture(diff_hunk_tsv_line) | {path, start: (.start | tonumber), end: (.end | tonumber)})
    else null end;

def diff_hunk_index($hunks): reduce $hunks[] as $hunk ({}; .[$hunk.path] += [[$hunk.start, $hunk.end]]);

# Whether a relates_to points at changed lines: its line or whole range lies
# inside one hunk of its file, or the file changed as a whole ("0 0"). A
# range reaching past a hunk names unchanged code, and a relates_to without
# a line points at no line.
def line_range_within_hunk($start; $end; $file_hunks):
  ($start | length) <= 9 and ($end | length) <= 9
  and (($start | tonumber) as $first | ($end | tonumber) as $last
       | $first >= 1 and $first <= $last
         and any($file_hunks[]; .[0] <= $first and $last <= .[1]));
def is_on_changed_line($hunk_index):
  location_parts as $l
  | if $l == null then false
    else ($hunk_index[$l.file] // []) as $file_hunks
      | any($file_hunks[]; . == [0, 0])
        or ($l.start != null and line_range_within_hunk($l.start; $l.end; $file_hunks))
    end;

def off_hunk_rule:
  "is not inside one changed hunk (diff-hunks.tsv): point it at a line or range the diff changed, in the code that relies on or exposes the defect";

# One line per relates_to a fields-file gives that is not inside one changed
# hunk.
def off_hunk_relates_to_problems($hunks):
  diff_hunk_index($hunks) as $hunk_index
  | ((.findings // []) | list_entries | .key as $index | .value | objects
     | select(has("relates_to") and (.relates_to | is_on_changed_line($hunk_index) | not))
     | "findings[\($index)] id \(.id | shown) — relates_to \(.relates_to | shown) \(off_hunk_rule)"),
    ((.speculative // []) | list_entries | .key as $index | .value | objects
     | select(has("relates_to") and (.relates_to | is_on_changed_line($hunk_index) | not))
     | "speculative[\($index)] — relates_to \(.relates_to | shown) \(off_hunk_rule)"),
    ((.handoffs // []) | list_entries | .key as $index | .value | objects
     | select((has("index") | not) and has("relates_to") and (.relates_to | is_on_changed_line($hunk_index) | not))
     | "handoffs[\($index)] — relates_to \(.relates_to | shown) \(off_hunk_rule)");

# The files a finding names: those of its locations and of its relates_to.
def finding_files:
  [ (.locations // [] | if type == "array" then .[] else empty end), (.relates_to // empty) ]
  | map(location_file | select(. != null)) | unique;

# One line per UPDATE that moves a stored finding to RESOLVED although none of
# its STORED files (locations and relates_to as stored) is in the given
# diff: a resolution is verified only against a diff that covers the
# finding, and a location or relates_to the same update adds does not count.
# In a test-plan review a plan:<item> locator is always covered. A finding
# already RESOLVED, and any other status change, are not judged.
def unverified_resolution_problems($diff_files; $stored_findings; $plan_review):
  diff_path_set($diff_files) as $in_diff
  | (.findings // []) | to_entries[] | .key as $index | .value
  | select(type == "object" and .status == "RESOLVED") | . as $entry
  | ([$stored_findings[] | select(type == "object" and .id == $entry.id)] | first) as $stored
  | select($stored != null and $stored.status != "RESOLVED")
  | ($stored | {locations, relates_to} | finding_files) as $files
  | select(all($files[]; $in_diff[.] != true and ($plan_review and is_plan_locator | not)))
  | "findings[\($index)] id \($entry.id | shown) — cannot be set RESOLVED: none of its stored files (\($files | map(shown) | join(", "))) is in the diff (--diff-files); resolve it against a diff that covers it, and carry it as OPEN until then";

# One line per entry that sets status RESOLVED on a finding not stored as
# RESOLVED without a resolution_proof (the evidence the fix holds, in one of
# $forms), and per resolution_proof given without status RESOLVED.
def resolution_proof_problems($stored_findings; $forms):
  (.findings // []) | to_entries[] | .key as $index | .value
  | select(type == "object") | . as $entry
  | ([$stored_findings[] | select(type == "object" and .id == $entry.id)] | first) as $stored
  | (if .status == "RESOLVED" and ($stored == null or $stored.status != "RESOLVED") and (has("resolution_proof") | not)
     then "resolution_proof is required when an entry sets status RESOLVED (the evidence the fix holds)"
     elif has("resolution_proof") and .status != "RESOLVED"
     then "resolution_proof is given only with status RESOLVED"
     elif has("resolution_proof") then .resolution_proof | proof_problems("resolution_proof"; $forms)
     else empty end)
  | "findings[\($index)] id \($entry.id | shown) — \(.)";


# ---------------------------------------------------------------------------
# 6. Handoffs (review-create.sh, review-add-round.sh, review-update-status.sh,
#    render-md.sh)
#
# A handoff is a concern one reviewer passes to another seat. It stays open
# until ruled: filed (as the finding filed_as names), rejected, or
# out-of-scope, each ruling with its proof; or waived by the human, with the
# human's reason in their words. A ruling is recorded once, by a round
# (review-add-round.sh) or by the orchestrator (review-update-status.sh
# --handoff-index); a waiver only by the orchestrator. Both name a handoff by
# its 1-based place in handoffs, the <N> of render-md.sh's
# REVIEW_ITEM_<n>=handoff:<N>. Its re-check is the human's record, set only
# through review-update-status.sh.
# ---------------------------------------------------------------------------

def handoff_rulings: ["open", "filed", "rejected", "out-of-scope", "waived"];
def handoff_required_keys: ["from", "to", "concern", "location", "ruling"];
def handoff_optional_keys: ["relates_to", "proof", "filed_as", "reason"];
def handoff_keys: handoff_required_keys + handoff_optional_keys;
def handoff_human_keys: ["recheck"];
# The keys an add-round fields-file entry carries to rule a stored handoff.
def handoff_ruling_keys: ["index", "ruling", "proof", "filed_as"];

def is_open_handoff: .ruling == "open";
def is_handoff_ruling: type == "string" and IN(handoff_rulings[]);
def is_finding_id_text: type == "string" and test("\\A[A-Z]+-[0-9]{3,}\\z");

def waived_ruling_rule:
  "ruling waived is the human's, recorded only through review-update-status.sh --handoff-index N --ruling waived --reason TEXT";

# Problems with ONE handoff as it will be stored; $finding_ids: the finding
# ids the artifact holds after the write, which filed_as must name; $forms:
# the proof forms its writer may record.
def handoff_problems($finding_ids; $forms):
  if type != "object" then "is not a JSON object"
  else
    . as $handoff
    | ((keys_unsorted - handoff_keys - handoff_human_keys) | length) as $unknown
    | (select($unknown > 0)
       | "has \($unknown) unknown field(s) (known fields: \(handoff_keys | join(", ")))"),
      ((handoff_required_keys - ["ruling"])[] as $key
       | if ($handoff | has($key) | not) then "is missing required field \"\($key)\""
         elif ($handoff[$key] | is_one_line_text | not) then "\($key) \(one_line_rule)"
         else empty end),
      (select(has("relates_to") and (.relates_to | is_relates_to | not))
       | "relates_to \(relates_to_rule)"),
      (if has("ruling") | not then "is missing required field \"ruling\""
       elif .ruling | is_handoff_ruling | not then "ruling must be one of \(handoff_rulings | join(" | "))"
       elif is_open_handoff then
         (select(has("proof")) | "proof must be absent while ruling is open (an open handoff has no outcome yet)"),
         (select(has("filed_as")) | "filed_as must be absent while ruling is open"),
         (select(has("reason")) | "reason must be absent unless ruling is waived")
       elif .ruling == "waived" then
         (if has("reason") | not then "reason is required when ruling is waived (the human's reason, in their words)"
          elif .reason | is_reason_text | not then "reason \(reason_text_rule)"
          else empty end),
         (select(has("proof")) | "proof must be absent when ruling is waived (the waiver carries the human's reason instead)"),
         (select(has("filed_as")) | "filed_as is given only when ruling is filed")
       else
         (select(has("reason")) | "reason must be absent unless ruling is waived"),
         (if has("proof") then .proof | proof_problems("proof"; $forms)
          else "proof is required when ruling is \(.ruling)" end),
         (if .ruling == "filed" then
            if has("filed_as") | not then "filed_as is required when ruling is filed (the id of the finding it was filed as)"
            elif (.filed_as | is_finding_id_text | not) then "filed_as must be a finding id (uppercase letters, a hyphen, 3+ digits)"
            elif ($finding_ids | index([$handoff.filed_as])) == null then "filed_as names no finding in the artifact"
            else empty end
          elif has("filed_as") then "filed_as is given only when ruling is filed"
          else empty end)
       end)
  end;

# The persisted handoff: rebuilt field by field so no stray key survives; a
# stored re-check is carried.
def stored_handoff:
  . as $handoff
  | {from, to, concern, location}
    + (if has("relates_to") then {relates_to} else {} end)
    + {ruling}
    + (reduce (["proof", "filed_as", "reason"] + handoff_human_keys)[] as $key ({};
         if $handoff | has($key) then .[$key] = $handoff[$key] else . end));

# Problems with a fields-file top-level `handoffs`, one line each, prefixed
# with the entry position; empty when the key is absent or valid. Without
# $stored_handoffs every entry is a new handoff; with it (add-round), an
# entry carrying index rules the stored open handoff at that 1-based place. A
# fields-file is built from reviewer reports, so its proofs take $forms and
# it never carries a re-check.
def handoffs_problems($stored_handoffs; $finding_ids; $forms):
  if has("handoffs") | not then empty
  elif (.handoffs | type) != "array" then "handoffs must be an array (may be [])"
  else
    ([.handoffs[] | objects | select(has("index")) | .index]) as $ruled_indexes
    | .handoffs | to_entries[] | .key as $position | .value
    | (if type == "object" and has("index") then
         . as $ruling
         | ((keys_unsorted - handoff_ruling_keys) | length) as $unknown
         | if $stored_handoffs == null then "index is accepted only by review-add-round.sh (ruling a stored handoff)"
           elif (.index | type == "number" and floor == . and . >= 1) | not then "index must be an integer >= 1 (the handoff's 1-based place in handoffs, the <N> of REVIEW_ITEM_<n>=handoff:<N>)"
           elif .index > ($stored_handoffs | length) then "index names no stored handoff"
           elif ([$ruled_indexes[] | select(. == $ruling.index)] | length) > 1 then "index is ruled by more than one entry"
           elif $unknown > 0 then "has \($unknown) unknown field(s) (a ruling carries only \(handoff_ruling_keys | join(", ")))"
           elif ($stored_handoffs[.index - 1] | is_open_handoff | not) then "the handoff at this index is already ruled (a ruling is recorded once)"
           elif (has("ruling") | not) or .ruling == "open" then "a ruling entry needs ruling filed, rejected or out-of-scope"
           elif .ruling == "waived" then waived_ruling_rule
           else ($stored_handoffs[.index - 1] | del(.recheck)) + del(.index) | handoff_problems($finding_ids; $forms) end
       elif type == "object" and has("recheck") then "recheck is set only by the human, via review-update-status.sh --handoff-index N --recheck"
       elif type == "object" and .ruling == "waived" then waived_ruling_rule
       else handoff_problems($finding_ids; $forms) end)
    | "handoffs[\($position)] \(.)"
  end;

# The artifact handoffs after a write: the stored ones with each ruling
# applied, then the new ones. Absent (omitted) when there are none.
def merged_handoffs($stored_handoffs; $entries):
  ([$entries[] | select(has("index"))] | map({key: (.index - 1 | tostring), value: del(.index)}) | from_entries) as $rulings
  | ($stored_handoffs | to_entries | map(.value + ($rulings[.key | tostring] // {}) | stored_handoff))
    + [$entries[] | select(has("index") | not) | stored_handoff];

# ---------------------------------------------------------------------------
# 7. Needs your decision (render-md.sh)
#
# The open items — open findings, unpromoted speculative entries and open
# handoffs — that return to the human, and the re-checks they carry.
# ---------------------------------------------------------------------------

def open_items:
  (.findings[] | select(is_open_finding)),
  unpromoted_speculative_entries[],
  (.handoffs // [] | .[] | select(is_open_handoff));

# Why an open item waits on the human, or null; one reason per item, the
# first that applies: an edge-case CRITICAL/HIGH awaiting confirmation, a
# re-check that escalated the item to the human and that the human has not
# decided since (recheck.decided, review-update-status.sh), or a confirmed
# edge case whose re-check survived.
def decision_reasons: ["edge-case", "escalated", "survived"];
def awaits_escalation_decision: has_recheck_status("escalated") and .recheck.decided != true;
def decision_reason:
  if awaits_edge_case_decision then "edge-case"
  elif awaits_escalation_decision then "escalated"
  elif .realism_confirmed == true and has_recheck_status("survived") then "survived"
  else null end;
def needs_decision: decision_reason != null;

# The open items needing a decision, by reason, and their total.
def decision_tally:
  [open_items | decision_reason | select(. != null)] as $reasons
  | {total: ($reasons | length)}
    + (reduce decision_reasons[] as $reason ({};
         .[$reason] = ([$reasons[] | select(. == $reason)] | length)));

# The re-checks on the open items, by status, an escalated one the human has
# decided counted as decided (it no longer awaits the human, as
# awaits_escalation_decision says). An unrecognized status counts toward
# total only.
def recheck_tally_keys: ["pending", "survived", "cleared", "escalated", "decided", "dismissed"];
def recheck_tally_key: if .status == "escalated" and .decided == true then "decided" else .status end;
def recheck_tally:
  [open_items | .recheck | select(. != null) | recheck_tally_key] as $keys
  | {total: ($keys | length)}
    + (reduce recheck_tally_keys[] as $key ({};
         .[$key] = ([$keys[] | select(. == $key)] | length)));
