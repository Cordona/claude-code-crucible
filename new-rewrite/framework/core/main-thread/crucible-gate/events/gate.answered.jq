# gate.answered: the human's answer to a recorded gate, written by the hook.
def one_line: type == "string" and test("\\S") and (test("[\\r\\n]") | not);
.event as $e | $e.body as $b
| (if $e.by == "record-gate-answer.sh" then empty else "gate.answered is written only by record-gate-answer.sh" end),
  ((($b | keys) - ["record", "subject", "question", "accept", "answer", "accepted"])[] | "\(.) is not a gate.answered field"),
  (if ($b.record | type) == "string" and ($b.record | test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$")) then empty else "record must be lowercase words joined by dashes" end),
  (if ($b.subject | type) == "string" then empty else "subject must be a string" end),
  (if ($b.question | one_line) and ($b.accept | one_line) then empty else "question and accept must be one line each" end),
  (if ($b.answer | type) == "string" then empty else "answer must be a string" end),
  (if $b.accepted == ($b.answer == $b.accept) then empty else "accepted must say whether the answer is the accept option" end)
