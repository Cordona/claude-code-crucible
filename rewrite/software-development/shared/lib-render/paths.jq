# Path display helpers; lib-render's SKILL.md (Modules) lists each def's input and output.

def span_cap: 80;
# 30 keeps a path's leading folders recognisable while leaving 49 characters
# for its tail, where the basename sits.
def cut_head: 30;
def middle_cut($tail): .[:(span_cap - 1 - $tail)] + "…" + .[(length - $tail):];
def capped: if length > span_cap then middle_cut(span_cap - 1 - cut_head) else . end;
def code_span: "`" + (gsub("`"; "'") | capped) + "`";
def base_name: sub("^.*/"; "");
def dir_segments: split("/") | .[1:-1];
def home_form($home): ($home | rtrimstr("/")) as $prefix
	| if $prefix != "" and (. == $prefix or startswith($prefix + "/")) then "~" + .[($prefix | length):] else . end;
def short_path($home): home_form($home) | (base_name | length) as $base
	| if length <= span_cap or $base > span_cap - 2 then capped
	  else middle_cut([span_cap - 1 - cut_head, $base] | max) end;
def shared_start($next): . as $prefix
	| first(range(0; length + 1) | select(. == ($prefix | length) or $prefix[.] != $next[.])) as $count
	| $prefix[:$count];
