# The fixed lines the main thread shows, one def per line; input: the line's
# fields.
include "line";

def failed_attempts: "These failed attempts stay in the conversation and are re-read each turn: /rewind (Esc Esc) drops them, or /clear and re-prompt with what they showed.";

def failed_attempts_shell: "These failed attempts stay in the conversation and are re-read each turn: /clear and re-prompt with what they showed.";

def side_question: "A side question stays in the conversation and is re-read each turn: /btw answers it without adding it.";

def model_switch: "A model or fast-mode switch mid-task makes the next turn re-read the whole conversation from scratch: switching at a natural break avoids that.";

def whole_file: "A whole file or log stays in the conversation and is re-read each turn: the lines that matter, found by a search or a line range, do the same job.";

def compact_idle: "/compact re-reads this whole conversation to summarise it: when the work doesn't need to carry on, /clear starts clean without that.";

# input: {skill: the owner skill the Skill tool could not load}
def owner_not_installed: "\(field("skill")) is not installed: \(skills_install).";
