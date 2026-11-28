# agent.initialized: a job agent started with its plugins, written by
# jobs-assign's job-assigned.sh when the agent starts: {agent, base, type,
# plugins}, agent its id, base the base agent, type its agent file's name
# (the base and its plugin set), plugins the skills that file loads. An
# agent starts once; a resumed agent writes no second one.
def one_word: type == "string" and test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$");
.event as $e | $e.body as $b | .prior as $all
| (if $e.by == "job-assigned.sh" then empty else "agent.initialized is written only by job-assigned.sh" end),
  ((($b | keys) - ["agent", "base", "type", "plugins"])[] | "\(.) is not an agent.initialized field"),
  (if ($b.agent | type) == "string" and ($b.agent | test("^[A-Za-z0-9._-]+$")) then empty
   else "agent must be the agent's id: letters, digits, ., _ or -" end),
  (if $b.base | one_word then empty else "base must be the base agent's name" end),
  (if ($b.type | one_word) and (($b.type | startswith(($b.base // "") + "-"))) then empty
   else "type must be the agent file's name, starting with its base and a dash" end),
  (if ($b.plugins | type) == "array" and ($b.plugins | length) > 0 and all($b.plugins[]; one_word) then empty
   else "plugins must be the skill names the agent loads, at least one" end),
  (if [$all[] | select(.type == "agent.initialized" and .body.agent == $b.agent)] | length > 0
   then "agent \($b.agent) is already initialized; a resumed agent starts no second time" else empty end)
