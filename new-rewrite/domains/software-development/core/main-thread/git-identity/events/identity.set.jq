# identity.set: the identity the human picked for one repository, written by
# identity-set.sh: {repo, name, email, signing: {format, key}, fingerprint,
# answer}, answer the seq of the human's recorded pick, used once. Whether
# that pick was a recorded choice is identity-set.sh's question to the
# gate's reader; this rule never reads the gate's events.
def one_line: type == "string" and test("\\S") and (test("[\\r\\n]") | not);
.event as $e | $e.body as $b | .prior as $all
| (if $e.by == "identity-set.sh" then empty else "identity.set is written only by identity-set.sh" end),
  ((($b | keys) - ["repo", "name", "email", "signing", "fingerprint", "answer"])[] | "\(.) is not an identity.set field"),
  (if ($b.repo | type) == "string" and ($b.repo | startswith("/")) then empty else "repo must be an absolute folder" end),
  (if $b.name | one_line then empty else "name must be one line" end),
  (if ($b.email | one_line) and ($b.email | test("@")) then empty else "email must be one line holding @" end),
  (if ($b.signing | type) == "object" and (($b.signing | keys) == ["format", "key"])
	and ($b.signing.format == "openpgp" or $b.signing.format == "ssh") and ($b.signing.key | one_line)
   then empty else "signing must be {format: openpgp or ssh, key}" end),
  (if ($b.fingerprint | type) == "string" then empty else "fingerprint must be a string" end),
  (if ($b.answer | type) != "number" then "answer must be the seq of the human's recorded pick"
   elif ([$all[] | select(.type == "identity.set" and .body.answer == $b.answer)] | length) > 0 then "answer \($b.answer) already set an identity"
   else empty end)
