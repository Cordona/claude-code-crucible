# The sha256 of a file, in one home.
# Sourced, so it sets no shell option; its names start with sh_.
# shellcheck shell=sh

# Prints the sha256 of file $1, 64 lowercase hex digits.
sh_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | cut -d ' ' -f 1
	else shasum -a 256 -- "$1" | cut -d ' ' -f 1; fi
}
