# The fixed lines of git setup, one def per line; input: the line's fields.
include "line";

# input: {identity: the saved identity's label, auto_push: yes or no}
def git_setup_saved:
	"Git setup saved: \(field("identity")); auto-push \(if field("auto_push") == "yes" then "on" else "off" end).";

def type_name_and_email: "Type the name and email this effort's commits are authored with.";

def approval_gate_not_installed: not_installed("procedure-approval-gate");

def git_not_installed: not_installed("git"; "install it");
