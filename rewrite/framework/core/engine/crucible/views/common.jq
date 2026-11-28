# The defs this skill's prune cards share.
include "view";

# prune_view($status; $title; $list; $note)
#   input:  {days: N of --older-than, removed: [effort folder], kept:
#           [{folder, reason}]}
#   output: the status line counting the removed folders, the $list section of
#           them, the Kept section and, when any folder is listed, $note
def prune_view($status; $title; $list; $note):
	(.removed | map(path_text)) as $gone
	| ($gone | length) as $count
	| [status_line($status; $title;
			"\($count | counted("effort folder"; "effort folders")) unchanged for \(.days) days"),
		section($list; $gone),
		section("Kept"; .kept | map("\(.folder | path_text) (\(.reason))")),
		(if $count == 0 then "" else $note end)]
	| blocks;
