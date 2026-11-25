#!/bin/sh
# The stand-in agents' one tool, sandbox only. Every recipe step is one call:
#   act.sh recipe FILE         print a job's recipe
#   act.sh put SRC DST         copy a prepared report SRC to DST (mkdir -p)
#   act.sh move SRC DST        move a report written at the wrong path
#   act.sh edit FILE TEXT      append one line to a file in a tree
#   act.sh undo TREE FILE      undo the change to FILE in TREE
#   act.sh sleep SECONDS       be busy for that long
#   act.sh note FILE TEXT      append a line to a scratch file (S10)
# Every path must be under the sandbox folder.
set -eu
SB=/Users/Shared/crucible-sandbox/stop-hook-matrix
inside() { case $1 in "${SB}"/*) case $1 in *..*) return 1 ;; *) return 0 ;; esac ;; *) return 1 ;; esac; }
need() { for p in "$@"; do inside "$p" || { echo "act.sh: $p is outside the sandbox" >&2; exit 2; }; done; }
op=${1-}; shift || true
case ${op} in
	recipe) need "$1"; cat -- "$1" ;;
	put) need "$1" "$2"; mkdir -p "${2%/*}"; cp -- "$1" "$2"; echo "written: $2" ;;
	move) need "$1" "$2"; mkdir -p "${2%/*}"; mv -- "$1" "$2"; echo "moved to: $2" ;;
	edit) need "$1"; printf '%s\n' "$2" >>"$1"; echo "edited: $1" ;;
	undo) need "$1"; if git -C "$1" ls-files --error-unmatch -- "$2" >/dev/null 2>&1; then git -C "$1" checkout -q -- "$2"; else rm -f -- "$1/$2"; fi; echo "undone: $2" ;;
	sleep) perl -e "sleep $1"; echo "slept $1 s" ;;
	note) need "$1"; mkdir -p "${1%/*}"; printf '%s\n' "$2" >>"$1"; echo "noted" ;;
	*) echo 'usage: act.sh recipe|put|move|edit|undo|sleep|note ...' >&2; exit 2 ;;
esac
