# shellcheck shell=sh
#
# pm-lists.sh — newline-separated list accumulators for the
#               procedure-gh-issues commands.
#
# POSIX sh has no arrays, so a newline-separated string is the portable
# stand-in and these are the two ways a value gets appended to one.
#
# EVERY FUNCTION HERE IS VALUE-RETURNING: it prints the new list on stdout
# rather than mutating a global chosen by a name argument. So a call site reads
#     LABELS=$(csv_accumulate "$LABELS" "$2")
# which keeps the target variable visible exactly where it is assigned, and
# needs no `eval` and no string-keyed dispatcher — the pattern this codebase's
# conventions reject.
#
# ---------------------------------------------------------------------------
# csv_accumulate VS append_line — WHICH ONE A NEW CALL SITE WANTS.
#
# csv_accumulate SPLITS its value on commas; append_line does NOT — it appends
# the value verbatim, commas and all. The split is now the rule for EVERY
# CALLER-FACING LIST FLAG in this skill, without exception:
#
#   create-issue.sh   --label           -> csv_accumulate (splits)
#   create-issue.sh   --assignee        -> csv_accumulate (splits)
#   create-issue.sh   --project         -> csv_accumulate (splits)
#   update-issue.sh   --add-label       -> csv_accumulate (splits)
#   update-issue.sh   --remove-label    -> csv_accumulate (splits)
#   update-issue.sh   --add-assignee    -> csv_accumulate (splits)
#   update-issue.sh   --remove-assignee -> csv_accumulate (splits)
#   ensure-labels.sh  --label           -> csv_accumulate (splits)
#
# create-issue.sh's --assignee and --project were the two hold-outs: they used
# to append verbatim, so `--assignee alice,bob` on create meant ONE assignee
# literally named "alice,bob" while the identical string on update's
# --add-assignee meant TWO. That asymmetry was a real inconsistency with no
# discoverable intent, and it is now RESOLVED IN FAVOUR OF SPLITTING — the more
# capable direction, matching both the convention update-issue.sh already set
# and what the real `gh` CLI's own repeatable string-slice flags do. It is a
# deliberate, documented behavior change, not a refactor side effect: a caller
# passing a single value sees no difference, and a caller who worked around the
# old behavior with repeated flags still works, because every one of these flags
# also accumulates across repeats.
#
# NOT list flags, and deliberately never routed through here: --milestone (both
# scripts) and --title/--repo/--body-file, each a single scalar whose value may
# legitimately contain a comma; and link-children.sh's --child, whose every
# occurrence is validated as one positive integer, so a comma-list there is a
# usage error (exit 2) rather than a silently-accepted second meaning.
#
# append_line survives for the accumulators the scripts build INTERNALLY out of
# already-validated values — link-children.sh's CHILDREN/SEEN/NEW_LINES and
# ensure-labels.sh's SEEN — where a comma split would be wrong (a label name may
# legitimately contain one) and trimming would alter a value the script itself
# constructed. Those four sites open-coded the identical append until this
# primitive was routed through them.
# ---------------------------------------------------------------------------

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
# line, VERBATIM. No comma-splitting and no trimming — for INTERNAL, already
# validated values only (see the block above); no caller-facing list flag routes
# through here any more. An empty VALUE leaves CURRENT unchanged.
append_line() {
	acc=$1
	[ -n "$2" ] || { printf '%s' "$acc"; return 0; }
	if [ -z "$acc" ]; then acc=$2
	else acc="$acc
$2"
	fi
	printf '%s' "$acc"
}
