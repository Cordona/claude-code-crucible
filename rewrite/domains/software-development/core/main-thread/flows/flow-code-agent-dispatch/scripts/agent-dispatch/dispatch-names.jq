# The flow's shared names, the one definition every validator and script
# reads.
# Include it with: include "dispatch-names"; and -L this folder, or a search
# path relative to the including file, such as {search: "./"} or
# {search: "../agent-dispatch"}; a bare "." misses the module (jq 1.6 to 1.8).
# A shell script reads a value with
#   jq -nr -L <this folder> 'include "dispatch-names"; listed_agents | join(" ")'

# The agents a dispatch file is written for: the one list of dispatched
# agents. A new agent goes here.
def dispatched_agents: ["code-developer", "code-reviewer"];
# The agents prepare-agent-prompt.sh acts on as a PreToolUse hook: every
# dispatched agent.
def listed_agents: dispatched_agents;
# \A and \z, not ^ and $: jq's $ also matches before a final newline.
def sha256_pattern: "\\A[0-9a-f]{64}\\z";
# A Crucible ID: <YYYYMMDDTHHMMSS>-<4 lowercase hex>, the shape crucible_is_id
# of the crucible skill's scripts/lib/crucible-space.sh checks.
def crucible_id_pattern: "\\A[0-9]{8}T[0-9]{6}-[0-9a-f]{4}\\z";
# A Claude Code session ID, a lowercase UUID, as CLAUDE_CODE_SESSION_ID holds
# it and crucible_check_session of the crucible skill's
# scripts/lib/crucible-space.sh takes it: the session a plan or a dispatch
# names as claude_session_id.
def claude_session_id_pattern: "\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z";
# A seat name of the effort's seats.json, as procedure-git-worktree's
# scripts/seats/seats.jq names one (seats_name_pattern, kept the same here):
# lowercase words joined by dashes, the last one of alpha ... omega, like
# software-developer-alpha.
def seat_pattern: "\\A[a-z][a-z0-9]*(-[a-z][a-z0-9]*)*-(alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa|lambda|mu|nu|xi|omicron|pi|rho|sigma|tau|upsilon|phi|chi|psi|omega)\\z";
# A local time with its offset, YYYY-MM-DDTHH:MM:SS+HH:MM.
def local_time_pattern: "\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}\\z";

