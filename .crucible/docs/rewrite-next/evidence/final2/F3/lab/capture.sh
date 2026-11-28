#!/bin/sh
# Hook-output capture, sandbox only: capture.sh TAG HOOK_SCRIPT. Runs the
# hook unchanged on the same stdin, prints its stdout and returns its exit,
# and saves one file per call under $MATRIX_CAPTURE: {tag, hook, t_start,
# t_end, input, stdout, exit}. Nothing here reads a transcript.
tag=$1 hook=$2
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
t0=$(now)
dir=${MATRIX_CAPTURE:-/Users/Shared/crucible-sandbox/final2/real/capture-unset}
mkdir -p "${dir}"
f=$(mktemp "${dir}/${tag}-${t0}-XXXXXX")
cat >"${f}.in"
rc=0
sh "${hook}" <"${f}.in" >"${f}.out" 2>"${f}.err" || rc=$?
cat "${f}.out"
t1=$(now)
jq -n --arg tag "${tag}" --arg hook "${hook}" --argjson t0 "${t0}" --argjson t1 "${t1}" --argjson rc "${rc}" \
	--rawfile in "${f}.in" --rawfile out "${f}.out" --rawfile err "${f}.err" \
	'{tag: $tag, hook: $hook, t_start: $t0, t_end: $t1, exit: $rc,
	  input: ($in | fromjson? // $in), stdout: ($out | fromjson? // $out), stderr: $err}' >"${f}.json" 2>/dev/null \
	&& rm -f "${f}" "${f}.in" "${f}.out" "${f}.err"
exit "${rc}"
