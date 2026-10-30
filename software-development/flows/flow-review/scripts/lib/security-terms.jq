# security-terms.jq — the ONE matcher deciding whether a text names a
# security weakness or a security subject, from the word lists of
# contracts/review-category.schema.json (x-security-terms, x-security-patterns
# and the x-* lists beside them, whose description states the rules).
# flow-review's writers and flow-testing's test-plan writers both load this
# file from flow-review/scripts/lib, so a review finding and a test-plan
# exclusion are judged by the same words.
#
# A jq module: a caller includes it with a pinned `search`, and it imports
# review-categories.json (the contract's copy) from its own directory
# (`search: "./"`), never from the process's working directory. Nothing here touches a file, takes a $-argument, or has a side effect.
#
# The text is read lowercase, as sentences (split at . ; : ! ? and line
# breaks) of clauses (split further at , and a closing parenthesis) of words.
# A backtick code span quotes code rather than making a claim, so its words
# are skipped; only a "../" or "..\" in it reads as the word __dotdot__, and
# an == or != as __eq__, as they do outside one. Any run of characters other
# than a letter, a digit or "_" separates words, and an identifier holding
# "_" (csrf_token) is one word.

import "review-categories" as $review_categories {search: "./"};

def review_category_data: $review_categories::review_categories[0];

def security_terms: review_category_data["x-security-terms"];
def security_mechanism_words: review_category_data["x-security-mechanism-words"];
def security_negation_words: review_category_data["x-security-negation-words"];
def injection_kinds: review_category_data["x-injection-kinds"];
def dependency_injection_words: review_category_data["x-dependency-injection-words"];
def access_subjects: review_category_data["x-access-subjects"];
def bypass_prefixes: review_category_data["x-bypass-prefixes"];
def test_security_subjects: review_category_data["x-test-security-subjects"];
def security_pattern($name): review_category_data["x-security-patterns"][$name];
def injection_reach: 3;

def code_span_marks:
  (if test("\\.\\.[/\\\\]") then " __dotdot__" else "" end)
  + (if test("[!=]=") then " __eq__" else "" end);

def security_text_sentences:
  gsub("`(?<code>[^`]*)`"; (.code | code_span_marks) + " ")
  | ascii_downcase
  | gsub("\\.\\.[/\\\\]"; " __dotdot__ ")
  | gsub("[!=]=+"; " __eq__ ")
  | [splits("[.;:!?\\n\\r]+")
     | [splits("[,)]+") | [splits("[^a-z0-9_]+") | select(length > 0)] | select(length > 0)]
     | select(length > 0)];

def security_text_clauses: [security_text_sentences[][]];

def term_word_list: ascii_downcase | [splits("[^a-z0-9]+")] | map(select(length > 0));

def is_word_or_plural($word): . == $word or . == $word + "s";
def is_mechanism_word:
  . as $word | any(security_mechanism_words[]; . as $mechanism | $word | is_word_or_plural($mechanism));
def is_negation_word: IN(security_negation_words[]);
def starts_with_any($prefixes): . as $word | any($prefixes[]; . as $prefix | $word | startswith($prefix));

# A word set is {prefixes, words, phrases}, each optional.
def in_word_set($set):
  . as $word
  | any(($set.words // [])[]; . == $word) or starts_with_any($set.prefixes // []);
def has_word_in($words; $set): any($words[]; in_word_set($set));
def has_pattern_word($words; $name): has_word_in($words; security_pattern($name));

# Whether $term_words run on from $words[$i], the last one possibly plural.
def words_match_at($words; $i; $term_words):
  ($term_words | length) as $n
  | all(range(0; $n); . as $j
        | ($words[$i + $j] // "") as $word
        | if $j == $n - 1 then $word | is_word_or_plural($term_words[$j]) else $word == $term_words[$j] end);

def term_spans($words; $term_words):
  range(0; $words | length) | select(words_match_at($words; .; $term_words));

# A negation or absence word anywhere in the clause outside $words[$from..$to].
def has_negation_outside($words; $from; $to):
  any(range(0; $words | length) | select(. < $from or . > $to); $words[.] | is_negation_word);

# A weakness named at $words[$start..$end] names its mechanism instead when a
# mechanism word follows it directly (csrf token, sql injection prevention),
# unless the clause also holds a negation or absence word: "missing csrf
# protection" and "xss filter can be bypassed" report the weakness, so the
# exemption never lets a fail-open finding through.
def names_mechanism($words; $start; $end):
  ($words[$end + 1] // "" | is_mechanism_word)
  and (has_negation_outside($words; $start; $end + 1) | not);

def named_term($words):
  security_terms[] as $term
  | ($term | term_word_list) as $term_words
  | first(term_spans($words; $term_words) as $i
          | select(names_mechanism($words; $i; $i + ($term_words | length) - 1) | not)
          | $term);

# "injection" names a weakness within injection_reach words of an injection
# kind, on either side ("injection (SQL)"), but never after a word naming a
# dependency-injection style ("constructor injection of the log service").
def named_injection($words):
  first(range(0; $words | length) as $i
        | select($words[$i] | is_word_or_plural("injection"))
        | select($i == 0 or ($words[$i - 1] | IN(dependency_injection_words[]) | not))
        | range([$i - injection_reach, 0] | max; [$i + injection_reach + 1, ($words | length)] | min) as $k
        | select($words[$k] | IN(injection_kinds[]))
        | select(names_mechanism($words; [$i, $k] | min; $i) | not)
        | "\($words[$k]) injection");

# Each place $subjects (prefixes, words, phrases) is named, as
# {start, end, name}.
def subject_spans($words; $subjects):
  range(0; $words | length) as $i
  | $words[$i] as $word
  | (select($word | in_word_set($subjects)) | {start: $i, end: $i, name: $word}),
    (($subjects.phrases // [])[] as $phrase | ($phrase | term_word_list) as $phrase_words
     | select(words_match_at($words; $i; $phrase_words))
     | {start: $i, end: ($i + ($phrase_words | length) - 1), name: $phrase});

# Whether what an access subject's match at $words[$from..$to] acts on is a
# performance thing (the redundant permission lookup, the cache bypassing
# its eviction) and nothing in the clause speaks of lost access. The words
# looked at run from the subordinator before the match to the one after it,
# so "skipped when the cache is warm" is not read as a cache being skipped.
def performance_object($words; $from; $to):
  security_pattern("clause-subordinators") as $subordinators
  | ([range(0; $from) | select($words[.] | IN($subordinators[]))] | max // -1) as $start
  | ([range($to + 1; $words | length) | select($words[.] | IN($subordinators[]))] | min // ($words | length)) as $end
  | has_word_in($words[$start + 1:$end]; security_pattern("performance-objects"))
    and (has_pattern_word($words; "access-loss") | not);

# An access subject and a bypass word anywhere in one clause
# ("authentication can be bypassed", "permission check skipped"), under the
# same mechanism rule ("auth bypass prevention" names a mechanism).
def named_access_bypass($words):
  first(subject_spans($words; access_subjects) as $subject
        | range(0; $words | length) as $j
        | select($j < $subject.start or $j > $subject.end)
        | $words[$j] as $bypass
        | select($bypass | starts_with_any(bypass_prefixes))
        | ([$subject.start, $j] | min) as $from
        | ([$subject.end, $j] | max) as $to
        | select(names_mechanism($words; $from; $to) | not)
        | select(performance_object($words; $from; $to) | not)
        | if $j < $subject.start then "\($bypass) \($subject.name)" else "\($subject.name) \($bypass)" end);

# An access subject followed by a mechanism word, with a negation or absence
# word in its clause ("no authorization check", "password check is skipped").
def named_missing_access_control($words):
  first(subject_spans($words; access_subjects) as $subject
        | select($words[$subject.end + 1] // "" | is_mechanism_word)
        | select(has_negation_outside($words; $subject.start; $subject.end + 1))
        | select(performance_object($words; $subject.start; $subject.end + 1) | not)
        | "\($subject.name) \($words[$subject.end + 1]) missing");

# An unauthenticated or unauthorized subject that reaches, accesses or calls
# something ("unauthenticated callers can reach the export endpoint").
def named_unauthenticated_reach($words):
  first($words[] | select(in_word_set(security_pattern("unauthenticated"))))
  | select(has_pattern_word($words; "reach"))
  | "\(.) access";

# A "../" with a word of escaping it, or a path joined unnormalized.
def named_path_escape($words):
  select((IN($words[]; "__dotdot__") and has_pattern_word($words; "traversal-escape"))
         or (has_pattern_word($words; "unnormalized") and has_pattern_word($words; "path-nouns")))
  | "path traversal";

# Text concatenated or interpolated into a query, shell or command, or an
# unescaped value in one.
def named_unsafe_sink($words):
  security_pattern("injection-sinks") as $sinks
  | first((range(0; $words | length) as $i
           | select($words[$i] | in_word_set(security_pattern("concatenation")))
           | range($i + 1; $words | length) as $j | select($words[$j] == "into")
           | $words[$j + 1:$j + 4][] | select(in_word_set($sinks))),
          (select(has_pattern_word($words; "unescaped")) | $words[] | select(in_word_set($sinks))))
  | "\(.) injection";

# A secret compared with == or not in constant time.
def named_unsafe_secret_comparison($words):
  select(has_pattern_word($words; "secrets") and has_pattern_word($words; "comparison"))
  | select(IN($words[]; "__eq__")
           or (any(term_spans($words; ["constant", "time"]); true) and has_pattern_word($words; "not-constant-time")))
  | "non-constant-time secret comparison";

# A check that treats a request as authenticated, or defaults or falls back
# to admin ("on a parse error the request is treated as authenticated").
def named_fail_open($words):
  first(range(0; $words | length) as $i
        | $words[$i] as $verb
        | (if $verb | in_word_set(security_pattern("fail-open-as")) then "as"
           elif $verb | in_word_set(security_pattern("fail-open-to")) then "to"
           else empty end) as $link
        | range($i + 1; $words | length) as $j | select($words[$j] == $link)
        | $words[$j + 1:$j + 3][] | select(in_word_set(security_pattern("access-grants")))
        | "fail open: \($verb) \($link) \(.)");

# A revoked user, token or key that keeps or retains its access, in that
# order ("lets a revoked user keep admin access").
def named_revoked_access($words):
  first(range(0; $words | length) as $i | select($words[$i] | in_word_set(security_pattern("revocation")))
        | range($i + 1; $words | length) as $j | select($words[$j] | in_word_set(security_pattern("retention")))
        | $words[$j + 1:][] | select(in_word_set(security_pattern("access-nouns")))
        | "revoked access kept");

# A sentence saying a check only covers authentication while a negation in
# one of its clauses names an authorization object ("only checks that the
# user is logged in, not the admin role").
def named_authentication_only($sentence):
  [$sentence[][]] as $words
  | first(range(0; $words | length) as $i | select($words[$i] == "only")
          | select(has_word_in($words[$i + 1:$i + 3]; security_pattern("check-verbs")))
          | select(has_word_in($words[$i + 1:]; security_pattern("authentication-states")))
          | $sentence[] as $clause
          | range(0; $clause | length) as $k
          | select($clause[$k] != "only" and ($clause[$k] | is_negation_word))
          | select(has_word_in($clause[$k + 1:]; security_pattern("authorization-objects")))
          | "authorization not checked");

def clause_weakness($words):
  named_term($words),
  named_injection($words),
  named_access_bypass($words),
  named_missing_access_control($words),
  named_unauthenticated_reach($words),
  named_path_escape($words),
  named_unsafe_sink($words),
  named_unsafe_secret_comparison($words),
  named_fail_open($words),
  named_revoked_access($words);

# The weakness a text names, or null.
def named_security_term:
  security_text_sentences as $sentences
  | first(($sentences[][] as $words | clause_weakness($words)),
          ($sentences[] as $sentence | named_authentication_only($sentence)))
    // null;

# The security subject a text names, or null — any mention counts, a
# mechanism word after it included (an untested auth check is untested
# security).
def named_security_subject:
  security_text_clauses as $clauses
  | first($clauses[] as $words
          | (subject_spans($words; test_security_subjects) | .name),
            (security_terms[] as $term
             | select(any(term_spans($words; $term | term_word_list); true))
             | $term))
    // null;
