# Shared JSON clean-up for script-written records: a key with nothing in it is
# left out, so a reader treats a missing key as empty.

# prune
#   input:  any JSON value
#   output: the value with every object key whose value is null, [] or {} dropped,
#           children pruned first, so a key left holding only empty keys goes too;
#           array items are pruned but never dropped; false, 0 and "" are kept
def prune:
	if type == "object" then
		with_entries(.value |= prune | select(.value | . != null and . != [] and . != {}))
	elif type == "array" then map(prune)
	else . end;
