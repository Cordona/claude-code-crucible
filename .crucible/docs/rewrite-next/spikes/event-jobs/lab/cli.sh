# Spike: option parsing, event queries and event writing for the lab's
# scripts. Sourced after LAB is set; sources lib.sh once the effort is known.

die() { echo "$(basename "$0"): $2" >&2; exit "$1"; }

# --name value sets opt_name; a --name with no value after it sets opt_name=1.
parse_opts() {
	while [ $# -gt 0 ]; do
		case "$1" in --?*) ;; *) die 1 "unexpected argument: $1" ;; esac
		name=$(printf '%s' "${1#--}" | tr - _)
		case "$name" in *[!a-z_]*) die 1 "bad option: $1" ;; esac
		if [ $# -gt 1 ] && case "$2" in --*) false ;; *) true ;; esac; then
			eval "opt_$name=\$2"; shift 2
		else
			eval "opt_$name=1"; shift
		fi
	done
	# --help: the script's header comment, which is its usage
	if [ -n "${opt_help:-}" ]; then
		sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "$0"; exit 0
	fi
	EFFORT=${opt_effort:-${EFFORT:-}}
	[ -n "$EFFORT" ] || die 1 "--effort is required"
	SESSION=${opt_session:-${CLAUDE_CODE_SESSION_ID:-${LAB_SESSION:-main}}}
	# the running session, when it is known: an agent of another one is gone
	RUNNING=${opt_session:-${CLAUDE_CODE_SESSION_ID:-}}
	export EFFORT
	. "$LAB/lib.sh"
}

need_seq() { # name value
	case "$2" in '' | *[!0-9]*) die 1 "--$1 must be a seq" ;; esac
}

# evq [jq options] FILTER: runs FILTER, with ev.jq included, over every event
evq() {
	all_events | jq -c -L "$LAB" -L "$LAB/real/crucible-jobs/lib" "$@"
}

# write TYPE ROOT ROUND JOB BODY: one event through ev.sh; prints its seq
write() {
	"$EV" --effort "$EFFORT" --session "$SESSION" --by "$(basename "$0")" --type "$1" --root "$2" --round "$3" --job "$4" --body "$5"
}

refusal() { # the refusal object; nothing is written
	printf '%s\n' "$1"
	exit 4
}

# list_json "a,b,c": a JSON array of strings; empty gives []
list_json() {
	jq -nc --arg s "$1" '$s | split(",") | map(select(length > 0))'
}

# dispatch_job ROOT ROUND BODY: writes one job.dispatched with its report
# path (a token known before the write) and the fixture's act for the nth
# job of its kind (acts/<kind>-<n>.json), then prints the call main must make
dispatch_job() {
	token=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
	kind=$(printf '%s' "$3" | jq -r .kind)
	nth=$(evq --arg k "$kind" '[.[] | select(.type == "job.dispatched" and .body.kind == $k)] | length + 1')
	act='{}'
	[ ! -f "$EFFORT/acts/$kind-$nth.json" ] || act=$(jq -c . "$EFFORT/acts/$kind-$nth.json")
	body=$(printf '%s' "$3" | jq -c --arg rep "$EFFORT/reports/$token.json" --argjson act "$act" '. + {report: $rep, act: $act}')
	seq=$(write job.dispatched "$1" "$2" null "$body") || return
	jq -nc --arg p "$(event_path "$seq")" --argjson b "$body" '
		if $b.delivery == "hot" then {call: "SendMessage", to: $b.hot_agent, message: "JOB: \($p)"}
		else {call: "Agent", subagent_type: $b.agent_type, run_in_background: true, prompt: "JOB: \($p)"} end'
}

# recheck STATUS: after a write failed, prints the step's own refusal when a
# rerun of the script's plan_step now finds one (the writer's rule refused a
# repeat another caller won); otherwise exits with the write's status
recheck() {
	again=$(plan_step)
	printf '%s' "$again" | jq -e .ok >/dev/null || refusal "$again"
	exit "$1"
}
