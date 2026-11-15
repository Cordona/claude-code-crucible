# The fixed lines the main thread shows, one def per line; input: the line's
# fields.
include "line";
include "paths";

def no_effort_started: "No effort was started here. Open a new session or run /clear, then ask again.";

def resume_not_installed: not_installed("procedure-resume");

def no_effort_resumed: "No effort is resumed.";

# input: {name: the effort's NAME}
def not_resumed_here: "\(field("name") | code_span) was not resumed here. Open a new session or run /clear, then ask to continue it.";

def resume_question_not_read: "The resume question could not be read. Nothing is resumed here.";

# input: {name: the effort's NAME, state: its state}
def effort_stays: "\(field("name") | code_span) stays \(field("state")).";

def offer_not_installed: "The effort offer could not be shown: its renderer is not installed correctly. No effort was started.";

def offer_question_not_read: "The effort offer's question could not be read. No effort was started.";

def offer_not_shown: "The effort offer could not be shown. No effort was started.";

def open_work_question_not_read: "The open-work question could not be read. Nothing was changed.";
