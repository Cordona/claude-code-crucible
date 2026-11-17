# The one way a template reads a field it cannot do without, the one way a
# line ends a sentence on a field, and the one wording of a line saying
# something is not installed.

# field($name)
#   input:  the template's input object
#   output: its $name value; missing, null or "" raises {missing_field: $name},
#           which show.sh refuses with exit 2, naming the template and the field
def field($name):
	.[$name] as $value
	| if $value == null or $value == "" then error({missing_field: $name}) else $value end;

# sentence
#   input:  text
#   output: the text with "." added, unless it already ends with one, so a
#           field ending its own sentence is not stopped twice
def sentence: if endswith(".") then . else . + "." end;

# skills_install
#   output: how to install a missing skill: under the Claude Code skills folder
def skills_install: "install it under ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/";

# not_installed($what; $fix), not_installed($what)
#   input:  ignored
#   output: `<what> is not installed: <fix>, then ask me again.`; $fix
#           defaults to skills_install
def not_installed($what; $fix): "\($what) is not installed: \($fix), then ask me again.";
def not_installed($what): not_installed($what; skills_install);

# skill_not_installed
#   input:  {skill: the name of the skill that could not be loaded or run}
#   output: not_installed for that skill
def skill_not_installed: not_installed(field("skill"));
