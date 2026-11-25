# A test report's rules, a jq module: load it with jq -L <the skills
# folder> and include "code-tester/scripts/lib/test-report". The tester's
# common rules, with a production_bug blocker, the mutation gate required,
# and the approved plan as the scope of what may change; a test-fix
# report's rules build on them. facts {plan, build_files, changed}, from
# tester-facts.sh.
include "code-tester/scripts/lib/tester-common";

# The plan's own files: its tests' files and its support entries, a folder
# included with everything in it.
def tt_plan_files: [(.facts.plan.tests // [])[], (.facts.plan.support // [])[] | objects | .file | strings];
def tt_planned($files): . as $path | any($files[]; . as $f | $path == $f or ($path | startswith(($f | rtrimstr("/")) + "/")));

# The file of an at in the tree, path or path:N or path:N-M; null for
# another repo's or a removed line's.
def tt_at_file: if type == "string" then (capture("^(?<file>[^:@\\s-][^:]*)(:[1-9][0-9]*(-[1-9][0-9]*)?)?$").file // null) else null end;

def tt_mutation:
	if any(tc_entries("gates") | .v | objects; .gate == "mutation") then empty
	else "list the mutation gate: pass with a note, fail with what survived, or not_run with why" end;

def tt_production_bugs:
	tt_plan_files as $files
	| tc_entries("blockers") | select((.v | type) == "object" and .v.kind == "production_bug") | .w as $w | .v
	| if has("at") | not then "\($w) is production_bug: add at, the production line that is wrong"
	  elif any(.at | (if type == "array" then .[] else . end) | tt_at_file; . != null and tt_planned($files))
	  then "\($w) is production_bug: at must be the production line that is wrong, not a test or support file"
	  else empty end;

# What the tester changed, against the approved plan: a planned file is
# allowed; an unplanned file the build under test changed is refused;
# anything else needs a decisions entry at it.
def tt_scope:
	tt_plan_files as $files
	| (.facts.build_files // []) as $build
	| [tc_entries("decisions") | .v | objects | .at | (if type == "array" then .[] else . end) | tt_at_file | strings] as $explained
	| (.facts.changed // [])[]
	| select(tt_planned($files) | not)
	| if IN($build[]) then "you changed \(.), which the build under test changed and the plan doesn't name: undo it, and say what you need in a question or a cannot blocker"
	  elif IN($explained[]) then empty
	  else "you changed \(.), which isn't in the approved plan: undo it, or add a decisions entry at it saying why" end;

# A test job writes every planned test, unless a cannot blocker says why not.
def tt_untouched:
	(.facts.changed // []) as $changed
	| if any(tc_entries("blockers") | .v | objects; .kind == "cannot") then empty
	  else [(.facts.plan.tests // [])[] | objects | {action, file}] | unique[]
		| select(.file as $f | $changed | index([$f]) | not)
		| {"add": "adds a test in \(.file), which didn't change: write it",
		   "modify": "modifies tests in \(.file), which didn't change: make the change",
		   "remove": "removes tests in \(.file), which didn't change: remove them"}[.action] // empty
		| "the approved plan \(.), or add a cannot blocker"
	  end;

def tt_own: tt_mutation, tt_production_bugs, tt_scope;

def test_report_problems:
	tc_common_problems(tc_keys), tc_unchanged_problem, tt_own, tt_untouched;
