# The approval gate's marker, the one copy: a gate view ends with it, which
# shows the human the view is a gate whose question follows.

# gate_marker
#   output: the marker line
def gate_marker: "_Crucible gate_";

# gate_text
#   input:  a rendered gate plan
#   output: the plan without its trailing blank (whitespace-only) lines, then a
#           blank line and the marker
def gate_text:
	split("\n")
	| until(length == 0 or (.[-1] | test("[^ \t\n\u000b\f\r]")); .[:-1])
	| join("\n") + "\n\n" + gate_marker;
