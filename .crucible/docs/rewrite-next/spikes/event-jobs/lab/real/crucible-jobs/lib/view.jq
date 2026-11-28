# Spike: the lab's view of a real event. The real envelope carries no chain
# links, so they travel in the body; the view lifts them back out.

# Lab types that are not a real type's name, and the real names they are
# written under. The lab's own approval is not the gate's gate.answered,
# whose rule admits only the gate's hook.
def real_types: {"waiver": "waiver.recorded", "gate.answered": "gate.approved"};
def real_type: real_types[.] // .;
def lab_type: . as $t | (real_types | to_entries | map(select(.value == $t)) | first | .key) // $t;

# The gate's own answer is an approval for the step it records. Its subject
# is "<what>:<seq>" naming the event decided about, or carries no seq.
def gate_answer: .type == "gate.answered" and .by == "record-gate-answer.sh";
def subject_seq: (.body.subject // "") | capture(":(?<s>[0-9]+)$") | .s | tonumber;

def lab_event:
	if gate_answer then
		{seq, type: "gate.answered", at, session: .claude_session_id, root: null, round: null, job: null, agent: null,
		 body: {step: .body.record, answer: .body.answer, accepted: .body.accepted, subject: .body.subject},
		 about: (subject_seq? // null)}
	else
		{seq, type: (.type | lab_type), at, session: .claude_session_id,
		 root: (if .body.root == "self" then .seq else .body.root end),
		 round: .body.round, job: .body.job, agent: .body.agent,
		 body: (.body | del(.root, .round, .job, .agent))}
	end;
def lab_view: map(lab_event)
	| . as $all
	| map(if has("about") then (.about as $a | .root = (if $a == null then null else (first($all[] | select(.seq == $a)) | .root) end) | del(.about)) else . end);
