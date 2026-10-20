# The flow's shared names and the baseline file's shape, the one definition
# every validator and script reads.
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
# A Crucible ID, as crucible.sh new makes it: <YYYYMMDDTHHMMSS>-<4 lowercase hex>.
def crucible_id_pattern: "\\A[0-9]{8}T[0-9]{6}-[0-9a-f]{4}\\z";
# A local time with its offset, YYYY-MM-DDTHH:MM:SS+HH:MM.
def local_time_pattern: "\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}\\z";

# A dispatch's baseline file: the repository's git status at the Agent call (or
# at --direct), written once by prepare-agent-prompt.sh into the empty file
# generate-agent-dispatch.sh had crucible.sh make; with --baseline-from,
# generate-agent-dispatch.sh fills it instead, byte for byte from an earlier
# dispatch's. One JSON object:
#   {"repo_root": <the dispatch's repo_root>, "taken": <local time>,
#    "entries": [<one git status --porcelain=v1 -z --no-renames entry>, ...]}
# repo_root binds the baseline to its dispatch; only the checks read it.
# taken is kept for audit: when the tree was read; nothing reads it.
# An entry is "XY <path>", git's NUL taken off; a clean tree is [].
def baseline_kind: "baselines";
def baseline_keys: ["repo_root", "taken", "entries"];
# Prints one "<field> <problem>; expected <x>" line per way the input, a
# parsed baseline file, differs from the shape above for repo root $repo_root.
def baseline_problems($repo_root):
	if type != "object" then "the baseline is a JSON \(type); expected an object with \(baseline_keys | join(", "))"
	else ((keys - baseline_keys)[] | "\(tojson): unknown field; expected only \(baseline_keys | join(", "))"),
		(baseline_keys[] as $key | select(has($key) | not) | "\($key) missing; expected every one of \(baseline_keys | join(", "))"),
		(select(has("repo_root")) | if .repo_root == $repo_root then empty
		 else "repo_root \(.repo_root | tojson) is not the dispatch's; expected \($repo_root | tojson)" end),
		(select(has("taken")) | if (.taken | type) == "string" and (.taken | test(local_time_pattern)) then empty
		 else "taken is not a local time; expected YYYY-MM-DDTHH:MM:SS+HH:MM" end),
		(select(has("entries")) | if (.entries | type) == "array" and all(.entries[]; type == "string" and length > 3) then empty
		 else "entries is not an array of git status entries; expected [\"XY <path>\", ...] ([] for a clean tree)" end)
	end;
