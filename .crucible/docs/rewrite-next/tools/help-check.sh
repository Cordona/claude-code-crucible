#!/usr/bin/env sh
# Checks scripts' --help against the template in help-rule.md.
set -u

usage() {
	cat <<'USAGE'
usage: sh help-check.sh SCRIPT...

Checks each script's --help against the help template: the usage lines,
the section labels and their order, no Needs: section, an Exit: section,
the width, the length, that every option the script parses is in its help,
and that a script's folder matches its help: under scripts/internal/ the
help starts "Run by <caller>; not for main to call.", under scripts/main/
it doesn't and names no script under any scripts/internal/ of its framework
tree (the nearest folder above it holding framework/). A file with no #!
first line is a sourced library, with no command line and so no --help; it
is skipped, and its header comment is its contract.

Stdout:    one line per problem, "SCRIPT: problem"; nothing when all pass
Exit:
  0  every help passes
  1  a help has a problem
  2  refused: no script given
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; '') usage >&2; exit 2 ;; esac
bad=0
say() { printf '%s: %s\n' "$1" "$2"; bad=1; }

# The framework tree a script sits in: the nearest folder above it that holds
# framework/. Prints nothing when there is none.
framework_root() {
	d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 0
	while [ "$d" != / ]; do
		[ -d "$d/framework" ] && { printf '%s\n' "$d"; return 0; }
		d=$(dirname "$d")
	done
}

# The names of the scripts under any scripts/internal/ of a tree, one per line.
internal_names() {
	find "$1" -path '*/scripts/internal/*.sh' -type f | sed 's|.*/||' | sort -u
}
internal_root='' internal=''

for f in "$@"; do
	name=${f##*/}
	case $(head -c 2 "$f" 2>/dev/null) in '#!') ;; *) continue ;; esac
	help=$(sh "$f" --help 2>/dev/null); rc=$?
	[ "$rc" -eq 0 ] || { say "$f" "--help exits $rc"; continue; }
	first=$(printf '%s\n' "$help" | sed -n 1p)
	case $first in "usage: sh ${name}"*) ;; *) say "$f" "first line is not 'usage: sh ${name} ...'" ;; esac
	printf '%s\n' "$help" | grep -q "^       sh ${name} --help | -h\$" && say "$f" "usage line 'sh ${name} --help | -h' is noise: drop it"
	printf '%s\n' "$help" | grep -q '^Needs:' && say "$f" "a Needs: section: install facts never go in a help"
	printf '%s\n' "$help" | grep -q '^Exit:$' || say "$f" "no 'Exit:' section on a line of its own"
	n=$(printf '%s\n' "$help" | wc -l | tr -d ' ')
	[ "$n" -le 25 ] || say "$f" "help is ${n} lines (at most 25; aim for 15)"
	wide=$(printf '%s\n' "$help" | awk 'length > 80 { c++ } END { print c + 0 }')
	[ "$wide" -eq 0 ] || say "$f" "${wide} lines wider than 80"
	# Labels: known ones only, in the template's order.
	order=$(printf '%s\n' "$help" | grep -oE '^(Commands|Options|Requires|Reads|Writes|Stdout|Exit):' | tr -d ':' | tr '\n' ' ')
	printf '%s\n' "$help" | grep -E '^[A-Z][a-z]+:' | grep -vE '^(Commands|Options|Requires|Reads|Writes|Stdout|Exit|Needs):' \
		| while IFS= read -r l; do printf '%s: unknown label line: %s\n' "$f" "$l"; done | grep . && bad=1
	rank=0
	for l in ${order}; do
		case $l in Commands) r=1 ;; Options) r=2 ;; Requires) r=3 ;; Reads) r=4 ;; Writes) r=5 ;; Stdout) r=6 ;; Exit) r=7 ;; esac
		[ "$r" -gt "$rank" ] || say "$f" "label ${l}: out of order or repeated"
		rank=$r
	done
	# The folder against the first sentence after the usage lines, joined
	# across its wrapped lines: scripts/main/ is main's, scripts/internal/ not.
	said=$(printf '%s\n' "$help" | awk 'started && NF { line = line sep $0; sep = " " } started && !NF && line != "" { exit }
		!NF { started = 1 } END { print line }' | sed 's/\. .*/./')
	case $f in
		*/scripts/main/*)
			case $said in *'not for main'*) say "$f" "in scripts/main/, but its help says it is not for main" ;; esac
			root=$(framework_root "$f")
			if [ -n "${root}" ] && [ "${root}" != "${internal_root}" ]; then
				internal_root=${root} internal=$(internal_names "${root}")
			fi
			if [ -n "${root}" ]; then
				# Whole names only, a sentence's closing dot dropped.
				printf '%s\n' "$help" | grep -oE '[A-Za-z0-9_.-]+' | sed 's/\.*$//' | sort -u \
					| while IFS= read -r n; do
						printf '%s\n' "${internal}" | grep -qxF -- "$n" \
							&& printf '%s: in scripts/main/, but its help names the internal script %s\n' "$f" "$n"
					done | grep . && bad=1
			fi ;;
		*/scripts/internal/*)
			case $said in 'Run by '*'; not for main to call.') ;; *) say "$f" "in scripts/internal/, but its help does not start 'Run by <caller>; not for main to call.'" ;; esac ;;
	esac
	# Every option the script parses in a case pattern appears in its help.
	for o in $(grep -E '^[[:space:]]*(--?[a-z][a-z0-9-]*[[:space:]]*\|?[[:space:]]*)+\)' "$f" | grep -oE -- '--[a-z][a-z0-9-]*' | sort -u); do
		case $o in --help) continue ;; esac
		printf '%s\n' "$help" | grep -q -- "$o" || say "$f" "option $o is parsed but not in the help"
	done
done
exit "$bad"
