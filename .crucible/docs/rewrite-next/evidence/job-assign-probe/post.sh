#!/bin/sh
in=$(cat); d=$(dirname "$0")
printf '%s\n' "$in" > "$(mktemp "$d/logs/post-XXXXXX")"
exit 0
