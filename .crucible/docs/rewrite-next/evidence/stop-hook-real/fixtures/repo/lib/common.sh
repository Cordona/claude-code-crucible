# shellcheck shell=sh
# Shared helpers for the scripts in bin/; sourced, so it sets nothing.
die() { printf '%s: %s\n' "${0##*/}" "$1" >&2; exit 1; }
warn() { printf '%s: %s\n' "${0##*/}" "$1" >&2; }
is_uint() { case $1 in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }
