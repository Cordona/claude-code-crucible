# The defs this skill's templates and generate-agent-dispatch.sh's TITLE line share.
include "title";

# agent_title($role)
#   input:  {language: label or null, frameworks: [labels], lens: label or
#           null}, either list key absent
#   $role:  the role word, builder or reviewer
#   output: "<lens> <role>" for a lens seat (a lens and no language), else
#           human-view's title($role)
def agent_title($role):
	if .language == null and (.lens // null) != null then "\(.lens) \($role)"
	else title($role) end;
