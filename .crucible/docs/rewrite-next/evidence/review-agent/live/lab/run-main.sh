#!/bin/sh
# Runs headless main once in the sandbox repo, on the main prompt for kind
# $1; bypass mode, inside this sandbox only. Logs to run/logs/main-$1.*.
set -eu
L=$(cd "$(dirname "$0")/.." && pwd)
RUN="${L}/run"
. "${RUN}/vars"
export CLAUDE_CONFIG_DIR=/Users/Shared/crucible-sandbox/event-jobs/cfg CRUCIBLE_HOME="${RUN}/space" LIVE="${RUN}" LIVE_EFFORT="${effort}"
unset CLAUDE_CODE_SESSION_ID
cd "${repo}"
rc=0
claude -p "$(cat "${RUN}/main-prompt-$1.txt")" --permission-mode bypassPermissions --output-format stream-json --verbose \
	>"${RUN}/logs/main-$1.jsonl" 2>"${RUN}/logs/main-$1.err" || rc=$?
echo "main exit ${rc}" >>"${RUN}/logs/main-$1.err"
