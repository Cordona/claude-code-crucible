# spec.approved: a draft the human approved, {sha256, answer}; the answer is
# read by gate-answer.sh, so this rule holds only the shape and used-once.
.event.body as $b
| ((($b | keys) - ["sha256", "answer"])[] | "\(.) is not a spec.approved field"),
  (if ($b.sha256 | type) == "string" and ($b.sha256 | test("^[0-9a-f]{64}$")) then empty else "sha256 must be 64 lowercase hex digits" end),
  (if ($b.answer | type) == "number" then empty else "answer must be the seq of the human's gate.answered" end),
  (if [.prior[] | select(.type == "spec.approved" and .body.answer == $b.answer)] | length > 0
	then "answer \($b.answer) already approved a draft" else empty end)
