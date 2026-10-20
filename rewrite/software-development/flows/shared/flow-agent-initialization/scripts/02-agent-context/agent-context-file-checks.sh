# The context file's path checks and its digest, the one definition the
# flow's scripts share.
# Sourced, so it sets no shell option; its variables start with context_.

# The context file's size cap, the one prepare-agent-prompt.sh applies:
# references and a few notes fit far below it.
# shellcheck disable=SC2034 # read by the scripts that source this file
context_max_bytes=65536

# What a context path must be, for the scripts' "expected" texts.
# shellcheck disable=SC2034 # read by the scripts that source this file
context_path_expected='an absolute path without control characters, double quotes or .. segments, not naming a sensitive file in any letter case (.env*, *.pem, *.key, id_*, or a .git component)'

# Prints the first problem of context path $1, or nothing when the file may be
# read. The checks use the text only, so they run before anything is opened.
# Sensitive names match in any letter case, as the default macOS file system
# opens .ENV or /.GIT/ as .env or /.git/.
context_path_problem() {
	case $1 in
		/*) ;;
		*)
			printf 'path is not absolute'
			return 0
			;;
	esac
	case $1 in
		*[[:cntrl:]]*) printf 'path holds a control character' ;;
		*'"'*) printf 'path holds a double quote' ;;
		*/../* | */..) printf 'path has a .. segment' ;;
		*/.[gG][iI][tT]/* | */.[gG][iI][tT]) printf 'path names a sensitive file' ;;
		*)
			case ${1##*/} in
				.[eE][nN][vV]* | *.[pP][eE][mM] | *.[kK][eE][yY] | [iI][dD]_*) printf 'path names a sensitive file' ;;
				*) ;;
			esac
			;;
	esac
}

# Sets context_digest_tool to the sha256 command on PATH (sha256sum on Linux and
# newer macOS, shasum on older macOS); fails when there is neither.
find_context_digest_tool() {
	if command -v sha256sum >/dev/null 2>&1; then
		context_digest_tool=sha256sum
	elif command -v shasum >/dev/null 2>&1; then
		context_digest_tool=shasum
	else
		return 1
	fi
}

# Sets context_digest to the sha256 of file $1 as 64 lowercase hex digits;
# fails when the tool does or prints anything else. Run find_context_digest_tool first.
compute_context_digest() {
	compute_stdin_digest <"$1"
}

# Sets context_digest to the sha256 of stdin, as compute_context_digest does
# for a file.
compute_stdin_digest() {
	if [ "${context_digest_tool}" = shasum ]; then
		context_digest_output=$(shasum -a 256) || return 1
	else
		context_digest_output=$(sha256sum) || return 1
	fi
	context_digest=${context_digest_output%% *}
	[ "${#context_digest}" -eq 64 ] || return 1
	case ${context_digest} in
		*[!0-9a-f]*) return 1 ;;
		*) ;;
	esac
}
