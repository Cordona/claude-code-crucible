#!/usr/bin/env sh
# Copies, copy-on-write, what a plan from setup-plan.sh says into the fresh
# tree. Never overwrites, never copies through a folder that leads outside
# the tree, and reads no copied file.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh setup-copy.sh --plan FILE

Run by worktree-setup.sh; not for main to call.
Copies a setup-plan.sh plan's "copy" items from its checkout into its tree.

Options:
  --plan FILE  the JSON setup-plan.sh printed
Writes:    the copied items and their parent folders, only inside the tree
Stdout:    one JSON line {method, done: [{did, path, technology?, target?}]};
           method is cp -c, reflink or plain; path is relative to the tree;
           did is copied (technology when the plan named one), exists (left
           alone), tracked (not copied), unignored (a secret-shaped file git
           doesn't ignore, left out) or flag (a kept absolute symlink into
           the checkout, its target in target)
Exit:
  0  every item handled
  2  refused, nothing changed; the reason is on stderr
  4  some items not copied, the rest were, stdout printed; or a tool is
     missing, nothing done, no stdout; reasons on stderr
USAGE
}

gw_prog='setup-copy.sh'
readonly TAB='	'
. "$(dirname -- "$0")/../lib/git-worktree.sh"

# Sets method to the fastest copy this system makes: a clone, a reflink, or
# a plain copy.
choose_method() {
	probe="${gw_work}/probe"
	: >"${probe}"
	system=$(uname -s)
	if [ "${system}" = Darwin ] && cp -c -- "${probe}" "${probe}.clone" 2>/dev/null; then
		method='cp -c'
	elif cp --reflink=auto -- "${probe}" "${probe}.reflink" 2>/dev/null; then
		method=reflink
	else
		method=plain
	fi
}

apply_items() {
	while IFS="${TAB}" read -r item technology path; do
		case ${item} in
			tracked) record tracked "${path}" ;;
			copy)
				check_secret "${path}"
				if [ "${secret_unignored}" = yes ]; then
					record unignored "${path}"
				else
					copy_item "${technology}" "${path}"
				fi
				;;
			*) gw_add_problem "${path} was not copied: its name holds a control character; expected printable names" ;;
		esac
	done <"${gw_work}/items"
}

# Notes thing $1 done to path $2, with technology or link target $3.
record() {
	printf '%s\t%s\t%s\n' "$1" "$2" "${3-}" >>"${gw_work}/done"
}

# Sets secret_unignored to yes when path $1 is secret-shaped and git does not
# confirm the tree ignores it: a commit of the tree stages every file git sees.
check_secret() {
	secret_unignored=no
	case ${1##*/} in
		.env | .env.* | auth.json | .npmrc | local.properties) ;;
		*) return 0 ;;
	esac
	git -C "${to_root}" check-ignore -q -- "$1" 2>/dev/null || secret_unignored=yes
}

# Copies path $2 found for technology $1 ("-" for none), then flags its
# absolute links into the checkout.
copy_item() {
	check_parent "$2"
	if [ "${parent_inside_to}" = no ]; then
		gw_add_problem "$2 was not copied: its folder in --to is not a folder inside --to; expected one"
		return 0
	fi
	target="${to_root}/$2"
	if [ -e "${target}" ] || [ -L "${target}" ]; then
		record exists "$2"
		return 0
	fi
	case $2 in
		*/*) mkdir -p -- "${to_root}/${2%/*}" || {
			gw_add_problem "$2 was not copied: mkdir could not create its folder in --to; expected a writable --to"
			return 0
		} ;;
		*) ;;
	esac
	copy_path "${from_root}/$2" "${target}"
	if [ "${copy_failed}" = yes ]; then
		gw_add_problem "$2 was not copied: cp (${method}) failed; expected a readable source and free space"
		return 0
	fi
	record copied "$2" "$1"
	flag_links "$2"
}

# Sets parent_inside_to to yes when the nearest existing folder above path
# $1 in --to is physically inside --to, so a tracked link can't send a copy
# elsewhere; to no otherwise.
check_parent() {
	parent_inside_to=yes
	parent=$1
	while :; do
		case ${parent} in
			*/*) parent=${parent%/*} ;;
			*) return 0 ;;
		esac
		[ ! -e "${to_root}/${parent}" ] && [ ! -L "${to_root}/${parent}" ] || break
	done
	physical_parent=$(cd -P -- "${to_root}/${parent}" 2>/dev/null && pwd -P) || physical_parent=''
	case ${physical_parent} in
		"${to_root}" | "${to_root}"/*) ;;
		*) parent_inside_to=no ;;
	esac
}

# Copies keeping links as links (-P) and modes and times (-p), so build
# tools judging freshness by time see the copy as current; sets copy_failed.
copy_path() {
	copy_failed=no
	case ${method} in
		'cp -c') cp -c -R -P -p -- "$1" "$2" || copy_failed=yes ;;
		reflink) cp -R -P -p --reflink=auto -- "$1" "$2" || copy_failed=yes ;;
		*) cp -R -P -p -- "$1" "$2" || copy_failed=yes ;;
	esac
}

# Notes a flag per absolute link inside copied path $1 pointing into the
# checkout.
flag_links() {
	find "${to_root}/$1" -type l -lname '/*' -print0 >"${gw_work}/links0" 2>/dev/null ||
		printf '%s: find could not list every link in %s; some absolute links into --from may be unflagged\n' "${gw_prog}" "$1" >&2
	tr '\n\000' '\001\n' <"${gw_work}/links0" >"${gw_work}/links"
	while IFS= read -r link; do
		link_target=$(readlink -- "${link}" 2>/dev/null) || link_target=''
		# Matched without case, as macOS file systems do.
		lowered=$(printf '%s' "${link_target}" | tr '[:upper:]' '[:lower:]')
		case ${lowered} in
			"${from_root_lower}" | "${from_root_lower}"/* | "${from_given_lower}" | "${from_given_lower}"/*) ;;
			*) continue ;;
		esac
		record flag "$(gw_printable "${link#"${to_root}"/}")" "$(gw_printable "${link_target}")"
	done <"${gw_work}/links"
}

plan=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--plan) [ $# -ge 2 ] && [ -n "$2" ] || gw_refuse '--plan needs a value'; plan=$2; shift 2 ;;
		*) gw_refuse "unknown argument $(gw_printable "$1"); try --help" ;;
	esac
done
[ -n "${plan}" ] || gw_refuse '--plan needs a value: the file setup-plan.sh printed'
[ -f "${plan}" ] && [ -r "${plan}" ] || gw_refuse "--plan $(gw_printable "${plan}") is not a readable file"
command -v git >/dev/null 2>&1 || gw_fail 'git not found'
command -v jq >/dev/null 2>&1 || gw_fail 'jq not found'
gw_make_work
# A plan's folders are absolute, and its paths root-relative and printable,
# so each record below stays one line of tab-separated fields.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
jq -r 'def folder: type == "string" and startswith("/") and (test("[[:cntrl:]]") | not);
	def relative: type == "string" and length > 0 and (startswith("/") | not) and (test("[[:cntrl:]]") | not);
	if type == "object" and (.from | folder) and (.from_given | folder) and (.to | folder) and (.items | type) == "array"
		and all(.items[]; type == "object" and IN(.do; "copy", "tracked", "bad")
			and (if .do == "bad" then (.path | type) == "string" else (.path | relative) end)
			and (.technology == null or (.technology | relative)))
	then .from, .from_given, .to, (.items[] | "\(.do)\t\(.technology // "-")\t\(.path | gsub("[[:cntrl:]]"; "?"))")
	else error("not a plan") end' "${plan}" >"${gw_work}/plan" 2>/dev/null \
	|| gw_refuse "--plan $(gw_printable "${plan}") is not a plan setup-plan.sh prints"
{ IFS= read -r from_root; IFS= read -r from_given; IFS= read -r to_root; } <"${gw_work}/plan"
tail -n +4 "${gw_work}/plan" >"${gw_work}/items"
[ -d "${from_root}" ] || gw_refuse "the plan's checkout $(gw_printable "${from_root}") is not a folder"
[ -d "${to_root}" ] || gw_refuse "the plan's tree $(gw_printable "${to_root}") is not a folder"
[ ! "${from_root}" -ef "${to_root}" ] || gw_refuse "the plan's tree $(gw_printable "${to_root}") is its checkout"
from_root_lower=$(printf '%s' "${from_root}" | tr '[:upper:]' '[:lower:]')
from_given_lower=$(printf '%s' "${from_given}" | tr '[:upper:]' '[:lower:]')

choose_method
: >"${gw_work}/done"
apply_items
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
jq -Rnc --arg method "${method}" '{method: $method, done: [inputs | split("\t")
	| {did: .[0], path: .[1]} + (if .[0] == "copied" and .[2] != "-" then {technology: .[2]}
		elif .[0] == "flag" then {target: .[2]} else {} end)]}' "${gw_work}/done"
gw_exit_on_problems 4
