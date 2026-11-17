# The install check's result.
include "view";
include "title";

# Each item as display text: shown, the first letter upper case.
def items: map(shown | capitalised);

# view
#   input:  {failed, total: counts of the full run; fixes, warnings: the Fix
#           and Warnings items (a warning is a Fix item too); passed: the
#           passed checks, listed only when given; since: the cached pass's
#           time, or null for a full run; not_cached: why a pass was not
#           cached, or null}
#   output: the cached pass line; else blocked with one Fix item per failed
#           or warned check, passed with one Warnings item per warning, or
#           passed with the count; the passed checks after it; then the
#           not-cached note on its own line
def view:
	(.fixes | items) as $fixes
	| (.warnings | items) as $warnings
	| (.not_cached // "" | shown) as $not_cached
	| (if .since != null then [status_line("done"; "Install check passed"; "unchanged since \(.since)")]
	   elif .failed > 0 then
		[status_line("blocked"; "Blocked · install check: \(.failed) of \(.total) checks failed"),
			section("Fix"; $fixes)]
	   elif $warnings != [] then
		[status_line("attention"; "Install check passed with \($warnings | length | counted("warning"; "warnings"))"),
			section("Warning"; "Warnings"; $warnings)]
	   else [status_line("done"; "Install check passed"; "\(.total) checks")]
	   end)
	+ [section("Passed"; .passed // [] | items)]
	| blocks + (if $not_cached == "" then "" else "\n(result not cached: \($not_cached))" end);
