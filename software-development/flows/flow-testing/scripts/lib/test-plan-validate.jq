# test-plan-validate.jq — the ONE validator for a flow-testing test plan
# (test-plan.schema.json): shape AND the cross-field rules JSON Schema cannot
# express, plus the one body-assembly shape every writer builds from. A jq
# module included (`include "test-plan-validate" {search: <this lib dir,
# absolute>};`) by test-plan-create.sh,
# test-plan-challenge.sh, test-plan-amend.sh, test-plan-approve.sh,
# test-plan-recheck.sh and render-md.sh, so the writers and the renderer can
# never disagree about what a valid plan is. It includes security-terms.jq,
# the matcher flow-review's writers use, from flow-review/scripts/lib, by a
# search path relative to this module's own directory (an unpinned lookup
# searches the process's working directory first); nothing here touches a file, takes a
# $-argument, or has a side effect.
#
# Every *_errors def returns an ARRAY of error strings, each prefixed with the
# failing field path (`tests[2].guards[0]: unknown behavior id B9`) — empty
# means valid. Entry points:
#   plan_input_errors($kind; $diff_files)  a caller-supplied file: "create"
#                             (fields-file: body only), "challenge" (body +
#                             reviewer), "amend" (body + amendments +
#                             optional no_e2e_agreed), judged against the
#                             diff's file list
#   challenge_input_errors($stored; $diff_files)  a challenge fields-file
#                             judged against the stored draft it challenges
#   amend_input_errors($stored; $diff_files)  an amend fields-file judged
#                             against the stored plan it amends
#   amended_reviewer($fields) the stored reviewer after an amend
#   plan_document_errors      a stored, stamped plan document (every rule
#                             but the write-only ones: the end-to-end, then
#                             integration, then unit order, change.files
#                             being present, the evidence (in a proof form,
#                             naming a test the plan holds) and category
#                             every not_tested entry names, and the diff
#                             scope)
#   unwaived_category_errors  a plan to approve: no exclusion that needs the
#                             human waiver (a required test category, or
#                             unproven) left without it, and no entry left
#                             unjudged (one without a category)
#   carry_waivers($stored_not_tested)  a body being written, with the stored
#                             waivers kept on unchanged entries
#   not_tested_number_offset  the number the Not tested list continues from
#                             (render-md.sh numbers its entries after the
#                             tests and the rejected proposals)
#   waive_not_tested($index; $reason)  the stored plan with one exclusion
#                             waived (0-based $index), recorded as an
#                             amendment
#   needs_waiver              whether an exclusion needs the human waiver
#   recheck_sidecar_errors($plan_id)  the <id>.recheck.json sidecar of
#                             test-plan-recheck.sh
#   not_tested_digest_input   a not_tested entry as its sidecar digest
#                             covers it
#   baseline_digest_inputs    each test, existing-test entry and section
#                             entry or digest as its approved_baseline
#                             fingerprint covers it
#   file_roles                each listed file with the role it is shown
#                             under (file, fixture, or on its repair or
#                             delete entry) and its marks, for render-md.sh
#   baseline_fingerprints($digests)  the plan's fingerprints, from the
#                             digests of baseline_digest_inputs, in the
#                             approved_baseline shape (approved_at aside)
#   approved_baseline($digests)  an approved plan's approved_baseline
#   approved_baseline_after_amend($digests)  the approved_baseline an
#                             amend of this stored plan records
#   not_tested_proof_locator_lines  each file:line a not_tested proof names,
#                             as a "<field path><TAB><file><TAB><start><TAB>
#                             <end>" line for the writers' --repo-root check
#   slug_errors($path)        a plan id / --slug value
#   plan_body($source)        the body sections of a validated $source,
#                             integers normalized — what every writer stores
#   diff_file_list            diff-files.txt or diff-files.tsv, read with
#                             `jq -R -s`, as a sorted array of unique paths
#                             or {path, sha} objects
#   plan_repo_path_lines      a validated plan's change.files,
#                             files.existing and files.new paths, each as a
#                             "<field path><TAB><path>" line for the
#                             writers' --repo-root symlink check
#
# WHY the diff scope binds only a plan being written: a plan tests the diff
# and nothing else, so each writer that takes a body — test-plan-create.sh,
# test-plan-challenge.sh and test-plan-amend.sh — checks change.files,
# files.existing and files.new against the list diff-scope.sh wrote and
# records that list as diff_files; test-plan-approve.sh carries diff_files
# unchanged. A stored plan is never re-judged against a diff, so one whose
# diff has moved on still renders, approves and verifies.
#
# WHY cross-field rules run only once the shape is clean: they index into
# fields the shape checks vouch for, so a malformed value would otherwise
# surface as a jq runtime error instead of a named field path.
#
# WHY an amend fields-file is checked in three passes: on its own (shape, body
# rules, the no_e2e_agreed shape), then against the stored plan (recorded
# changes, the agreement an amend that removes the last end-to-end test must
# supply), then — merged with the stored reviewer and amendments — as a whole
# plan (plan_document_errors), because reviewer coverage and the "accepted
# needs an amendment" rule depend on that history.
#
# Regex code points are written as Oniguruma `\x{...}` escapes, so this file
# stays plain ASCII (no invisible character can hide in it) and the patterns
# mean the same on every jq from 1.6 on.

include "security-terms" {search: "../../../flow-review/scripts/lib"};

def field_path($parent; $key): if $parent == "" then $key else $parent + "." + $key end;
def item_path($parent; $index): $parent + "[" + ($index | tostring) + "]";
def failure($path; $message): $path + ": " + $message;

def body_required_keys: ["change", "run", "behaviors", "existing_tests", "tests", "not_tested", "files", "approx_lines"];
def body_optional_keys: ["builds_on", "no_e2e_reason", "no_unit_reason"];
def stamped_keys: ["schema_version", "id", "status", "created", "approved_at"];
# Recorded by every writer from its --diff-files, never supplied in a
# fields-file; a stored plan without it is read as it is.
# snapshot: the diff-scope.sh --snapshot-out tree the diff was taken since,
# from test-plan-create.sh --snapshot and carried by every later writer.
def diff_scope_keys: ["diff_files", "snapshot"];
# Recorded only by test-plan-amend.sh from the approved plan it amends, never
# supplied in a fields-file (approved_baseline_after_amend).
def baseline_keys: ["approved_baseline"];
def after_challenge_keys: ["reviewer", "amendments"];
def statuses: ["draft", "challenged", "approved"];
# e2e drives the feature through its entry point; integration exercises real
# infrastructure (a real database, service or process, no mock of the
# project's own code); unit is everything below.
def levels: ["e2e", "integration", "unit"];
def unit_kinds: ["required", "optional", "accepted"];
# A draft (or a rejected proposal) has not been through the human, so it can
# only propose a unit test as required or optional; "accepted" is the human's.
def proposed_unit_kinds: ["required", "optional"];
def reviewer_change_actions: ["merged", "to-unit", "to-integration", "to-e2e", "changed", "added"];
# "waived" is recorded only by test-plan-amend.sh --waive-not-tested.
def amendment_actions: ["restored", "accepted", "removed", "merged", "to-unit", "to-integration", "to-e2e", "changed", "added", "waived"];
# The actions that change which tests exist or how they are kept, so the
# reviewer-coverage rules can tie each to its test by name. A merge or rename
# is recorded as removed (each old name) + added (the new name), a rename's
# added amendment naming the old one in renamed_from.
def amendment_actions_needing_test: ["restored", "accepted", "removed", "added"];
# The body sections a challenge or an amend must record by name when it
# changes them (tests are recorded per test instead).
def recordable_fields: ["change", "run", "builds_on", "behaviors", "existing_tests", "no_e2e_reason", "no_unit_reason", "not_tested", "files", "approx_lines"];
# Free text is capped short so every rendered line stays scannable; the
# identifiers, paths and run command shown in code spans are not prose and
# keep room for long test names and deep paths. A reason in plain words —
# why a re-check escalated an entry, the human's reason for a waiver — gets
# more room than other prose.
def max_text_length: 100;
def max_reason_length: 200;
def max_code_length: 300;

# Characters no plan string may carry, and the set render-md.sh's neutralize
# replaces: C0/DEL/C1 controls (newlines included), the line/paragraph
# separators (they split a rendered line), and every invisible format
# character — bidi controls (the rendered plan is what the human approves,
# and an override can make it display in a different order than it reads),
# zero-width and soft-hyphen characters, variation selectors, and the tag
# characters, which can carry text the human never sees to a downstream
# agent. test-plan.schema.json's patterns list the BMP part of this set; its
# surrogate-pair form of the astral ranges matches only in non-unicode ECMA
# mode, so this lib is the one enforcer of those.
def forbidden_characters:
  "[\\x{0}-\\x{1F}\\x{7F}-\\x{9F}\\x{AD}\\x{61C}\\x{180E}\\x{200B}-\\x{200F}\\x{2028}-\\x{202E}\\x{2060}-\\x{2064}\\x{2066}-\\x{206F}\\x{FE00}-\\x{FE0F}\\x{FEFF}\\x{FFF9}-\\x{FFFB}\\x{E0000}-\\x{E007F}\\x{E0100}-\\x{E01EF}]";

# The Unicode space separators (Zs). Every other whitespace character is a
# control, already in forbidden_characters.
def space_characters: "[\\x{20}\\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{202F}\\x{205F}\\x{3000}]";

# A caller-supplied key echoed in a diagnostic: quoted by tojson, with any
# forbidden character tojson leaves raw (C1, bidi, tags) replaced by "?".
def shown_key: tojson | gsub(forbidden_characters; "?");

def member($list): . as $value | $list | any(. == $value);

# --- leaf value checks -------------------------------------------------------

def line_errors($path; $max):
  if type != "string" then [failure($path; "expected a string")]
  elif test(forbidden_characters) then [failure($path; "must be a single line with no control, line-separator, or invisible format characters")]
  elif test("\\A" + space_characters + "*\\z") then [failure($path; "must contain a visible character")]
  elif length > $max then [failure($path; "must be at most \($max) characters (got \(length))")]
  else [] end;

# Text inside a Markdown code span renders literally, so a tag there is inert
# (generics like Vec<String> are common in typed-language plans). Spans are
# matched the CommonMark way: an opening run of N backticks that is neither
# escaped nor part of a longer run, closed by the next run of exactly N. A
# lone, escaped or mismatched backtick therefore never hides live HTML from
# the tag check — whatever is not provably a span stays in and is checked.
# A backtick left over is rejected outright: the renderer joins several values
# (and its own template) on one Markdown line, so a stray backtick could pair
# with one in a later value and turn that value's inert `<tag>` into live HTML.
def outside_code_spans:
  gsub("(?<![`\\\\])(?<run>`+)(?!`).*?(?<!`)\\k<run>(?!`)"; "");

# Free text is shown to the human as approved prose, so anything that renders
# differently than it reads is rejected rather than escaped (an escape would
# put visible backslashes into the plan): HTML can hide renderer text, a link
# or image can point elsewhere or fetch on view, and whitespace padding can
# fake a line start in a terminal. A trailing backslash would escape the
# renderer's punctuation after the text.
def prose_errors_within($path; $max):
  line_errors($path; $max) as $errors
  | if $errors != [] then $errors
    elif test("\\A" + space_characters) or test(space_characters + "\\z") then [failure($path; "must not start or end with whitespace")]
    elif test(space_characters + "{2}") then [failure($path; "must not contain a run of 2 or more whitespace characters")]
    elif test("<!--|-->") then [failure($path; "must not contain \"<!--\" or \"-->\" (even inside a code span)")]
    elif (outside_code_spans | contains("`")) then [failure($path; "unbalanced backtick (every backtick must close within this value)")]
    elif (outside_code_spans | test("<[A-Za-z/!?]")) then [failure($path; "must not contain an HTML tag outside a code span")]
    elif test("\\]\\(|!\\[") then [failure($path; "must not contain Markdown link or image syntax (\"](\" or \"![\")")]
    elif endswith("\\") then [failure($path; "must not end with a backslash (it would escape the renderer's punctuation)")]
    else [] end;
# The renderer appends punctuation after plan text, so a trailing "."
# doubles it. A reason is the human's or the review-arbiter's sentence, quoted
# as written and never followed by the renderer's own full stop, so it keeps
# its period.
def text_errors_within($path; $max):
  prose_errors_within($path; $max) as $errors
  | if $errors != [] then $errors
    elif endswith(".") then [failure($path; "must not end with \".\" (the renderer owns all punctuation)")]
    else [] end;
def text_errors($path): text_errors_within($path; max_text_length);
def reason_errors($path): prose_errors_within($path; max_reason_length);

# A heading ending in whitespace + #'s loses them as a closing ATX sequence.
def subject_errors($path):
  text_errors($path) as $errors
  | if $errors != [] then $errors
    elif test("\\s#+\\z") then [failure($path; "must not end with a space followed by \"#\" (Markdown drops it from the heading)")]
    else [] end;

# Identifiers, commands and paths are rendered inside a Markdown code span,
# which a backtick would close early.
def code_errors($path):
  line_errors($path; max_code_length) as $errors
  | if $errors != [] then $errors
    elif contains("`") then [failure($path; "must not contain a backtick")]
    else [] end;

# An approved plan authorizes writes to its paths, so each must stay inside
# the repo: relative, no parent-directory or empty segment, and no form a
# shell or tool could read as an option or a Windows separator.
def path_errors($path):
  code_errors($path) as $errors
  | if $errors != [] then $errors
    elif startswith("/") or startswith("~") then [failure($path; "must be repo-relative (no leading \"/\" or \"~\")")]
    elif startswith("-") then [failure($path; "must not start with \"-\"")]
    elif contains("\\") then [failure($path; "must not contain a backslash")]
    elif (split("/") | any(. == "..")) then [failure($path; "must not contain a \"..\" segment")]
    elif (split("/") | any(. == "")) then [failure($path; "must not contain an empty segment (\"//\" or a trailing \"/\")")]
    else [] end;

# run is shown to the human as a command and may be pasted into a shell, so it
# holds plain commands chained only with &&.
def run_errors($path):
  code_errors($path) as $errors
  | if $errors != [] then $errors
    elif test("[;|$<>()\\\\]") then [failure($path; "must not contain \"\(match("[;|$<>()\\\\]").string)\" (only commands chained with && are allowed)")]
    elif (gsub("&&"; "") | contains("&")) then [failure($path; "must not contain a single \"&\" (only commands chained with && are allowed)")]
    else [] end;

# One existing test by its exact name: no glob character, so one approved
# entry can never stand for several tests.
def existing_name_errors($path):
  code_errors($path) as $errors
  | if $errors != [] then $errors
    elif test("[*?\\[\\]]") then [failure($path; "must name one test exactly (no \"*\", \"?\", \"[\" or \"]\")")]
    else [] end;

def enum_errors($path; $allowed):
  if type == "string" and member($allowed) then []
  else [failure($path; "must be one of: " + ($allowed | join(", ")))] end;

def positive_integer_errors($path):
  if type == "number" and . == floor and . >= 1 then []
  else [failure($path; "must be an integer >= 1")] end;

def behavior_id_errors($path):
  if type == "string" and test("\\AB[1-9][0-9]*\\z") then []
  else [failure($path; "must match B<positive integer>, e.g. B1")] end;

# Anchored with \A…\z, not ^…$: Oniguruma's `$` is end-of-LINE, so `^…$`
# would accept a slug with a trailing newline — which then reaches a filename.
def slug_errors($path):
  if type == "string" and test("\\A[a-z0-9]+(-[a-z0-9]+)*\\z") then []
  else [failure($path; "must be lowercase and hyphen-separated, e.g. submit-backslash-prompts")] end;

# Real calendar date, not just the YYYY-MM-DD shape: the strftime round trip
# rejects 2026-02-30.
def date_errors($path):
  if type == "string" and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}\\z")
     and ((try (strptime("%Y-%m-%d") | mktime | strftime("%Y-%m-%d")) catch null) == .)
  then []
  else [failure($path; "must be a date YYYY-MM-DD")] end;

# --- container checks --------------------------------------------------------

def object_key_errors($path; $required; $optional):
  if type != "object" then [failure($path; "expected an object")]
  else
    [ $required[] as $key | select(has($key) | not) | failure(field_path($path; $key); "required field missing") ]
    + [ keys_unsorted[] as $key
        | select(($required + $optional) | any(. == $key) | not)
        | failure(field_path($path; $key | shown_key); "unknown field") ]
  end;

def array_errors($path; $min_items):
  if type != "array" then [failure($path; "expected an array")]
  elif length < $min_items then [failure($path; "must have at least \($min_items) item(s)")]
  else [] end;

# Runs `checks` only when the object-key check passed, so a field-level check
# never indexes a non-object.
def guarded($key_errors; checks): if $key_errors != [] then $key_errors else checks end;

def each_item_errors($path; $min_items; checks):
  (array_errors($path; $min_items)) as $array
  | if $array != [] then $array
    else . as $items | [range(0; $items | length) as $i | {path: item_path($path; $i), value: $items[$i]} | checks[]] end;

def optional_errors($key; checks): if has($key) then (.[$key] | checks) else [] end;

# A key that must be present exactly when $condition holds.
def present_iff_errors($path; $key; $condition; $reason):
  if $condition and (has($key) | not) then [failure(field_path($path; $key); "required when " + $reason)]
  elif ($condition | not) and has($key) then [failure(field_path($path; $key); "must be absent unless " + $reason)]
  else [] end;

# --- section shape -----------------------------------------------------------

# files (the production files the plan tests) is optional here, so a stored
# plan without it is read as it is; every write requires it
# (change_files_presence_errors).
def change_errors($path):
  object_key_errors($path; ["subject", "under_test"]; ["files"]) as $keys
  | guarded($keys;
      (.subject | subject_errors(field_path($path; "subject")))
      + (.under_test | each_item_errors(field_path($path; "under_test"); 1;
           .path as $p | .value | text_errors($p)))
      + optional_errors("files"; each_item_errors(field_path($path; "files"); 1;
           .path as $p | .value | path_errors($p))));

def change_files_presence_errors:
  if (.change | type) == "object" and (.change | has("files") | not)
  then [failure("change.files"; "required field missing (the production files whose behavior the plan tests)")]
  else [] end;

# The diff_files a writer recorded from --diff-files: non-empty path
# strings, or {path, sha} objects when it was given diff-files.tsv.
def is_diff_file_entry:
  (type == "string" and length > 0)
  or (type == "object" and (keys == ["path", "sha"])
      and (.path | type == "string" and length > 0)
      and (.sha | type == "string" and test("\\A([0-9a-f]{40}|[0-9a-f]{64}|-)\\z")));

# The full 40- or 64-hex tree sha diff-scope.sh --snapshot-out printed.
def snapshot_errors($path):
  if type == "string" and test("\\A([0-9a-f]{40}|[0-9a-f]{64})\\z") then []
  else [failure($path; "must be the full 40- or 64-hex tree sha diff-scope.sh --snapshot-out printed")] end;

def diff_files_errors:
  array_errors("diff_files"; 1) as $array
  | if $array != [] then $array
    else [ to_entries[] | select(.value | is_diff_file_entry | not)
           | failure(item_path("diff_files"; .key); "must be a non-empty path string or a {path, sha} object") ] end;

def behavior_errors($path):
  object_key_errors($path; ["id", "text"]; []) as $keys
  | guarded($keys;
      (.id | behavior_id_errors(field_path($path; "id")))
      + (.text | text_errors(field_path($path; "text"))));

def named_reason_errors($path):
  object_key_errors($path; ["name", "reason"]; []) as $keys
  | guarded($keys;
      (.name | code_errors(field_path($path; "name")))
      + (.reason | text_errors(field_path($path; "reason"))));

# A reused test is named only; a test to repair or delete also names its
# file, so the change it authorizes is pinned to one test in one file.
def existing_entry_errors($path; $with_file):
  object_key_errors($path; ["name"] + (if $with_file then ["file"] else [] end) + ["reason"]; []) as $keys
  | guarded($keys;
      (.name | existing_name_errors(field_path($path; "name")))
      + (if $with_file then (.file | path_errors(field_path($path; "file"))) else [] end)
      + (.reason | text_errors(field_path($path; "reason"))));

def existing_tests_errors($path):
  object_key_errors($path; ["reused", "repair", "delete"]; ["none_reason"]) as $keys
  | guarded($keys;
      ( [ ("reused", "repair", "delete") as $list
          | .[$list] | each_item_errors(field_path($path; $list); 0;
              .path as $p | .value | existing_entry_errors($p; $list != "reused"))[] ]
      ) as $lists
      | if $lists != [] then $lists
        else
          present_iff_errors($path; "none_reason"; ([.reused, .repair, .delete] | all(length == 0));
            "reused, repair and delete are all empty")
          + optional_errors("none_reason"; text_errors(field_path($path; "none_reason")))
        end);

def fixture_errors($path):
  object_key_errors($path; ["path", "from"]; []) as $keys
  | guarded($keys;
      (.path | path_errors(field_path($path; "path")))
      + (.from | text_errors(field_path($path; "from"))));

# The keys only one level may carry: e2e REQUIRES a golden (it asserts the
# whole observable outcome) and FORBIDS the unit-only keys; integration
# REQUIRES why_not_e2e and FORBIDS unit_kind; unit REQUIRES unit_kind and
# why_not_e2e. Skipped while level itself is invalid.
def level_rule_errors($path; $allowed_unit_kinds):
  if .level == "e2e" then
    (if has("golden") then [] else [failure(field_path($path; "golden"); "required for an end-to-end test")] end)
    + [ ("unit_kind", "why_not_e2e") as $key | select(has($key))
        | failure(field_path($path; $key); "must be absent for an end-to-end test") ]
  elif .level == "integration" then
    (if has("unit_kind") then [failure(field_path($path; "unit_kind"); "must be absent for an integration test")] else [] end)
    + (if has("why_not_e2e") then (.why_not_e2e | text_errors(field_path($path; "why_not_e2e")))
       else [failure(field_path($path; "why_not_e2e"); "required for an integration test")] end)
  elif .level == "unit" then
    (if has("unit_kind") then (.unit_kind | enum_errors(field_path($path; "unit_kind"); $allowed_unit_kinds))
     else [failure(field_path($path; "unit_kind"); "required for a unit test")] end)
    + (if has("why_not_e2e") then (.why_not_e2e | text_errors(field_path($path; "why_not_e2e")))
       else [failure(field_path($path; "why_not_e2e"); "required for a unit test")] end)
  else [] end;

# A planned test (with n) or a rejected proposal (without n, and with only
# the unit kinds a proposal can carry).
def test_entry_errors($path; $with_n; $allowed_unit_kinds):
  object_key_errors($path;
    (if $with_n then ["n"] else [] end) + ["name", "level", "guards", "why", "fails_if", "file"];
    ["input", "golden", "unit_kind", "why_not_e2e"]) as $keys
  | guarded($keys;
      (if $with_n then (.n | positive_integer_errors(field_path($path; "n"))) else [] end)
      + (.name | code_errors(field_path($path; "name")))
      + (.level | enum_errors(field_path($path; "level"); levels))
      + (.guards | each_item_errors(field_path($path; "guards"); 1; .path as $p | .value | behavior_id_errors($p)))
      + (.why | text_errors(field_path($path; "why")))
      + (.fails_if | text_errors(field_path($path; "fails_if")))
      + (.file | path_errors(field_path($path; "file")))
      + optional_errors("input"; fixture_errors(field_path($path; "input")))
      + optional_errors("golden"; fixture_errors(field_path($path; "golden")))
      + level_rule_errors($path; $allowed_unit_kinds));

# A re-check of an exclusion is recorded only in the sidecar
# test-plan-recheck.sh writes, never in the plan: pending, with no outcome
# yet; survived or cleared with the proof of the outcome; or escalated to the
# human with the reason the re-check could not settle it (the verifier's or
# the adversary's unresolved disagreement). An escalated entry is closed by
# the human: dismissed, with their reason, keeps it untested.
def terminal_recheck_statuses: ["survived", "cleared", "escalated"];
def recheck_statuses: ["pending"] + terminal_recheck_statuses + ["dismissed"];

# Every proof names checkable evidence that exists: a file:line (or
# file:start-end) locator whose file is path-like — it holds a letter and has
# an extension, a "/", or is one of extensionless_file_names, and it is no
# part of a URL (10:30 or 1:1000 is not one) — which the writer resolves
# under --repo-root and against the file's length; or a test number the
# plan holds (test 3, Covered by test 3). A plan author, the reviewer and
# the review-arbiter have no shell, so no plan proof starts "ran ". The
# locator rule is the same in flow-review's review-aggregates.jq (each flow
# loads only the libs under its own scripts/ directory, so the two copies
# change together).
def plan_proof_forms: ["locator", "test"];

def extensionless_file_names: ["Makefile", "Dockerfile", "Justfile", "Rakefile", "Gemfile", "Procfile"];
def is_path_like_file:
  test("[A-Za-z]")
  and (contains("/")
       or test("\\.[A-Za-z0-9_-]*[A-Za-z][A-Za-z0-9_-]*\\z")
       or member(extensionless_file_names));

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

def proof_test_numbers: [scan("(?<![A-Za-z])[Tt]est ([0-9]+)(?![0-9])") | .[0] | tonumber];

def proof_form_matches($form):
  if $form == "locator" then has_file_line_locator
  else proof_test_numbers != [] end;

def is_proof_format($forms):
  type == "string" and (. as $proof | any($forms[]; . as $form | $proof | proof_form_matches($form)));

def proof_form_text:
  {locator: "a file:line locator (src/a.rs:42, src/a.rs:42-50, Makefile:3; the file has an extension or a \"/\", or is \(extensionless_file_names | join(", ")); never a URL or a bare number like 10:30)",
   test: "a test number of this plan (test 3, Covered by test 3)"}[.];
def proof_format_rule($forms):
  "must name its evidence in an accepted form: " + ($forms | map(proof_form_text) | join(", or "));

# A proof value: plan text, in one of $forms.
def proof_errors($path; $forms):
  text_errors($path) as $errors
  | if $errors != [] then $errors
    elif is_proof_format($forms) | not then [failure($path; proof_format_rule($forms))]
    else [] end;

# Every test number a proof names is a test the plan holds ($test_count
# tests, numbered 1..$test_count).
def proof_test_errors($path; $test_count):
  [ proof_test_numbers[] | select(. < 1 or . > $test_count)
    | failure($path; "names test \(.), which the plan does not hold (its tests are numbered 1-\($test_count))") ];

# What an exclusion leaves untested. Every category but other is a required
# test category: it is left untested only with the human's waiver
# (waived_by_human, set by test-plan-amend.sh --waive-not-tested, with the
# human's waiver_reason). An unproven exclusion of any category needs the
# waiver too; a proven other one needs none, though the human may still
# waive it. test-plan-approve.sh refuses a plan holding one unwaived.
def not_tested_categories: ["security", "persisted-data", "concurrency", "authentication", "other"];
def waiver_keys: ["waived_by_human", "waiver_reason"];

# An exclusion may name its evidence: proof (one line: a covering test, a
# file:line) or unproven, the literal true — never both. Which one it must
# carry, its category, and the proof form are write-only rules
# (not_tested_write_errors). A re-check is never stored on it: recheck is
# known here only to be refused by name.
def exclusion_errors($path):
  object_key_errors($path; ["what", "reason", "accepting"];
    ["category", "proof", "unproven", "recheck"] + waiver_keys) as $keys
  | guarded($keys;
      [ ("what", "reason", "accepting") as $key
        | .[$key] | text_errors(field_path($path; $key))[] ]
      + optional_errors("category"; enum_errors(field_path($path; "category"); not_tested_categories))
      + optional_errors("proof"; text_errors(field_path($path; "proof")))
      + optional_errors("unproven";
          if . == true then [] else [failure(field_path($path; "unproven"); "must be true when given (omit it otherwise)")] end)
      + (if has("proof") and has("unproven")
         then [failure(field_path($path; "unproven"); "proof and unproven are mutually exclusive: give exactly one")]
         else [] end)
      + optional_errors("waived_by_human";
          if . == true then [] else [failure(field_path($path; "waived_by_human"); "must be true when given (omit it otherwise)")] end)
      + present_iff_errors($path; "waiver_reason"; (.waived_by_human == true); "waived_by_human is true")
      + optional_errors("waiver_reason"; reason_errors(field_path($path; "waiver_reason")))
      + (if has("recheck") then [failure(field_path($path; "recheck"); "a re-check is recorded in the sidecar (test-plan-recheck.sh), never in the plan")] else [] end));

def new_file_errors($path):
  object_key_errors($path; ["path", "kind", "justification"]; []) as $keys
  | guarded($keys;
      (.path | path_errors(field_path($path; "path")))
      + (.kind | enum_errors(field_path($path; "kind"); ["test-file", "harness", "fixture"]))
      + (.justification | text_errors(field_path($path; "justification"))));

def files_errors($path):
  object_key_errors($path; ["existing", "new"]; []) as $keys
  | guarded($keys;
      (.existing | each_item_errors(field_path($path; "existing"); 0; .path as $p | .value | path_errors($p)))
      + (.new | each_item_errors(field_path($path; "new"); 0; .path as $p | .value | new_file_errors($p))));

def reviewer_change_errors($path):
  object_key_errors($path; ["action", "item", "reason"]; ["test", "field"]) as $keys
  | guarded($keys;
      (.action | enum_errors(field_path($path; "action"); reviewer_change_actions))
      + optional_errors("test"; code_errors(field_path($path; "test")))
      + optional_errors("field"; enum_errors(field_path($path; "field"); recordable_fields))
      + (.item | text_errors(field_path($path; "item")))
      + (.reason | text_errors(field_path($path; "reason"))));

def rejected_errors($path):
  object_key_errors($path; ["test", "reason"]; []) as $keys
  | guarded($keys;
      (.test | test_entry_errors(field_path($path; "test"); false; proposed_unit_kinds))
      + (.reason | text_errors(field_path($path; "reason"))));

def reviewer_shape_errors:
  .reviewer
  | object_key_errors("reviewer"; ["approved", "rejected", "changes"]; ["no_e2e_agreed"]) as $keys
  | guarded($keys;
      (.approved | each_item_errors("reviewer.approved"; 0; .path as $p | .value | named_reason_errors($p)))
      + (.rejected | each_item_errors("reviewer.rejected"; 0; .path as $p | .value | rejected_errors($p)))
      + (.changes | each_item_errors("reviewer.changes"; 0; .path as $p | .value | reviewer_change_errors($p)))
      + optional_errors("no_e2e_agreed"; text_errors("reviewer.no_e2e_agreed")));

# A removed amendment names a test, or — with field not_tested — the
# not_tested entry it removes, by its what in item.
def is_not_tested_removal: .action == "removed" and .field == "not_tested";

# A waived amendment's reason is the human's waiver_reason. A rename is
# recorded as removed (the old name) plus added (the new one), the added
# amendment naming the old test in renamed_from, so the render can show one
# renamed test rather than a removed and a new one.
def amendment_errors($path):
  . as $item
  | object_key_errors($path; ["action", "item", "reason"]; ["test", "field", "renamed_from"]) as $keys
  | guarded($keys;
      (.action | enum_errors(field_path($path; "action"); amendment_actions))
      + optional_errors("field"; enum_errors(field_path($path; "field"); recordable_fields))
      + (.item | text_errors(field_path($path; "item")))
      + (.reason | if $item.action == "waived" then reason_errors(field_path($path; "reason"))
                   else text_errors(field_path($path; "reason")) end)
      + optional_errors("test"; code_errors(field_path($path; "test")))
      + optional_errors("renamed_from"; code_errors(field_path($path; "renamed_from")))
      + (if has("renamed_from") and .action != "added"
         then [failure(field_path($path; "renamed_from"); "allowed only on an added amendment (the old name of the test it adds)")]
         else [] end)
      + (if (.action | member(amendment_actions_needing_test)) and (has("test") | not)
            and (is_not_tested_removal | not)
         then [failure(field_path($path; "test"); "required for a \(.action) amendment (the test it applies to)"
                 + (if .action == "removed" then "; a removed not_tested entry is named by item with field not_tested instead" else "" end))]
         else [] end));

def amendments_shape_errors:
  .amendments | each_item_errors("amendments"; 1; .path as $p | .value | amendment_errors($p));

# Shape of the body sections. The caller has already confirmed `.` is an
# object holding every required body key.
def body_shape_errors:
  (.change | change_errors("change"))
  + (.run | run_errors("run"))
  + optional_errors("builds_on"; each_item_errors("builds_on"; 0; .path as $p | .value | code_errors($p)))
  + (.behaviors | each_item_errors("behaviors"; 1; .path as $p | .value | behavior_errors($p)))
  + (.existing_tests | existing_tests_errors("existing_tests"))
  + (.tests | each_item_errors("tests"; 1; .path as $p | .value | test_entry_errors($p; true; unit_kinds)))
  + optional_errors("no_e2e_reason"; text_errors("no_e2e_reason"))
  + optional_errors("no_unit_reason"; text_errors("no_unit_reason"))
  + (.not_tested | each_item_errors("not_tested"; 0; .path as $p | .value | exclusion_errors($p)))
  + (.files | files_errors("files"))
  + (.approx_lines | positive_integer_errors("approx_lines"));

# --- cross-field rules (run only on a shape-clean plan) ------------------------

# For an array, each position whose value already appeared earlier, paired
# with the first position holding it: [{index, first}, ...].
def duplicate_positions:
  . as $values
  | [ range(0; length) as $i
      | ($values[:$i] | index([$values[$i]])) as $first
      | select($first != null)
      | {index: $i, first: $first} ];

def has_level($level): any(.tests[]; .level == $level);

def numbering_errors:
  [ .tests | to_entries[] | select(.value.n != .key + 1)
    | failure(item_path("tests"; .key) + ".n"; "expected \(.key + 1) (tests are numbered 1..N in order), got \(.value.n)") ];

# End-to-end tests come first, then integration, then unit, so n runs 1..N
# down the rendered plan. Only a body being written is held to this
# (plan_input_errors): a stored plan is read whatever its order, so one out
# of order can still be rendered, approved and amended into order.
def level_rank: {"e2e": 0, "integration": 1, "unit": 2}[.];
def level_order_rule:
  {"e2e": "an end-to-end test must come before every integration and unit test",
   "integration": "an integration test must come before every unit test"}[.];

def level_order_errors:
  .tests | to_entries as $entries
  | [ $entries[] | .key as $i | .value.level as $level
      | select(any($entries[:$i][]; (.value.level | level_rank) > ($level | level_rank)))
      | failure(item_path("tests"; $i) + ".level";
          ($level | level_order_rule) + " (tests are numbered end-to-end, then integration, then unit)") ];

# An exclusion whose prose names a security weakness or subject
# (lib/security-terms.jq) leaves security untested, so it is filed under a
# security category, where it needs the human waiver, rather than slipping
# through as a proven other one.
def not_tested_security_categories: ["security", "authentication"];
def not_tested_prose_keys: ["what", "reason", "accepting"];
def not_tested_security_errors:
  [ .not_tested | to_entries[] | (item_path("not_tested"; .key)) as $path | .value
    | select(has("category") and (.category | IN(not_tested_security_categories[]) | not)) | . as $entry
    | first(not_tested_prose_keys[] as $key | $entry[$key] | strings
            | (named_security_term // named_security_subject) as $named | select($named != null)
            | failure(field_path($path; $key);
                "names security/authentication — set category security or authentication; security/authentication outranks other required categories (it names \($named | tojson))")) ];

# Every exclusion in a body being written names its evidence in a plan proof
# form and its category (a security one when its prose names security), and
# a what no other exclusion names, so a coverage gap without proof is visible
# as one and each exclusion is told apart; the waiver and a re-check are the
# human's, never a fields-file's. Only a body
# being written is held to this; a stored entry without a category is read
# as it is, and approval refuses it (unwaived_category_errors).
def not_tested_write_errors:
  (.tests | length) as $test_count
  | not_tested_security_errors as $security
  | [ .not_tested | to_entries[] | (item_path("not_tested"; .key)) as $path | .value
    | (if (has("proof") or has("unproven")) | not
       then failure($path; "needs exactly one of proof (one line: a covering test such as \"Covered by test 3\", or a file:line such as src/a.rs:42) or unproven: true")
       else empty end),
      (select(has("proof")) | .proof | select(is_proof_format(plan_proof_forms) | not)
       | failure(field_path($path; "proof"); proof_format_rule(plan_proof_forms))),
      (select(has("proof")) | .proof | proof_test_errors(field_path($path; "proof"); $test_count)[]),
      (select(has("category") | not)
       | failure(field_path($path; "category"); "required field missing (one of: " + (not_tested_categories | join(", ")) + ")")),
      (waiver_keys[] as $key | select(has($key))
       | failure(field_path($path; $key); "set only by test-plan-amend.sh --waive-not-tested after the human answers")) ]
  + $security
  + [ .not_tested | map(.what) | duplicate_positions[]
      | failure(item_path("not_tested"; .index) + ".what"; "duplicate of not_tested[\(.first)].what (each exclusion names a different what)") ];

# Whether an exclusion needs the human waiver: one in a required test
# category (every category but other), and one of any category without
# proof (fail closed: an entry naming neither proof nor unproven counts as
# unproven). An entry with no category is not judged here: render-md.sh
# marks it, approval refuses it, and an amend gives it a category.
def is_unjudged_exclusion: .category == null;
def needs_waiver:
  (is_unjudged_exclusion | not) and (.category != "other" or (has("proof") | not));

# The planned tests, then the rejected proposals not restored (shown_rejected,
# numbered on from the last test so "restore 6" names one entry), then the
# Not tested entries: one run of numbers, so no two entries share one. The
# Not tested number is what --waive-not-tested and test-plan-recheck.sh
# --not-tested take.
def shown_rejected:
  (.tests | map(.name)) as $planned
  | (.tests | length) as $planned_count
  | [ .reviewer // {} | .rejected // [] | .[] | select(.test.name | member($planned) | not) ]
  | to_entries | map(.value + {shown_n: ($planned_count + .key + 1)});
def not_tested_number_offset: (.tests | length) + (shown_rejected | length);

# A plan to approve holds no exclusion that needs the human waiver without
# it, and none left unjudged. Each is named by its Not tested number.
def unwaived_category_errors:
  not_tested_number_offset as $offset
  | [ .not_tested | to_entries[]
      | (item_path("not_tested"; .key) + " (Not tested \($offset + .key + 1))") as $path
      | if .value | is_unjudged_exclusion then
          failure($path; "has no category, so it is not judged: give it a category and proof or unproven with test-plan-amend.sh")
        elif (.value | needs_waiver) and .value.waived_by_human != true then
          failure($path;
            (if .value.category != "other" then "\(.value.category) is a required test category" else "it is not proven" end)
            + ": test it, or record the human waiver with test-plan-amend.sh --waive-not-tested \($offset + .key + 1) --expect-sha HEX --reason TEXT")
        else empty end ];

# The body's not_tested with each stored waiver carried onto the entry it was
# given for: an entry equal to a stored waived one (waiver aside) keeps the
# waiver, and any change to the entry drops it.
def carry_waivers($stored_not_tested):
  (($stored_not_tested // []) | map(select(.waived_by_human == true))) as $waived
  | .not_tested |= map(. as $entry
      | (first($waived[] | select(del(.waived_by_human, .waiver_reason) == $entry)) // null) as $match
      | if $match == null then $entry else $entry + {waived_by_human: true, waiver_reason: $match.waiver_reason} end);

# The stored plan with not_tested[$index] waived by the human, recorded as a
# waived amendment whose reason is the human's.
def waive_not_tested($index; $reason):
  .not_tested[$index] as $entry
  | .not_tested[$index] += {waived_by_human: true, waiver_reason: $reason}
  | .amendments = ((.amendments // [])
      + [{action: "waived", item: $entry.what, reason: $reason, field: "not_tested"}]);

# Each file:line a not_tested proof names, for the writers' --repo-root
# check. Run only on a validated plan.
def not_tested_proof_locator_lines:
  .not_tested | to_entries[] | (item_path("not_tested"; .key) + ".proof") as $path
  | .value.proof | strings | proof_locators[]
  | "\($path)\t\(.file)\t\(.start)\t\(.end)";

# The sidecar test-plan-recheck.sh writes beside a plan (<id>.recheck.json):
# a re-check of a not_tested entry, recorded once per entry. Each record
# holds entry_sha256, the SHA-256 of the entry it re-checked as `jq -S -c`
# prints it with the waiver keys removed (the shell computes it: jq has no
# hash), and is shown, and refuses a second re-check, only for an entry
# equal to that one — as carry_waivers keeps a waiver — so an amendment that
# changes or renumbers the entry never moves a re-check onto another.
# not_tested (its Not tested number) and what record where it stood. A
# pending record carries neither proof nor reason and is replaced by the
# entry's next re-check; a survived or cleared record carries the proof of
# the outcome, an escalated one the reason the re-check escalated the entry
# to the human. An escalated record alone may be followed by a second record
# for its entry: the human's dismissal, with their reason. Never part
# of the plan bytes, so the plan digest is unchanged. A prefix of
# entry_sha256 is also the entry's handle (test-plan-recheck.sh
# --list-not-tested), which the waiver and re-check writers take as
# --expect-sha so a moved number never lands on another entry.
def is_sha256_text: type == "string" and test("\\A[0-9a-f]{64}\\z");
def not_tested_digest_input: del(.waived_by_human, .waiver_reason);

def sidecar_recheck_errors($path):
  object_key_errors($path; ["not_tested", "what", "entry_sha256", "status", "recorded"]; ["proof", "reason"]) as $keys
  | guarded($keys;
      (.not_tested | positive_integer_errors(field_path($path; "not_tested")))
      + (.what | text_errors(field_path($path; "what")))
      + (.entry_sha256 | if is_sha256_text then [] else [failure(field_path($path; "entry_sha256"); "must be 64 lowercase hex digits (the SHA-256 of the entry)")] end)
      + (.status | enum_errors(field_path($path; "status"); recheck_statuses))
      + (if .status == "pending" then
           present_iff_errors($path; "reason"; false; "status is escalated or dismissed")
           + present_iff_errors($path; "proof"; false; "status is survived or cleared")
         elif .status == "escalated" or .status == "dismissed" then
           present_iff_errors($path; "reason"; true; "status is escalated or dismissed")
           + present_iff_errors($path; "proof"; false; "status is survived or cleared")
           + optional_errors("reason"; reason_errors(field_path($path; "reason")))
         else
           present_iff_errors($path; "proof"; true; "status is survived or cleared")
           + present_iff_errors($path; "reason"; false; "status is escalated or dismissed")
           + optional_errors("proof"; proof_errors(field_path($path; "proof"); plan_proof_forms))
         end)
      + (.recorded | date_errors(field_path($path; "recorded"))));

# Each entry's records, in order: one re-check, or an escalated one then the
# human's dismissal of it.
def recheck_sequence_errors:
  [ [.[] | objects] | group_by(.entry_sha256)[] | map(.status)
    | if . == ["escalated", "dismissed"] then empty
      elif length > 1 then failure("rechecks"; "an entry is re-checked more than once")
      elif .[0] == "dismissed" then failure("rechecks"; "a dismissal follows its entry's escalated re-check")
      else empty end ];

def recheck_sidecar_errors($plan_id):
  if type != "object" then [failure("(root)"; "expected a JSON object")]
  else
    object_key_errors(""; ["schema_version", "plan", "rechecks"]; []) as $keys
    | guarded($keys;
        (if .schema_version == "1.0" then [] else [failure("schema_version"; "must be \"1.0\"")] end)
        + (if .plan == $plan_id then [] else [failure("plan"; "names a different plan than the one rendered")] end)
        + (.rechecks | each_item_errors("rechecks"; 0; .path as $p | .value | sidecar_recheck_errors($p)))
        + (if (.rechecks | type) == "array" then .rechecks | recheck_sequence_errors else [] end))
  end;

def name_errors:
  [ .tests | map(.name) | duplicate_positions[]
    | failure(item_path("tests"; .index) + ".name"; "duplicate of tests[\(.first)].name") ];

def behavior_id_unique_errors:
  (.behaviors | map(.id)) as $ids
  | [ $ids | duplicate_positions[]
      | failure(item_path("behaviors"; .index) + ".id"; "duplicate behavior id \($ids[.index]) (also behaviors[\(.first)])") ];

def guards_errors:
  (.behaviors | map(.id)) as $known
  | [ .tests | to_entries[] | .key as $t | .value.guards as $ids
      | (item_path("tests"; $t) + ".guards") as $guards_path
      | ( (range(0; $ids | length) as $g
           | select($ids[$g] | member($known) | not)
           | failure(item_path($guards_path; $g); "unknown behavior id \($ids[$g])")),
          ($ids | duplicate_positions[]
           | failure(item_path($guards_path; .index); "duplicate behavior id \($ids[.index])")) ) ];

# Only a test that will be written guards a behavior: an optional unit test
# is offered, not planned, until the human accepts it.
def coverage_errors:
  ([.tests[] | select(.unit_kind != "optional") | .guards[]] | unique) as $guarded
  | ([.tests[].guards[]] | unique) as $offered
  | [ .behaviors | to_entries[] | select(.value.id | member($guarded) | not)
      | if (.value.id | member($offered)) then failure(item_path("behaviors"; .key); "guarded only by an optional unit test")
        else failure(item_path("behaviors"; .key); "\(.value.id) is not guarded by any test") end ];

def redundancy_errors:
  [ .tests | map({level, guard_set: (.guards | unique)}) | duplicate_positions[]
    | failure(item_path("tests"; .index); "same level and same guarded behaviors as tests[\(.first)] (redundant)") ];

def level_reason_errors:
  present_iff_errors(""; "no_e2e_reason"; (has_level("e2e") | not); "no test is end-to-end")
  + present_iff_errors(""; "no_unit_reason"; (has_level("unit") | not); "no test is a unit test");

# Every file a test writes or reads — its file, input and golden — must be
# one the plan declares.
def path_listing_errors:
  ((.files.existing) + (.files.new | map(.path))) as $listed
  | [ .tests | to_entries[] | .key as $t | .value
      | (["file", .file], (select(has("input")) | ["input.path", .input.path]), (select(has("golden")) | ["golden.path", .golden.path]))
      | select(.[1] | member($listed) | not)
      | failure(item_path("tests"; $t) + "." + .[0]; "path \(.[1]) is not listed in files.existing or files.new[].path") ];

def existing_file_errors:
  .files.existing as $existing
  | [ ("repair", "delete") as $list
      | .existing_tests[$list] | to_entries[] | select(.value.file | member($existing) | not)
      | failure(item_path("existing_tests." + $list; .key) + ".file"; "path \(.value.file) is not listed in files.existing") ];

def change_file_unique_errors:
  [ (.change.files // []) | duplicate_positions[]
    | failure(item_path("change.files"; .index); "duplicate of change.files[\(.first)]") ];

def path_unique_errors:
  ( [ .files.existing | to_entries[] | {path: item_path("files.existing"; .key), value} ]
    + [ .files.new | to_entries[] | {path: (item_path("files.new"; .key) + ".path"), value: .value.path} ]
  ) as $entries
  | [ $entries | map(.value) | duplicate_positions[]
      | failure($entries[.index].path; "duplicate path \($entries[.index].value) (also \($entries[.first].path))") ];

def body_rule_errors:
  numbering_errors + name_errors + behavior_id_unique_errors + guards_errors
  + coverage_errors + redundancy_errors + level_reason_errors
  + path_listing_errors + existing_file_errors + path_unique_errors
  + change_file_unique_errors;

def amended_tests($amendments; $actions):
  [ $amendments[] | select(.action | member($actions)) | select(has("test")) | .test ];

# "accepted" is the human opting in to an optional unit test, so it must be
# recorded by an accepted amendment naming the test.
def accepted_errors($amendments):
  amended_tests($amendments; ["accepted"]) as $accepted
  | [ .tests | to_entries[] | select(.value.unit_kind == "accepted")
      | select(.value.name | member($accepted) | not)
      | failure(item_path("tests"; .key) + ".unit_kind"; "accepted requires an amendment with action accepted and test \(.value.name)") ];

# Every body section a challenge or an amend changes (compared with the stored
# plan) is named by the field of one of $entries, so no change reaches the
# human unannounced.
#
# change.files given for a plan stored without it is not a change to record:
# every write requires it, so the first write to such a plan supplies it
# whether or not the plan changed.
def unrecorded_field_errors($stored_plan; $entries; $where):
  ($stored_plan | .not_tested |= map(del(.waived_by_human, .waiver_reason))) as $stored
  | (if $stored.change | has("files") then . else del(.change.files) end) as $new
  | ([ $entries[] | select(has("field")) | .field ]) as $recorded
  | [ recordable_fields[] | select($new[.] != $stored[.]) | select(member($recorded) | not)
      | failure(.; "changed, but no \($where) entry has field \"\(.)\"") ];

# Every stored test a challenge or an amend changes (matched by name,
# ignoring n) is named by the test of one of $entries.
def unrecorded_test_errors($stored; $entries; $where):
  ($stored.tests | map({(.name): del(.n)}) | add // {}) as $before
  | [ $entries[] | select(has("test")) | .test ] as $named
  | [ .tests | to_entries[]
      | select($before[.value.name] != null and $before[.value.name] != (.value | del(.n)))
      | select(.value.name | member($named) | not)
      | failure(item_path("tests"; .key); "\(.value.name) changed, but no \($where) entry has test \"\(.value.name)\"") ];

# Every draft test a challenge leaves out of tests[] is rejected, or named by
# the test of a reviewer.changes entry (merged away, say).
def dropped_draft_test_errors($stored):
  (.tests | map(.name)) as $kept
  | (.reviewer.rejected | map(.test.name)) as $rejected
  | [ .reviewer.changes[] | select(has("test")) | .test ] as $named
  | [ $stored.tests[].name
      | select(member($kept) or member($rejected) or member($named) | not)
      | failure("tests"; "draft test \"\(.)\" was dropped without being rejected or recorded in reviewer.changes") ];

# The reviewer's verdict covers every test exactly once: each current test is
# approved by the reviewer, or was put back (restored) or added by an
# amendment; each approved name is a current test or was removed by one; and
# a rejected test is back in tests[] only through a restored amendment.
# An added amendment's renamed_from names a test an earlier removed
# amendment records, so a rename always pairs two recorded changes.
def renamed_from_errors($amendments):
  [ $amendments | to_entries[] | .key as $index | .value
    | select(has("renamed_from")) | .renamed_from as $old
    | select(any($amendments[:$index][]; .action == "removed" and .test == $old) | not)
    | failure(item_path("amendments"; $index) + ".renamed_from"; "\($old) is not named by an earlier removed amendment (a rename records the old name as removed first)") ];

def review_rule_errors($amendments):
  (.tests | map(.name)) as $tests
  | (.reviewer.approved | map(.name)) as $approved
  | (.reviewer.rejected | map(.test.name)) as $rejected
  | amended_tests($amendments; ["restored", "added"]) as $restored_or_added
  | amended_tests($amendments; ["restored"]) as $restored
  | amended_tests($amendments; ["removed"]) as $removed
  | [ $approved | duplicate_positions[]
      | failure(item_path("reviewer.approved"; .index) + ".name"; "duplicate of reviewer.approved[\(.first)].name") ]
    + [ $tests | to_entries[]
        | select((.value | member($approved)) or (.value | member($restored_or_added)) | not)
        | failure(item_path("tests"; .key) + ".name"; "\(.value) is not in reviewer.approved and no restored or added amendment names it") ]
    + [ $approved | to_entries[]
        | select((.value | member($tests)) or (.value | member($removed)) | not)
        | failure(item_path("reviewer.approved"; .key) + ".name"; "\(.value) is not in tests[] and no removed amendment names it") ]
    + [ $rejected | duplicate_positions[]
        | failure(item_path("reviewer.rejected"; .index) + ".test.name"; "duplicate of reviewer.rejected[\(.first)].test.name") ]
    + [ $rejected | to_entries[]
        | select((.value | member($tests)) and (.value | member($restored) | not))
        | failure(item_path("reviewer.rejected"; .key) + ".test.name"; "\(.value) is in tests[] but no restored amendment names it") ]
    + (has_level("e2e") as $has_e2e
       | .reviewer | present_iff_errors("reviewer"; "no_e2e_agreed"; ($has_e2e | not); "no test is end-to-end"));

# --- body assembly -------------------------------------------------------------

# The body sections every writer stores, in schema order, rebuilt key by key
# from an already-validated $source (so no stray key can ride along); an
# optional key is carried only when present. n and approx_lines are floored:
# validation has already rejected a fraction, so this only turns an integral
# float (3.0) into 3.
def plan_body($source):
  def optional_key($key): if has($key) then {($key): .[$key]} else {} end;
  $source
  | {change, run}
    + optional_key("builds_on")
    + {behaviors, existing_tests, tests: (.tests | map(.n |= floor))}
    + optional_key("no_e2e_reason")
    + optional_key("no_unit_reason")
    + {not_tested, files, approx_lines: (.approx_lines | floor)};

# --- diff scope (write-only) ----------------------------------------------------

# The --diff-files parse: diff-files.txt (one path per line) or
# diff-files.tsv (path<TAB>blob-sha per line). The same parse lives in
# flow-review's review-aggregates.jq: each flow loads only the libs under its
# own scripts/ directory, so the two copies change together.

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

# The paths of a diff_file_list result, whichever form it holds.
def diff_file_paths: map(if type == "object" then .path else . end);

# Directory names that only a test tree uses, matched exactly
# (case-sensitive) at any depth: __tests__/, Go's testdata/, and a .NET test
# project such as MyApp.Tests/ or MyApp.Test/.
def is_dedicated_test_directory:
  member(["__tests__", "__mocks__", "__fixtures__", "__snapshots__", "testdata"])
  or test("\\A[^/]+\\.Tests?\\z");

# Directory names a production package can also carry (django/test/,
# lib/fixtures/), so they mark a test tree only at a test root: the first
# segment (tests/, spec/) or directly under a src segment (src/test/,
# app/src/test/).
def generic_test_directories:
  ["test", "tests", "spec", "specs", "fixtures", "golden", "goldens"];

# A test file by an explicit test-file token in its name — a token a
# production file does not carry by accident:
#   foo_test.go, foo_test.rs, foo_test.py   (_test.)
#   foo.test.ts, foo.spec.ts, a.cy.ts       (.test. / .spec. / Cypress .cy.)
#   user_spec.rb                            (_spec.)
#   test_foo.py                             (test_ prefix)
#   FooTest.java, FooTests.java, FooIT.java, FooTest.kt, FooTests.kt,
#   FooTest.php, FooTest.cs, FooTests.cs, FooTests.swift,
#   FooSpec.kt, FooSpec.scala               (xUnit-style class suffix)
# A bare "spec" or "Spec" elsewhere (src/spec.rs, OrderSpec.java) is not a
# token.
def is_test_file_name:
  test("\\A[^/]+(_test|\\.test|\\.spec|\\.cy|_spec)\\.[^/]+\\z")
  or test("\\Atest_[^/]+\\.[^/]+\\z")
  or test("\\A[A-Za-z0-9_]+(Tests?\\.(java|kt|cs)|IT\\.java|Test\\.php|Tests\\.swift|Spec\\.(kt|scala))\\z");

# A test or test-data file: a path with a test marker and no "main"
# directory segment before that marker (src/main/... is production in a
# Maven or Gradle layout, whatever sits below it). The marker is the first
# directory segment that is a dedicated test directory anywhere, or a generic
# test directory at a test root (first segment, or right after "src"); else
# a file name with a test-file token. So:
#   tests/x_test.go, spec/models/user_spec.rb, src/test/java/FooTest.java,
#   MyApp.Tests/OrderTests.cs, cypress/e2e/a.cy.ts           test paths
#   src/main/java/org/x/test/Helper.java, django/test/client.py,
#   src/domain/OrderSpec.java                                not test paths
def is_test_path:
  split("/") as $segments
  | ($segments | length - 1) as $file_index
  | [ range(0; $file_index) as $i
      | $segments[$i] as $segment
      | select(($segment | is_dedicated_test_directory)
               or (($segment | member(generic_test_directories))
                   and ($i == 0 or $segments[$i - 1] == "src")))
      | $i ] as $test_directory_indexes
  | (if $test_directory_indexes != [] then $test_directory_indexes[0]
     elif ($segments[$file_index] | is_test_file_name) then $file_index
     else null end) as $marker_index
  | $marker_index != null and ("main" | member($segments[:$marker_index]) | not);

# Every file the plan tests is in the diff, and every file it edits or adds
# is in the diff or is a test or test-data file: a production file outside
# the diff is never tested, touched or created.
def diff_scope_errors($diff_files):
  (reduce ($diff_files | diff_file_paths)[] as $path ({}; .[$path] = true)) as $in_diff
  | def outside_production($path): $in_diff[$path] != true and ($path | is_test_path | not);
  [ .change.files | to_entries[] | select($in_diff[.value] != true)
      | failure(item_path("change.files"; .key); "\(.value) is not in the diff (--diff-files); a plan tests only files the diff changed") ]
    + [ .files.existing | to_entries[] | select(outside_production(.value))
        | failure(item_path("files.existing"; .key); "production file \(.value) is not in the diff (--diff-files); outside it a plan may touch only test or test-data files") ]
    + [ .files.new | to_entries[] | select(outside_production(.value.path))
        | failure(item_path("files.new"; .key) + ".path"; "production file \(.value.path) is not in the diff (--diff-files); outside it a plan may add only test or test-data files") ];

# Every repo path a plan names, as "<field path><TAB><path>" lines: the paths
# each writer resolves under --repo-root, refusing a symlink on the way or a
# location outside the repo. Run only on a validated plan, whose paths are
# single-line, tab-free and repo-relative.
def plan_repo_path_lines:
  (.change.files | to_entries[] | item_path("change.files"; .key) + "\t" + .value),
  (.files.existing | to_entries[] | item_path("files.existing"; .key) + "\t" + .value),
  (.files.new | to_entries[] | item_path("files.new"; .key) + ".path\t" + .value.path);

# --- approved baseline -----------------------------------------------------------

# approved_baseline: the fingerprint of the plan as it was last approved,
# recorded by test-plan-amend.sh when it amends an approved plan, kept by a
# later amend, and removed by approval. It lets render-md.sh show what an
# amendment changed since approval: the amendments cannot tell it (they also
# hold the changes made before approval, and one item can be added and then
# changed), so the delta is a comparison of two fingerprints. A
# fingerprint is {name, sha256}: the SHA-256 of the entry as `jq -S -c`
# prints it (the shell computes it: jq has no hash) — a test without n, so a
# test renumbered by an insertion before it is unchanged, and a reused,
# repair or delete entry whole. An entry is matched by name: equal digest,
# unchanged; same name, changed; else new. It also counts the amendments the
# approved plan held, so the render can list only the later ones.
#
# sections fingerprints the rest of what the render shows, so the change
# view can leave out every section the amendment left as approved: each
# Files and Fixtures entry (by path, as the render lists it: its new-file
# kind and inline-unit mark, the role it is listed under taken from the
# list it sits in), each builds_on line (by itself), each behavior (by id)
# and each not_tested entry (by what, waiver included), plus one digest
# each of run, the whole existing_tests, the reviewer lines the render shows
# and the rejected proposals it lists (without their shifting numbers). A
# baseline recorded before sections existed has none, and the render then
# shows those sections whole.
def baseline_lists: ["reused", "repair", "delete"];
def baseline_section_lists: ["files", "fixtures", "builds_on", "behaviors", "not_tested"];
def baseline_section_digests: ["run", "existing_tests", "reviewer", "rejected"];

# Where each listed file is shown. An input a test reads, and every new
# fixture file (a golden included), is a fixture; a file named only by a
# repair or delete entry is shown on that entry; every other file is listed
# under Files — the files the tests live in, existing goldens, and new
# harnesses. inline_units marks a unit test written into the source file it
# tests.
def file_roles:
  [.tests[].file] as $test_files
  | [.tests[] | .golden // empty | .path] as $goldens
  | ([.tests[] | .input // empty | .path] - $test_files - $goldens) as $inputs
  | [.tests[] | select(.level == "unit") | .file] as $unit_files
  | [.tests[] | select(.level == "e2e") | .file] as $e2e_files
  | ([.existing_tests.repair[], .existing_tests.delete[] | .file] - $test_files - $goldens - $inputs) as $entry_only
  | [ (.files.existing[] | {path: ., new: null}), (.files.new[] | {path, new: .kind}) ]
  | map(.path as $path
        | . + {role: (if ($path | member($inputs)) or .new == "fixture" then "fixture"
                      elif .new == null and ($path | member($entry_only)) then "entry"
                      else "file" end),
               inline_units: (.new == null and ($path | member($unit_files)) and ($path | member($e2e_files) | not)
                              and ($path | is_test_path | not))});

# The reviewer lines and rejected proposals as the render shows them.
def shown_reviewer: .reviewer // null | if . == null then null else {approved: [.approved[].name], changes, no_e2e_agreed} end;
def shown_rejected_entries: [shown_rejected[] | {name: .test.name, level: .test.level, guards: .test.guards, reason}];

# Each entry a fingerprint covers, in fingerprint order: the tests, the
# reused, repair and delete entries, then the sections' entries and digests.
def baseline_entries:
  (.tests[] | {list: "tests", name, value: del(.n)}),
  (baseline_lists[] as $list | .existing_tests[$list][] | {list: $list, name, value: .}),
  (file_roles[] | select(.role != "entry")
   | {list: (if .role == "fixture" then "fixtures" else "files" end), name: .path, value: {path, new, inline_units}}),
  ((.builds_on // [])[] | {list: "builds_on", name: ., value: .}),
  (.behaviors[] | {list: "behaviors", name: .id, value: .}),
  (.not_tested[] | {list: "not_tested", name: .what, value: .}),
  {list: "run", value: .run},
  {list: "existing_tests", value: .existing_tests},
  {list: "reviewer", value: shown_reviewer},
  {list: "rejected", value: shown_rejected_entries};
def baseline_digest_inputs: baseline_entries | .value;

# The plan's fingerprints, $digests being the SHA-256 of each
# baseline_digest_inputs line in order.
def baseline_fingerprints($digests):
  [baseline_entries] as $entries
  | if ($digests | length) != ($entries | length) then error("baseline_fingerprints: \($digests | length) digests for \($entries | length) entries")
    else
      reduce range(0; $entries | length) as $i (
        {tests: [], existing_tests: {reused: [], repair: [], delete: []},
         sections: {files: [], fixtures: [], builds_on: [], behaviors: [], not_tested: []}};
        $entries[$i].list as $list
        | {name: $entries[$i].name, sha256: $digests[$i]} as $fingerprint
        | if $list == "tests" then .tests += [$fingerprint]
          elif $list | member(baseline_lists) then .existing_tests[$list] += [$fingerprint]
          elif $list | member(baseline_section_lists) then .sections[$list] += [$fingerprint]
          else .sections[$list] = $digests[$i] end)
    end;

# amendments is how many amendments the approved plan held, so the render
# can tell the amendments made since approval from the earlier ones.
def approved_baseline($digests):
  {approved_at, amendments: ((.amendments // []) | length)} + baseline_fingerprints($digests);

# The approved_baseline an amend of this stored plan records: a fresh one
# when it is approved ($digests its baseline_digest_inputs digests), the one
# it holds when it is challenged and already carries one (a second amend
# before re-approval still compares with the approved plan), else none.
def approved_baseline_after_amend($digests):
  if .status == "approved" then {approved_baseline: approved_baseline($digests)}
  elif has("approved_baseline") then {approved_baseline}
  else {} end;

def sha256_errors($path):
  if is_sha256_text then [] else [failure($path; "must be 64 lowercase hex digits (the SHA-256 of the entry)")] end;

# A fingerprint names its entry as the plan does: a test or existing-test
# name, a path, a builds_on line, a behavior id or a not_tested what.
def fingerprint_name_errors($kind; $path):
  if $kind == "path" then path_errors($path)
  elif $kind == "behavior" then behavior_id_errors($path)
  elif $kind == "text" then text_errors($path)
  else code_errors($path) end;

def fingerprint_errors($path; $kind):
  object_key_errors($path; ["name", "sha256"]; []) as $keys
  | guarded($keys;
      (.name | fingerprint_name_errors($kind; field_path($path; "name")))
      + (.sha256 | sha256_errors(field_path($path; "sha256"))));

def fingerprint_list_errors($path; $min_items; $kind):
  each_item_errors($path; $min_items; .path as $p | .value | fingerprint_errors($p; $kind));

def section_name_kind: {files: "path", fixtures: "path", builds_on: "code", behaviors: "behavior", not_tested: "text"}[.];

def baseline_sections_errors:
  object_key_errors("approved_baseline.sections"; baseline_section_lists + baseline_section_digests; []) as $keys
  | guarded($keys;
      [ (baseline_section_lists[] as $list
         | .[$list] | fingerprint_list_errors("approved_baseline.sections." + $list; 0; $list | section_name_kind)[]),
        (baseline_section_digests[] as $key
         | .[$key] | sha256_errors("approved_baseline.sections." + $key)[]) ]);

def approved_baseline_errors:
  .approved_baseline
  | object_key_errors("approved_baseline"; ["approved_at", "amendments", "tests", "existing_tests"]; ["sections"]) as $keys
  | guarded($keys;
      (.approved_at | date_errors("approved_baseline.approved_at"))
      + (.amendments | if type == "number" and . == floor and . >= 0 then []
                       else [failure("approved_baseline.amendments"; "must be an integer >= 0")] end)
      + (.tests | fingerprint_list_errors("approved_baseline.tests"; 1; "code"))
      + (.existing_tests
         | object_key_errors("approved_baseline.existing_tests"; baseline_lists; []) as $list_keys
         | guarded($list_keys;
             [ baseline_lists[] as $list
               | .[$list] | fingerprint_list_errors("approved_baseline.existing_tests." + $list; 0; "code")[] ]))
      + optional_errors("sections"; baseline_sections_errors));

# The amendments the approved plan held are still the first ones the plan
# holds: an amend only appends.
def approved_baseline_rule_errors:
  if has("approved_baseline") and .approved_baseline.amendments > ((.amendments // []) | length)
  then [failure("approved_baseline.amendments"; "is \(.approved_baseline.amendments), more than the \((.amendments // []) | length) amendments the plan holds")]
  else [] end;

# --- entry points --------------------------------------------------------------

def input_kind_label($kind):
  {create: "a create fields-file", challenge: "a challenge fields-file", amend: "an amend fields-file"}[$kind];

# The one after-challenge key each input kind must carry (none for create).
def input_list_keys($kind):
  {create: [], challenge: ["reviewer"], amend: ["amendments"]}[$kind];

# Keys an input kind may carry beyond the body and its list key (an amend's
# no_e2e_agreed: flow-testing §3d).
def input_optional_keys($kind):
  {create: [], challenge: [], amend: ["no_e2e_agreed"]}[$kind];

# The no_e2e_agreed rules of flow-testing §3d: what the fields-file alone
# decides, what needs the stored plan, and the reviewer they produce.
def amend_agreement_shape_errors:
  if has("no_e2e_agreed") | not then []
  elif has_level("e2e") then [failure("no_e2e_agreed"; "must be absent when the amended plan has an end-to-end test (the amend clears the reviewer's agreement)")]
  else (.no_e2e_agreed | text_errors("no_e2e_agreed")) end;

def amend_agreement_errors($stored):
  if has_level("e2e") or has("no_e2e_agreed") or ($stored | has_level("e2e") | not) then []
  else [failure("no_e2e_agreed"; "required when the amend removes the last end-to-end test (the reviewer's agreement — flow-testing §3d)")] end;

def amended_reviewer($fields):
  (.reviewer | del(.no_e2e_agreed))
  + (if ($fields | has_level("e2e")) then {}
     elif ($fields | has("no_e2e_agreed")) then {no_e2e_agreed: $fields.no_e2e_agreed}
     elif (.reviewer | has("no_e2e_agreed")) then {no_e2e_agreed: .reviewer.no_e2e_agreed}
     else {} end);

def input_key_errors($kind):
  input_list_keys($kind) as $list_keys
  | [ keys_unsorted[] as $key
      | ($key | shown_key) as $shown
      | if ($key | member(stamped_keys + diff_scope_keys + baseline_keys)) then failure($shown; "stamped by the script; must not appear in " + input_kind_label($kind))
        elif ($key | member(after_challenge_keys)) and ($key | member($list_keys) | not) then
          failure($shown; "must not appear in " + input_kind_label($kind))
        elif ($key | member(body_required_keys + body_optional_keys + $list_keys + input_optional_keys($kind)) | not) then failure($shown; "unknown field")
        else empty end ]
  + [ (body_required_keys + $list_keys)[] as $key | select(has($key) | not) | failure($key; "required field missing") ];

def plan_input_errors($kind; $diff_files):
  if type != "object" then [failure("(root)"; "expected a JSON object")]
  else
    input_key_errors($kind) as $keys
    | if $keys != [] then $keys
      else
        ( body_shape_errors
          + change_files_presence_errors
          + (if $kind == "challenge" then reviewer_shape_errors
             elif $kind == "amend" then amendments_shape_errors
             else [] end)
        ) as $shape
        | if $shape != [] then $shape
          else
            body_rule_errors
            + level_order_errors
            + not_tested_write_errors
            + (if $kind == "amend" then amend_agreement_shape_errors else accepted_errors([]) end)
            + (if $kind == "challenge" then review_rule_errors([]) else [] end)
            + diff_scope_errors($diff_files)
          end
      end
  end;

def challenge_input_errors($stored; $diff_files):
  plan_input_errors("challenge"; $diff_files) as $errors
  | if $errors != [] then $errors
    else
      unrecorded_field_errors($stored; .reviewer.changes; "reviewer.changes")
      + unrecorded_test_errors($stored; .reviewer.changes; "reviewer.changes")
      + dropped_draft_test_errors($stored)
    end;

# A removed amendment with field not_tested names, by item, the what of a
# stored entry the amended plan no longer holds.
def removed_not_tested_errors($stored):
  (.not_tested | map(.what)) as $kept
  | ($stored.not_tested | map(.what)) as $before
  | [ .amendments | to_entries[] | select(.value | is_not_tested_removal)
      | select((.value.item | member($before) | not) or (.value.item | member($kept)))
      | failure(item_path("amendments"; .key) + ".item";
          "names no not_tested entry this amend removes (the what of a stored entry the amended plan no longer holds)") ];

def amend_input_errors($stored; $diff_files):
  plan_input_errors("amend"; $diff_files) as $errors
  | if $errors != [] then $errors
    else
      amend_agreement_errors($stored)
      + unrecorded_field_errors($stored; .amendments; "amendments")
      + unrecorded_test_errors($stored; .amendments; "amendments")
      + removed_not_tested_errors($stored)
    end;

# Every stamped key except approved_at (which only an approved plan carries),
# plus the required body.
def document_key_errors:
  [ keys_unsorted[] as $key
    | select($key | member(stamped_keys + diff_scope_keys + baseline_keys + body_required_keys + body_optional_keys + after_challenge_keys) | not)
    | failure($key | shown_key; "unknown field") ]
  + [ ((stamped_keys - ["approved_at"]) + body_required_keys)[] as $key
      | select(has($key) | not) | failure($key; "required field missing") ];

def stamped_field_errors:
  (if .schema_version == "1.0" then [] else [failure("schema_version"; "must be \"1.0\"")] end)
  + (.id | slug_errors("id"))
  + (.status | enum_errors("status"; statuses))
  + (.created | date_errors("created"));

# Which optional keys each status carries (lifecycle SEMANTICS: flow-testing
# §3). Run only once status is known to be valid.
def status_lifecycle_errors:
  present_iff_errors(""; "approved_at"; (.status == "approved"); "status is approved")
  + optional_errors("approved_at"; date_errors("approved_at"))
  + present_iff_errors(""; "reviewer"; (.status != "draft"); "status is challenged or approved")
  + (if .status == "draft" and has("amendments") then [failure("amendments"; "must be absent while status is draft")] else [] end)
  + (if .status != "challenged" and has("approved_baseline")
     then [failure("approved_baseline"; "must be absent unless status is challenged (an amend of an approved plan records it; approval removes it)")]
     else [] end);

def plan_document_errors:
  if type != "object" then [failure("(root)"; "expected a JSON object")]
  else
    document_key_errors as $keys
    | if $keys != [] then $keys
      else
        ( stamped_field_errors
          + (if (.status | enum_errors("status"; statuses)) == [] then status_lifecycle_errors else [] end)
          + optional_errors("diff_files"; diff_files_errors)
          + optional_errors("snapshot"; snapshot_errors("snapshot"))
          + (if has("approved_baseline") then approved_baseline_errors else [] end)
          + body_shape_errors
          + (if has("reviewer") then reviewer_shape_errors else [] end)
          + (if has("amendments") then amendments_shape_errors else [] end)
        ) as $shape
        | if $shape != [] then $shape
          else
            (.amendments // []) as $amendments
            | body_rule_errors
              + approved_baseline_rule_errors
              + accepted_errors($amendments)
              + renamed_from_errors($amendments)
              + (if has("reviewer") then review_rule_errors($amendments) else [] end)
          end
      end
  end;
