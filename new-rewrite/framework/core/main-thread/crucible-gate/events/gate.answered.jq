# gate.answered: the human's answer to a recorded gate, written by the hook.
# A yes gate holds accept and accepted; a choice gate holds neither.
def one_line: type == "string" and test("\\S") and (test("[\\r\\n]") | not);
.event as $e | $e.body as $b
| (if $e.by == "record-gate-answer.sh" then empty else "gate.answered is written only by record-gate-answer.sh" end),
  ((($b | keys) - ["record", "subject", "question", "accept", "answer", "accepted"])[] | "\(.) is not a gate.answered field"),
  (if ($b.record | type) == "string" and ($b.record | test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$")) then empty else "record must be lowercase words joined by dashes" end),
  (if ($b.subject | type) == "string" then empty else "subject must be a string" end),
  (if $b.question | one_line then empty else "question must be one line" end),
  (if ($b.answer | type) == "string" then empty else "answer must be a string" end),
  (if ($b | has("accept")) != ($b | has("accepted")) then "accept and accepted go together: a yes gate holds both, a choice gate neither"
   elif ($b | has("accept")) | not then empty
   elif ($b.accept | one_line) | not then "accept must be one line"
   elif $b.accepted != ($b.answer == $b.accept) then "accepted must say whether the answer is the accept option"
   else empty end)
