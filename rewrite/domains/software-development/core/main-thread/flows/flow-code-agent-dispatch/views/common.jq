# The defs this skill's templates and generate-agent-dispatch.sh's TITLE line share.
include "title";

# agent_word
#   input:  a dispatched agent, such as code-builder
#   output: its role word in a title: build agent, test agent or reviewer
def agent_word: {"code-builder": "build agent", "code-tester": "test agent", "code-reviewer": "reviewer"}[.] // "build agent";

# agent_label
#   input:  a dispatched agent
#   output: its agent_word capitalised, the plan card's section label, such
#           as "Build agent"
def agent_label: agent_word | capitalised;

# agent_title($role)
#   input:  {language: label or null, frameworks: [labels], lens: label or
#           null}, either list key absent
#   $role:  the role word, as agent_word gives it
#   output: "<lens> <role>" for a lens seat (a lens and no language), else
#           human-view's title($role)
def agent_title($role):
	if .language == null and (.lens // null) != null then "\(.lens) \($role)"
	else title($role) end;
