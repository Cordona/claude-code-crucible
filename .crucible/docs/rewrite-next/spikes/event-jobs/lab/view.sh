#!/bin/sh
# Spike: an effort's events in the lab's shape, as one JSON array.
# usage: view.sh --effort DIR
set -eu
LAB=$(cd "$(dirname "$0")" && pwd)
[ "${1:-}" = --effort ] && [ -n "${2:-}" ] || { echo "usage: view.sh --effort DIR" >&2; exit 1; }
EFFORT=$2
. "$LAB/lib.sh"
all_events
