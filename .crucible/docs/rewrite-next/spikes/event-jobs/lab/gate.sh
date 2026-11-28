#!/bin/sh
# Spike: the card for a gated step, and the core gate's show-card.sh command
# that shows it. It writes no event: the human's answer is written by the
# gate's own hook, and that answer is the approval. What to run on each answer
# is kept in stops/follow/, not shown to the human.
# usage: gate.sh --effort DIR ONE OF
#   --fact KEY [--kinds K,K]                  review what a fact names
#   --step build --tree PATH --task TEXT      a build
#   --step test --tree PATH                   tests of the tree's latest build
#   --step test-plan --about SEQ              a test plan for build SEQ
#   --owed STEP --args JSON                   a gate step owes.sh names
# Stdout: one line, the command to run: sh .../show-card.sh ... CARD_FILE
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/cli.sh"
parse_opts "$@"
EFFORT=$(cd "$EFFORT" && pwd)
SHOW=$LAB/real/crucible-gate/scripts/main/show-card.sh
mkdir -p "$EFFORT/cards" "$EFFORT/stops/follow"

# card RECORD SUBJECT ACCEPT|"" : the card text on stdin; prints the command
card() {
	file="$EFFORT/cards/$1-$(printf '%s' "$2" | tr -c 'A-Za-z0-9-' '-').md"
	# the human sees the card; what follows each answer is kept in stops/follow/,
	# and next.sh (and the held stop) give it to main once the answer is in
	text=$(cat)
	# written only when it changes, so a card keeps the time it was made
	printf '%s\n' "$text" | grep -Ev '^on (yes|no|answer): ' > "$file.new"
	if cmp -s "$file.new" "$file"; then rm -f "$file.new"; else mv "$file.new" "$file"; fi
	printf '%s\n' "$text" | jq -Rn '[inputs | capture("^on (?<key>yes|no|answer): (?<value>.*)$")?] | from_entries' > "$EFFORT/stops/follow/$1-$(printf '%s' "$2" | tr -c 'A-Za-z0-9-' '-').json"
	if [ -n "$3" ]; then mode="--accept '$3'"; else mode=--choice; fi
	echo "sh $SHOW --record $1 --effort $EFFORT $mode --subject $2 $file"
}
lab() { printf 'sh %s/%s --effort %s' "$LAB" "$1" "$EFFORT"; }

if [ -n "${opt_fact:-}" ]; then
	about=$(printf '%s' "$opt_fact" | sed -n 's/^[a-z-]*:\([0-9][0-9]*\)$/\1/p')
	[ -n "$about" ] || die 1 "--fact takes a fact key such as no-review:4"
	words=$(sh "$LAB/owes.sh" --effort "$EFFORT" | jq -r --arg k "$opt_fact" '.facts[] | select(.key == $k) | .words')
	[ -n "$words" ] || die 1 "no open fact $opt_fact"
	kind=code
	evq -e --argjson s "$about" 'include "ev"; ev($s).type == "external-review.received"' >/dev/null && kind=external
	kinds=${opt_kinds:-${LAB_KINDS:-shell}}
	card review "$opt_fact" "Review it (Recommended)" <<CARD
Fact: $words; it can be reviewed now.
Recommended: a review by $(printf '%s' "$kinds" | sed 's/,/, /g'), one reviewer each over the whole change.
The other way: leave it unreviewed; it is not offered again.
on yes: $(lab round.sh) --kind $kind --targets $about --kinds $kinds
on no: $(lab choose.sh) --fact $opt_fact
CARD
	exit 0
fi

case "${opt_step:-}" in
build)
	[ -n "${opt_tree:-}" ] && [ -n "${opt_task:-}" ] || die 1 "--step build needs --tree and --task"
	card build "build" "Build it (Recommended)" <<CARD
Build in $opt_tree: $opt_task
Recommended: start the build now; its review is offered when it is done.
on yes: $(lab job-dispatch.sh) --kind build --tree $opt_tree --task '$opt_task'
CARD
	exit 0 ;;
test)
	[ -n "${opt_tree:-}" ] || die 1 "--step test needs --tree"
	build=$(evq -r --arg t "$opt_tree" 'include "ev"; root_of_tree($t) as $r | [.[] | select(.type == "build.submitted" and .root == $r)] | last | .seq // empty')
	[ -n "$build" ] || die 1 "no build on $opt_tree"
	card test "test:$build" "Write the tests (Recommended)" <<CARD
Tests for build $build in $opt_tree.
Recommended: write them now; their review is offered when they are done.
on yes: $(lab job-dispatch.sh) --kind test --tree $opt_tree
CARD
	exit 0 ;;
test-plan)
	need_seq about "${opt_about:-}"
	card test-plan "test-plan:$opt_about" "Plan the tests (Recommended)" <<CARD
A test plan for build $opt_about: drafted, challenged once, reworked, then shown to you.
Recommended: plan first, so the tests cover what matters.
on yes: $(lab job-dispatch.sh) --kind test-plan --target $opt_about
CARD
	exit 0 ;;
'') ;;
*) die 1 "unknown --step $opt_step" ;;
esac

[ -n "${opt_owed:-}" ] && [ -n "${opt_args:-}" ] || die 1 "give --fact, --step or --owed with --args"
a() { printf '%s' "$opt_args" | jq -r ".$1"; }
case "$opt_owed" in
choose)
	m=$(a merge)
	evq -r --argjson m "$m" 'include "ev"; ev($m).body as $b
		| "Review merged (\($m)): verdict \($b.verdict); \($b.targets | length) to fix.",
		  ($b.findings[] | select(.status | IN("open", "insisted", "ruled-fix")) | "- \(.id) \(.severity) \(.realism) in \(.file)"),
		  "Recommended: fix \($b.targets | join(", ") | if . == "" then "nothing" else . end), up to three rounds; the loop also fixes new findings its fixes raise."' |
		{ cat; echo "on answer: $(lab choose.sh) --merge $m, then the human's choice as --severity LIST [--plus IDS] [--minus IDS] --cap N, or --none"; } |
		card fix-choice "merge:$m" "" ;;
end-card)
	l=$(a loop); r=$(a reason)
	card end-card "loop:$l" "Close the loop (Recommended)" <<CARD
The fix loop of choice $l is over: $r.
$(sh "$LAB/owes.sh" --effort "$EFFORT" | jq -r --argjson l "$l" 'select(.loop.chosen == $l) | .loop | "Rounds: \(.rounds) of \(.cap)."')
Recommended: close it; anything left is offered again.
on yes: $(lab loop-end.sh) --loop $l --reason $r
CARD
	;;
plan-gate)
	p=$(a plan)
	card plan-gate "plan:$p" "Approve the plan (Recommended)" <<CARD
The reworked test plan ($p) answers every challenge.
Recommended: approve it.
on yes: $(lab choose.sh) --plan $p
CARD
	;;
replies)
	r=$(a review)
	card replies "review:$r" "Post the replies (Recommended)" <<CARD
The external review $r is dealt with; its threads get their replies.
Recommended: post them.
on yes: $(lab remote.sh) --review $r
CARD
	;;
comments)
	m=$(a merge)
	card comments "merge:$m" "Post the comments (Recommended)" <<CARD
Our review of their change is merged ($m).
Recommended: post its open findings as comments.
on yes: $(lab remote.sh) --merge $m
CARD
	;;
*) die 1 "$opt_owed is not a gate step" ;;
esac
