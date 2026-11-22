# A file replaced whole or not at all, in one home. It never refuses and
# sets no trap of the caller's: the caller words its own refusal.
# Sourced, so it sets no shell option; its names start with aw_.
# shellcheck shell=sh

# Replaces file $1 with stdin, through a temp file beside it. Returns 1, the
# file untouched and no temp left, when the write fails.
aw_write() (
	aw_temp=$(mktemp "${1%/*}/.tmp.XXXXXX") || exit 1
	if cat >"${aw_temp}" && mv -f -- "${aw_temp}" "$1"; then exit 0; fi
	rm -f -- "${aw_temp}"
	exit 1
)
