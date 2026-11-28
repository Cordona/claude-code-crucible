#!/bin/sh
# What is next for main, from the events: the same lines the held stop gives,
# from the same code. Owed lines first; else each new fact with its offer;
# else what is still working.
# usage: next.sh --effort DIR
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/cli.sh"
parse_opts "$@"
exec sh "$LAB/main-stop.sh" --next
