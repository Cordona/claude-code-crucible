# The flow's shared names, the one definition every validator and script
# reads.
# Include it with: include "dispatch-names"; and -L this folder, or a search
# path relative to the including file, such as {search: "./"} or
# {search: "../agent-dispatch"}; a bare "." misses the module (jq 1.6 to 1.8).
# A shell script reads a value with
#   jq -nr -L <this folder> 'include "dispatch-names"; listed_agents | join(" ")'

# The agents a dispatch file is written for: the one list of dispatched
# agents. A new agent goes here.
def dispatched_agents: ["code-builder", "code-reviewer", "code-tester"];
# The agents prepare-agent-prompt.sh acts on as a PreToolUse hook. No
# code-reviewer: no review seat exists to dispatch it into.
def listed_agents: ["code-builder", "code-tester"];
# The mode each dispatched agent's plan holds, the mode of the seat it goes
# to. A code-tester is dispatched only to PLAN: its TEST work reaches the same
# running agent by message, never by a dispatch.
def agent_modes: {"code-builder": "BUILD", "code-reviewer": "BUILD", "code-tester": "PLAN"};
# \A and \z, not ^ and $: jq's $ also matches before a final newline.
def sha256_pattern: "\\A[0-9a-f]{64}\\z";
# A Crucible ID: <YYYYMMDDTHHMMSS>-<4 lowercase hex>, the shape crucible_is_id
# of the crucible skill's scripts/lib/crucible-space.sh checks.
def crucible_id_pattern: "\\A[0-9]{8}T[0-9]{6}-[0-9a-f]{4}\\z";
# A seat name of the effort's seats, as procedure-seat-run's
# scripts/seats/seats.jq names one (seats_name_pattern, kept the same here):
# lowercase words joined by dashes, then a letter of alpha ... omega and, from
# the second round, -2, -3 ..., like build-agent-alpha or build-agent-alpha-2.
def seat_pattern: "\\A[a-z][a-z0-9]*(-[a-z][a-z0-9]*)*-(alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa|lambda|mu|nu|xi|omicron|pi|rho|sigma|tau|upsilon|phi|chi|psi|omega)(-[2-9]|-[1-9][0-9]+)?\\z";

