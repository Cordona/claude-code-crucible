#!/usr/bin/env sh
#
# unit-driver.sh — source inspect-project's lib/ units and invoke ONE function
#                  directly, with the polling constants overridable.
#
# WHY THIS EXISTS, and why it is used for exactly one thing. Every other test in
# this suite drives the real CLI, because that is inspect-project's public
# contract. One property cannot be reached that way in bounded time: the
# compute-engine poll's UPPER BOUND. The production constants are 90 attempts at a
# 2-second interval, so an e2e test of "the poll really does stop" would take three
# minutes, and lib/runtime.sh sets both constants unconditionally at source time,
# so no environment variable can shrink them from outside.
#
# This driver sources the units exactly as inspect-project.sh does, in the same
# order, then lets a test override the two constants before calling the REAL
# sonar_wait_for_task. Nothing is faked: the function under test, the units around
# it, and the curl boundary are all the production ones.
#
# It is a test entry point, not a fake — the distinction that matters is that it
# replaces main(), never a collaborator.
#
# Usage:  unit-driver.sh LIB_DIR FUNCTION [ARGS...]
# Environment:
#   UNIT_SONAR_HOST                the base URL sonar_curl builds requests against
#   UNIT_SONAR_POLL_MAX_ATTEMPTS   override SONAR_POLL_MAX_ATTEMPTS
#   UNIT_SONAR_POLL_INTERVAL       override SONAR_POLL_INTERVAL
#
# shellcheck disable=SC2034  # file-wide: the globals set below are read by the units sourced in the loop, which shellcheck cannot follow — the same situation inspect-project.sh's own parse loop carries this directive for
set -eu

LC_ALL=C
export LC_ALL

PROG=unit-driver

UD_LIB=$1
shift

for ud_unit in runtime.sh usage.sh gitscope.sh intellij.sh sonar.sh output.sh menu.sh; do
	[ -r "$UD_LIB/$ud_unit" ] || {
		printf '%s: missing unit: %s\n' "$PROG" "$UD_LIB/$ud_unit" >&2
		exit 1
	}
	# shellcheck disable=SC1090  # the path is a loop variable, exactly as in inspect-project.sh's own sourcing loop
	. "$UD_LIB/$ud_unit"
done

ensure_workdir

SONAR_HOST=${UNIT_SONAR_HOST:-$SONAR_HOST_URL_DEFAULT}
[ -z "${UNIT_SONAR_POLL_MAX_ATTEMPTS:-}" ] || SONAR_POLL_MAX_ATTEMPTS=$UNIT_SONAR_POLL_MAX_ATTEMPTS
[ -z "${UNIT_SONAR_POLL_INTERVAL:-}" ] || SONAR_POLL_INTERVAL=$UNIT_SONAR_POLL_INTERVAL

ud_function=$1
shift
"$ud_function" "$@"
