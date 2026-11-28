# The join of an effort's events to the reports their submissions pin, a jq
# module: load it with jq -L <this folder> and include "pinned-report".
# Input {events, reports}: events as events-read.sh prints them; reports
# maps each pinned path to {sha256, text}, the file as it is now, sha256 ""
# when it is gone. A submission is any event whose body holds
# report {path, sha256}.

def pr_submissions: .events[] | select((.body.report | type) == "object");

# One line per report that is not as its submission pinned it.
def pr_problems:
	.reports as $now
	| pr_submissions
	| .body.report as $pin
	| $now[$pin.path] as $file
	| (if $file == null or $file.sha256 == "" then ", and the file is gone"
	   elif $file.sha256 != $pin.sha256 then ", but it changed after it was submitted: it is now \($file.sha256[:12])"
	   elif ($file.text | try fromjson catch null) == null then ", and it is not JSON"
	   else empty end) as $wrong
	| "event \(.seq) (\(.type)) pinned \($pin.path) at sha256 \($pin.sha256[:12])\($wrong)";

# The events, each submission with the report it pins under report, beside
# its body.
def pr_joined:
	.reports as $now
	| [.events[] | if (.body.report | type) == "object" then . + {report: ($now[.body.report.path].text | fromjson)} else . end];
