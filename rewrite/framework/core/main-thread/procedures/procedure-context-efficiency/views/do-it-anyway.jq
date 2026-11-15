# The gate under a habit row's line, asking whether to do the work anyway.
include "view";
include "line";

# view
#   input:  {habit: the Bad habits row, 3 to 7}
#   output: the gate's plan, without the gate marker open-gate.sh adds
def view:
	{"3": "try the fix again here?",
	 "4": "answer the side question here?",
	 "5": "switch the model or fast mode now?",
	 "6": "show the whole file or log?",
	 "7": "compact this conversation?"}[field("habit") | tostring] as $ask
	| if $ask == null then error("habit must be a row from 3 to 7")
	  else status_line("decision"; "Decision needed · \($ask)") end;
