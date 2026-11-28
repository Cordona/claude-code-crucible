#!/usr/bin/env sh
# Checks that a link is a plain http(s) link of safe characters, and prints
# its parts, so no script puts anything else on a tool's command line.
set -eu

usage() {
	cat <<'USAGE'
usage: sh safe-link.sh --url URL

Run by the domain's scripts; not for main to call.
Takes only a plain http(s) link of letters, digits and . _ ~ / ? # = % : + , @ -.

Options:
  --url URL  the link
Stdout:    one JSON line {authority, host, path}: authority the host and
           any port, lowercased; host without the port; path without the
           query or fragment, "" for none
Exit:
  0  accepted
  2  refused, nothing printed; the reason is on stderr
USAGE
}

readonly PROG='safe-link.sh'
refuse() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
	exit 2
}

url='' given=no
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--url)
			[ $# -ge 2 ] || refuse '--url needs a value; try --help'
			[ "${given}" = no ] || refuse '--url given twice; try --help'
			url=$2 given=yes
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
[ -n "${url}" ] || refuse '--url missing; try --help'
command -v jq >/dev/null 2>&1 || refuse 'jq missing; expected jq 1.6 or later on PATH'

printf '%s' "${url}" | grep -Eq '^[Hh][Tt][Tt][Pp][Ss]?://[A-Za-z0-9.-]+(:[0-9]+)?([/?#][A-Za-z0-9._~/?#=%:+,@-]*)?$' \
	|| refuse 'the URL is not of the accepted form; expected an http(s) link of letters, digits and . _ ~ / ? # = % : + , @ - only'
# One line only: grep matches line by line, so a newline must not slip by.
case ${url} in *"
"*) refuse 'the URL holds a line break' ;; *) ;; esac

rest=${url#*://}
authority=$(printf '%s' "${rest%%[/?#]*}" | tr '[:upper:]' '[:lower:]')
path=${rest#"${rest%%[/?#]*}"}
path=${path%%[?#]*}
jq -cn --arg authority "${authority}" --arg host "${authority%%:*}" --arg path "${path}" '{authority: $authority, host: $host, path: $path}'
