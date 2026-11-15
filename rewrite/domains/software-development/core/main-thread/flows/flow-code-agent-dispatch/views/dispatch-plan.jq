# The dispatch-plan gate: the slim plan, plugins by label (a plugin
# list-plugins.sh no longer prints shows its name), every reason staying in the
# plan JSON. A code-developer plan: the Developer title from its valid language
# and frameworks, then Load and Skip with its standards, then procedures, in
# plan order. A code-reviewer plan holds one lens and shows only the Reviewer
# line, its seat's title. A replan "invalid" plan shows only the plugins it
# names as invalid, and no question.
include "view";
include "common";

def clean: one_line | sub("^ +"; "") | sub(" +$"; "");
# A task keeps its own lines (a numbered list in it stays as written); any
# other control character prints as a space.
def task_text: gsub("\r"; "") | split("\n") | map(one_line | sub(" +$"; "")) | join("\n")
	| sub("\\A\n+"; "") | sub("\n+\\z"; "");
# The later lines of a numbered item are indented under it; a blank line stays empty.
def list_item_lines: split("\n") | .[:1] + (.[1:] | map(if . == "" then . else "   " + . end)) | join("\n");
def task_section: section("Task"; "Tasks"; .tasks | map(task_text | list_item_lines));

# view
#   input:  {plan: the plan JSON, installed: installed-plugins.jq's map of
#           the installed plugins, data: [[kind, path], ...], the --data pairs
#           in the order given, then what the dispatch would cut}
#   output: the plan, without the gate marker open-gate.sh adds
def view:
	.installed as $installed
	| (.data | map([.[0], (.[1] | clean)])) as $data
	| def plugin_label: $installed[.plugin].label // .plugin | clean;
	def kind_labels($group): (($group.standards // []) + ($group.procedures // [])) | map(plugin_label);
	def installed_only: .plugin as $name | select($installed | has($name));
	# A plugin installed and not named invalid by the plan.
	def valid_only: installed_only | select(.reason != "invalid");
	# The title input, from the valid plugins only (an invalid one shows only
	# under Invalid): the language label and the framework labels in plugin-name order.
	def seat_labels: {language: (first(.language // empty | valid_only | plugin_label) // null),
		frameworks: [.frameworks // [] | sort_by(.plugin)[] | valid_only | plugin_label]};
	def role_section:
		(.plugins.load // {}) as $load
		| [$load.standards // [] | .[] | installed_only | plugin_label] as $lenses
		| if .agent == "code-reviewer" then
			section("Reviewer"; [$load | seat_labels
				+ {lens: (if $load.language == null then $lenses[0] else null end)} | agent_title("reviewer")])
		  else section("Developer"; [$load | seat_labels | agent_title("developer")]) end;
	def invalid_labels:
		[(.plugins.load.language // empty), (.plugins.load.frameworks // [])[], (.plugins.skip.standards // [])[], (.plugins.skip.procedures // [])[]
		 | select(.reason == "invalid") | plugin_label];
	.plan
	| if .replan == "invalid" then
		[status_line("blocked"; "Blocked · this plan names an invalid plugin: fix it, then rerun"),
		 role_section,
		 task_section,
		 section("Invalid"; invalid_labels)]
	  elif .agent == "code-reviewer" then
		[status_line("decision"; "Decision needed · approve this dispatch?"),
		 role_section,
		 task_section]
	  else
		[status_line("decision"; "Decision needed · approve this dispatch?"),
		 role_section,
		 task_section,
		 section("Load"; kind_labels(.plugins.load // {})),
		 section("Skip"; kind_labels(.plugins.skip // {}))]
	  end
	| . + [data_section($data)]
	| blocks;
