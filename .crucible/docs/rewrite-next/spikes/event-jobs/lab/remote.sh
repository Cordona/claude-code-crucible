#!/bin/sh
# Spike: a fake pull request, a JSON file under the effort (pr/<id>.json),
# and the events its traffic starts. Every chain event's root is derived.
# usage: remote.sh --effort DIR [--session ID] ONE OF
#   --open --pr ID --base SHA --head SHA --tree PATH [--threads JSON]   set up the fake PR (no event)
#   --fetch --pr ID          the review on our PR: external-review.received
#   --request --pr ID        a review asked of us: pr.review-requested
#   --push --pr ID --head SHA [--replies JSON]   the author pushed: pr.head-moved
#   --review SEQ [--check]   post the replies to an external review's threads: pr.posted
#   --merge SEQ [--check]    post a merge's findings as comments: pr.posted
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/cli.sh"
parse_opts "$@"
mkdir -p "$EFFORT/pr"
pr_file() { printf '%s/pr/%s.json' "$EFFORT" "$1"; }
need_pr() { [ -n "${opt_pr:-}" ] && [ -f "$(pr_file "$opt_pr")" ] || die 1 "no fake PR ${opt_pr:-}"; }
done_json() { jq -nc --argjson s "$1" '{ok: true, seq: $s}'; }

if [ -n "${opt_open:-}" ]; then
	[ -n "${opt_pr:-}" ] && [ -n "${opt_base:-}" ] && [ -n "${opt_head:-}" ] && [ -n "${opt_tree:-}" ] || die 1 "--open needs --pr, --base, --head and --tree"
	threads=${opt_threads:-}; [ -n "$threads" ] || threads='[]'
	jq -nc --arg pr "$opt_pr" --arg b "$opt_base" --arg h "$opt_head" --arg t "$opt_tree" --argjson th "$threads" \
		'{pr: $pr, base: $b, head: $h, tree: $t, threads: $th, posted: []}' > "$(pr_file "$opt_pr")"
	echo '{"ok":true}'; exit 0
fi
if [ -n "${opt_fetch:-}" ]; then
	need_pr
	done_json "$(write external-review.received self null null "$(jq -c '{pr, head, tree, threads}' "$(pr_file "$opt_pr")")")"; exit 0
fi
if [ -n "${opt_request:-}" ]; then
	need_pr
	done_json "$(write pr.review-requested self null null "$(jq -c '{pr, base, head, tree}' "$(pr_file "$opt_pr")")")"; exit 0
fi
if [ -n "${opt_push:-}" ]; then
	need_pr; [ -n "${opt_head:-}" ] || die 1 "--push needs --head"
	f=$(pr_file "$opt_pr")
	root=$(evq -r --arg pr "$opt_pr" '[.[] | select(.type | IN("pr.review-requested", "external-review.received")) | select(.body.pr == $pr) | .root] | last // empty')
	[ -n "$root" ] || die 1 "PR $opt_pr has no chain"
	replies=${opt_replies:-}; [ -n "$replies" ] || replies='{}'
	body=$(jq -c --arg h "$opt_head" --argjson r "$replies" '{pr, old_head: .head, head: $h, replies: $r}' "$f")
	jq --arg h "$opt_head" '.head = $h' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
	done_json "$(write pr.head-moved "$root" null null "$body")"; exit 0
fi

# posting: the items, and the decision they answer (refused when already posted after it)
if [ -n "${opt_review:-}" ]; then
	need_seq review "$opt_review"
	plan_step() { evq --argjson r "$opt_review" 'include "ev"; ev($r) as $R
		| if $R.type != "external-review.received" then {ok: false, refusal: "not-a-review"} else
		  ([.[] | select(.root == $r and (.type == "fix.none" or .type == "loop.ended"))] | last) as $d
		  | (first(.[] | select(.type == "pr.posted" and .root == $r and .seq > ($d.seq // 0))) | {ok: false, refusal: "done-already", by: .seq})
		  // {ok: true, root: $r, pr: $R.body.pr, items: [$R.body.threads[] | {id: .thread, kind: "reply"}]} end'; }
elif [ -n "${opt_merge:-}" ]; then
	need_seq merge "$opt_merge"
	plan_step() { evq --argjson m "$opt_merge" 'include "ev"; ev($m) as $M
		| if $M.type != "review.merged" then {ok: false, refusal: "not-a-merge"} else
		  (first(.[] | select(.type == "pr.posted" and .root == $M.root and .seq > $m)) | {ok: false, refusal: "done-already", by: .seq})
		  // {ok: true, root: $M.root, pr: ev($M.root).body.pr,
		      items: [$M.body.findings[] | select(.status | IN("open", "insisted")) | {id, kind: "comment"}]} end'; }
else
	die 1 "give --open, --fetch, --request, --push, --review or --merge"
fi
plan=$(plan_step)
printf '%s' "$plan" | jq -e .ok >/dev/null || refusal "$plan"
[ -z "${opt_check:-}" ] || { echo '{"ok":true}'; exit 0; }
f=$(pr_file "$(printf '%s' "$plan" | jq -r .pr)")
[ ! -f "$f" ] || { jq --argjson p "$plan" '.posted += $p.items' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
seq=$(write pr.posted "$(printf '%s' "$plan" | jq -r .root)" null null "$(printf '%s' "$plan" | jq -c '{items}')") || recheck $?
done_json "$seq"
