# The context file's path checks and its digest, the one definition context.sh
# and every script that reads a context file share.
# Sourced, so it sets no shell option; its variables start with context_.

# The context file's size cap, the one prepare-agent-prompt.sh applies:
# references and a few notes fit far below it.
# shellcheck disable=SC2034 # read by the scripts that source this file
context_max_bytes=65536

# The basenames of key and credential files, as lowercase globs matched in any
# letter case, separated by single spaces: the one list the path check, the
# diff's git excludes and the scripts' help texts are built from.
context_sensitive_names='.env* *.pem *.key *.crt *.cer id_* credentials* *.p12 *.pfx *.jks *.keystore .netrc .pgpass .npmrc .pypirc'

# Calls function $1 with each name of context_sensitive_names in order; stops
# and fails at the first call that fails. The names are never glob-expanded.
context_each_sensitive_name() {
	context_names_rest=${context_sensitive_names}
	while [ -n "${context_names_rest}" ]; do
		context_name=${context_names_rest%% *}
		case ${context_names_rest} in
			*' '*) context_names_rest=${context_names_rest#* } ;;
			*) context_names_rest='' ;;
		esac
		"$1" "${context_name}" || return 1
	done
}

# Appends name $1 to context_sensitive_names_text, comma separated.
context_append_name_text() {
	context_sensitive_names_text=${context_sensitive_names_text:+${context_sensitive_names_text}, }$1
}

# The sensitive names as one line of text, for the scripts' "expected" and
# help texts.
context_sensitive_names_text=''
context_each_sensitive_name context_append_name_text

# What a context path must be, for the scripts' "expected" texts.
# The ${...} in it is the rule's text, never expanded.
# shellcheck disable=SC2016,SC2034 # read by the scripts that source this file
context_path_expected='an absolute path without control characters, quotes or .. segments, not naming a sensitive file in any letter case (a basename '"${context_sensitive_names_text}"', a .git or .ssh component, or a .docker/config.json), and context, not instructions: no basename CLAUDE.md or SKILL.md in any letter case, and nothing under ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/ or agents/, and not a Claude settings file, which can hold secrets: no ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json and no basename settings.local.json, in any letter case'

# Prints the first problem of context path $1, or nothing when the file may be
# read. The checks use the text only, so they run before anything is opened.
# Sensitive and instruction names match in any letter case, as the default
# macOS file system opens .ENV or /.GIT/ as .env or /.git/. With no quote of
# either kind, a path is always safe inside a single-quoted shell word.
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
		*\'*) printf 'path holds a single quote' ;;
		*/../* | */..) printf 'path has a .. segment' ;;
		*/.[gG][iI][tT]/* | */.[gG][iI][tT]) printf 'path names a sensitive file' ;;
		*/.[sS][sS][hH]/* | */.[sS][sS][hH]) printf 'path names a sensitive file' ;;
		*/.[dD][oO][cC][kK][eE][rR]/[cC][oO][nN][fF][iI][gG].[jJ][sS][oO][nN]) printf 'path names a sensitive file' ;;
		*)
			if context_name_is_sensitive "${1##*/}"; then
				printf 'path names a sensitive file'
				return 0
			fi
			case ${1##*/} in
				[cC][lL][aA][uU][dD][eE].[mM][dD] | [sS][kK][iI][lL][lL].[mM][dD]) printf 'path names a file of instructions for Claude' ;;
				[sS][eE][tT][tT][iI][nN][gG][sS].[lL][oO][cC][aA][lL].[jJ][sS][oO][nN]) printf 'path names a Claude settings file' ;;
				*) context_config_path_problem "$1" ;;
			esac
			;;
	esac
}

# Succeeds when basename $1, in lowercase, matches a sensitive name.
context_name_is_sensitive() {
	[ -n "$1" ] || return 1
	context_lowercase_name=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')
	# shellcheck disable=SC2310 # its status is the match result; errexit adds nothing
	! context_each_sensitive_name context_name_misses
}

# Succeeds when context_lowercase_name does not match glob $1.
context_name_misses() {
	# shellcheck disable=SC2254 # $1 is a glob from context_sensitive_names, matched as one
	case ${context_lowercase_name} in
		$1) return 1 ;;
		*) return 0 ;;
	esac
}

# Prints the git pathspecs, one per line, that leave out of a diff every file
# context_path_problem refuses by its basename, a .git or .ssh component or
# a .docker/config.json, in any letter case. The Claude config dir's
# settings.json depends on the repository, so the caller adds it.
context_excluded_pathspecs() {
	context_each_sensitive_name context_print_name_pathspec
	printf '%s\n' ':(exclude,icase,glob)**/.git' ':(exclude,icase,glob)**/.git/**' \
		':(exclude,icase,glob)**/.ssh' ':(exclude,icase,glob)**/.ssh/**' \
		':(exclude,icase,glob)**/.docker/config.json' \
		':(exclude,icase,glob)**/settings.local.json'
}

# Prints the git pathspec leaving out basename glob $1 in any folder.
context_print_name_pathspec() {
	printf ':(exclude,icase,glob)**/%s\n' "$1"
}

# Prints the problem of absolute path $1 when it is the skills/ or agents/
# folder of the Claude config dir, or under one, or that dir's settings.json,
# compared as text after empty and . segments are dropped; prints nothing
# otherwise.
context_config_path_problem() {
	context_config_dir=${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}
	while [ "${context_config_dir}" != "${context_config_dir%/}" ]; do
		context_config_dir=${context_config_dir%/}
	done
	context_compared_path=$1/
	while :; do
		case ${context_compared_path} in
			*//*) context_compared_path=${context_compared_path%%//*}/${context_compared_path#*//} ;;
			*/./*) context_compared_path=${context_compared_path%%/./*}/${context_compared_path#*/./} ;;
			*) break ;;
		esac
	done
	case ${context_compared_path} in
		"${context_config_dir}"/[sS][kK][iI][lL][lL][sS]/* | "${context_config_dir}"/[aA][gG][eE][nN][tT][sS]/*)
			printf 'path names a file of instructions for Claude'
			;;
		"${context_config_dir}"/[sS][eE][tT][tT][iI][nN][gG][sS].[jJ][sS][oO][nN]/)
			printf 'path names a Claude settings file'
			;;
		*) ;;
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
