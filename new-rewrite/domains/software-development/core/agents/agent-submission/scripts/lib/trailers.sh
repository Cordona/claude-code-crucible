# A working commit's trailers: written into commit-message.sh's input, and
# read back from a commit. Sourced, so it sets no shell option; its names
# start with tr_.
# shellcheck shell=sh

# Prints commit-message.sh's input for job file $1 (job-of.sh's output),
# report file $2 and effort folder name $3: kind the job's kind, the report's
# summary as summary, and the trailers Effort, Job (seq, then name), Iteration,
# Fix-Round (a fix only), then the dispatch's setup: Language, Framework
# (only with frameworks, joined by commas), Standards (joined the same way)
# and Model when the dispatch has one.
tr_message_input() {
	jq -n --slurpfile job "$1" --slurpfile report "$2" --arg effort "$3" '
		$job[0] as $j
		| {kind: $j.kind, summary: $report[0].summary,
		   trailers: ({effort: $effort, job: "\($j.job) \($j.name)"}
			+ (if $j | has("iteration") then {iteration: $j.iteration} else {} end)
			+ (if $j | has("fix_round") then {"fix-round": $j.fix_round} else {} end)
			+ ($j.setup | {language}
				+ (if (.frameworks // []) == [] then {} else {framework: (.frameworks | join(", "))} end)
				+ {standards: (.standards | join(", "))}
				+ (if has("model") then {model} else {} end)))}'
}

# Prints {kind, effort, job, name, iteration, fix_round?} read from commit
# $2 in repository folder $1: kind from the subject crucible(<kind>):, the
# rest from the Effort, Job, Iteration and Fix-Round trailers; nothing when
# the commit has no such subject or Job trailer. Fails when git can't read
# the commit.
tr_read() {
	tr_message=$(git -C "$1" log -1 --format=%B "$2" --) || return 1
	tr_subject=${tr_message%%"
"*}
	printf '%s\n' "${tr_message}" | git -C "$1" interpret-trailers --parse \
		| jq -R -s --arg subject "${tr_subject}" '
			[split("\n")[] | capture("^(?<key>[A-Za-z-]+): (?<value>.*)$")] as $lines
			| def value($key): [$lines[] | select(.key == $key) | .value] | last;
			  (value("Job") // "" | capture("^(?<job>[1-9][0-9]*) (?<name>\\S+)$")) as $job
			| {kind: ($subject | capture("^crucible\\((?<kind>[a-z-]+)\\): ").kind),
			   effort: value("Effort"), job: ($job.job | tonumber), name: $job.name,
			   iteration: (value("Iteration") | tonumber? // null)}
			+ (if value("Fix-Round") then {fix_round: (value("Fix-Round") | tonumber)} else {} end)'
}
