# shellcheck shell=sh
#
# pm-lists.sh — newline-separated list accumulators for the
#               procedure-glab-issues commands.
#
# POSIX sh has no arrays, so a newline-separated string is the portable
# stand-in and these are the two ways a value gets appended to one.
#
# EVERY FUNCTION HERE IS VALUE-RETURNING: it prints the new list on stdout rather
# than mutating a global chosen by a name argument. So a call site reads
#     ADD_LABELS=$(csv_accumulate "$ADD_LABELS" "$2")
# which keeps the target variable visible exactly where it is assigned, and
# needs no `eval` and no string-keyed dispatcher — the pattern this codebase's
# conventions reject.
#
# ---------------------------------------------------------------------------
# csv_accumulate VS append_line — THE DIFFERENCE IS DELIBERATE.
#
# csv_accumulate SPLITS its value on commas and trims each token; append_line
# does NOT — it appends the value verbatim, commas and all.
#
# THE SPLIT IS FOR CLI FLAG VALUES, THE VERBATIM APPEND IS FOR INTERNAL LISTS.
# In THIS family every list-valued CLI flag comma-splits, so csv_accumulate is
# the only one wired to argument parsing. append_line serves the accumulators the
# scripts build INTERNALLY out of already-validated values — link-children.sh's
# CHILDREN / SEEN / NEW_LINES, ensure-labels.sh's SEEN — where splitting on a
# comma would be wrong (a label name may legitimately contain one) and where
# trimming would silently alter a value the script itself constructed.
#
# Those four sites each hand-rolled the identical three-line
# `if [ -z "$acc" ] … else … fi` append before this primitive existed here; the
# GitHub sibling already carried it, and this file's header used to assert a
# counterpart "would be dead code" — which was true only of the FLAG-parsing
# role, and false of the internal accumulators that were open-coding it.
# ---------------------------------------------------------------------------
#
# NOTE ON THE GITHUB SIBLING: procedure-gh-issues has its OWN physically
# separate pm-lists.sh, whose three functions are byte-identical to these. The
# two are deliberately NOT shared — the hub deploys each skill directory
# independently (symlinking it), so a cross-family `source` would resolve fine in
# this repo and then fail only at RUNTIME, invisibly past a green test suite, for
# anyone who installs one skill without the other. Duplication here is the
# cheaper failure mode. (The GitHub side now routes EVERY caller-facing list flag
# through csv_accumulate too — `create-issue.sh --assignee`/`--project` were the
# last hold-outs that appended verbatim, and both were changed to split, ending
# an asymmetry with `update-issue.sh --add-assignee`. So append_line is
# INTERNAL-ONLY in BOTH families, exactly as it is here: no CLI flag on either
# side reaches it.)

# split_csv_list VALUE — print each comma-separated, trimmed, non-empty token
# in VALUE on its own line (stdout).
#
# csv_accumulate below reads this through a HEREDOC, never by piping into its
# `while read`: the loop must stay in csv_accumulate's OWN shell so its `acc`
# variable survives to the final printf. Piping would put the loop in a further
# subshell and lose every appended token.
split_csv_list() {
	value=$1
	old_ifs=$IFS
	IFS=','
	set -f
	# shellcheck disable=SC2086  # deliberate split of a comma-list on IFS=','; -f (above) blocks globbing
	set -- $value
	set +f
	IFS=$old_ifs
	for tok in "$@"; do
		tok=$(printf '%s' "$tok" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		[ -n "$tok" ] || continue
		printf '%s\n' "$tok"
	done
}

# csv_accumulate CURRENT VALUE — print CURRENT with every comma-separated token
# of VALUE appended as its own line. CURRENT may be empty (then the result is
# just the new tokens). VALUE contributing no usable token leaves CURRENT
# unchanged, so a `--label ,,` cannot introduce a blank entry.
csv_accumulate() {
	acc=$1
	while IFS= read -r tok; do
		[ -n "$tok" ] || continue
		if [ -z "$acc" ]; then acc=$tok
		else acc="$acc
$tok"
		fi
	done <<EOF
$(split_csv_list "$2")
EOF
	printf '%s' "$acc"
}

# append_line CURRENT VALUE — print CURRENT with VALUE appended as ONE new
# line, VERBATIM. No comma-splitting and no trimming (see the block above: this
# is the deliberate counterpart to csv_accumulate, not an oversight). An empty
# VALUE leaves CURRENT unchanged.
append_line() {
	acc=$1
	[ -n "$2" ] || { printf '%s' "$acc"; return 0; }
	if [ -z "$acc" ]; then acc=$2
	else acc="$acc
$2"
	fi
	printf '%s' "$acc"
}
