# GitLab's replies in the common shapes, a jq module: load it with
# jq -L <this folder> and include "gitlab". Each def says its input.

# Input: projects/P/merge_requests/N. The change as change-read.sh prints it.
def gl_change:
	{author: .author.username, head: (.diff_refs.head_sha // .sha), base_sha: .diff_refs.base_sha, base_branch: .target_branch, title,
	 description: (.description // ""),
	 state: (if .state == "opened" then "open" elif .state == "merged" then "merged" else "closed" end)};

# Input {mr, discussions, versions, bots}: the MR, its discussions (all
# pages), its versions, the names the human gave as bots. Output {threads}:
# each discussion with a note left, after system notes and empty bodies.
# A thread's commit: its first note's position, or for a note with no
# position the head of the latest version made before it.
def gl_threads:
	.bots as $bots | .mr.author.username as $author
	| (.versions | sort_by(.created_at)) as $versions
	| {threads: [.discussions[]
		| [.notes[] | select((.system | not) and ((.body // "") != ""))] as $notes
		| select($notes | length > 0)
		| $notes[0] as $first
		| ($first.position // null) as $pos
		| ([$versions[] | select(.created_at <= $first.created_at)] | last | .head_commit_sha) as $at
		| {id, resolved: ([$notes[] | select(.resolvable)] | length > 0 and all(.[]; .resolved == true))}
		  + (if $pos != null and $pos.head_sha != null then {commit: $pos.head_sha}
		     elif $at != null then {commit: $at} else {} end)
		  + (if $pos == null then {}
		     else {path: ($pos.new_path // $pos.old_path)}
			+ (if $pos.new_line != null then {new_line: $pos.new_line} else {} end)
			+ (if $pos.old_line != null then {old_line: $pos.old_line} else {} end) end)
		  + {comments: [$notes[] | .author.username as $who | {id: (.id | tostring),
			source: (if ($bots | index([$who])) != null then "bot" else "human" end),
			role: (if $who == $author then "author" else "reviewer" end),
			updated: .updated_at, body}]}]};
