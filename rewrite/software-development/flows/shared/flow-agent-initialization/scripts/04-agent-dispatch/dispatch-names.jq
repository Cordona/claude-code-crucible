# The flow's shared names, the one definition every validator and script reads.
# Include it with: include "dispatch-names"; and -L this folder, or a search
# path relative to the including file, such as {search: "./"} or
# {search: "../04-agent-dispatch"}; a bare "." misses the module (jq 1.6 to 1.8).
# A shell script reads a value with
#   jq -nr -L <this folder> 'include "dispatch-names"; direct_agent'

# Direct implementation: the main thread writes the code itself.
def direct_agent: "main thread";
# The agents prepare-agent-prompt.sh acts on as a PreToolUse hook.
def listed_agents: ["code-developer", "code-reviewer"];
# \A and \z, not ^ and $: jq's $ also matches before a final newline.
def sha256_pattern: "\\A[0-9a-f]{64}\\z";
