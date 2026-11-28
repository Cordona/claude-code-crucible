# A job agent's name and skills, a jq module: load it with jq -L <the
# skills folder> and include "jobs-agent-init/scripts/lib/agent-name". The one
# mapping from a base agent, the kind's part and a job's plugins to the
# agent file that carries them, so the files and the door never name apart.

# The plugin skills of plugins $p for part $part (build, test or review),
# among the skill names $installed: each language, framework and standard
# in full, and its part where it has one installed (a part is optional: a
# standard may have no build part, no plugin has a test part yet).
def an_skills($part; $p; $installed):
	[("language-\($p.language)"), (($p.frameworks // [])[] | "framework-\(.)"), ($p.standards[] | "standard-\(.)")]
	| map(., ("\(.)-\($part)" | select(. as $s | $installed | index([$s]) != null)));

# The agent file's name: the base, then the language, frameworks and
# standards, so a type always starts with its base.
def an_name($base; $p): ([$base, $p.language] + ($p.frameworks // []) + $p.standards) | join("-");
