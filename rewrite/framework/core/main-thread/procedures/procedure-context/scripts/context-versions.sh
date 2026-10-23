# An effort's context versions and how its latest is found, the one definition
# context.sh and the dispatch scripts share.
# Sourced, so it sets no shell option; its variables start with context_version_.
# Its patterns are byte-wise only under LC_ALL=C, which every sourcing script sets.
# The ID and the effort folder name are the crucible skill's rules: source its
# scripts/lib/crucible-space.sh before this file.
# shellcheck shell=sh

# A longer version number is not a version file's, so the shell's arithmetic
# on it never overflows.
# shellcheck disable=SC2034 # read by the scripts that source this file
context_version_max_digits=9

# Sets context_version_number to N when file name $1 is a version file's,
# <YYYYMMDDTHHMMSS>-<4 lowercase hex>-v<N>.json with N from 1, no leading zero
# and at most context_version_max_digits digits; fails otherwise. The text and
# diff files (-v<N>-text, -diff-<sha>) are not version files.
context_version_of_name() {
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	crucible_split_id "$1" || return 1
	# shellcheck disable=SC2154 # set by crucible_split_id of crucible-space.sh, sourced first
	case ${crucible_name_rest} in
		v[1-9]*.json) ;;
		*) return 1 ;;
	esac
	context_version_number=${crucible_name_rest#v}
	context_version_number=${context_version_number%.json}
	case ${context_version_number} in
		*[!0-9]*) return 1 ;;
		*) ;;
	esac
	[ "${#context_version_number}" -le "${context_version_max_digits}" ]
}

# Sets context_version_latest to the path of the latest version file in
# folder $1 and context_version_latest_number to its N, both empty when it
# holds none. The latest has the highest N; of two with the same N, the one
# whose name sorts last (the later ID). Only regular files that are not
# symlinks count.
context_find_latest_version() {
	context_version_latest=''
	context_version_latest_number=''
	# The glob expands in byte order (LC_ALL=C), so on a tie the later name wins.
	for context_version_candidate in "$1"/*-v*.json; do
		[ -f "${context_version_candidate}" ] && [ ! -L "${context_version_candidate}" ] || continue
		# shellcheck disable=SC2310 # its status says whether the name is a version's
		context_version_of_name "${context_version_candidate##*/}" || continue
		if [ -z "${context_version_latest_number}" ] ||
			[ "${context_version_number}" -ge "${context_version_latest_number}" ]; then
			context_version_latest=${context_version_candidate}
			context_version_latest_number=${context_version_number}
		fi
	done
}

# Prints why context file $1 can't be used: it is a version file in an
# effort's context/ folder (<...>/efforts/<effort>/context/<id>-v<N>.json)
# that is not that effort's latest version. Prints nothing for the latest, and
# nothing for a file anywhere else: a context file outside an effort (legacy).
context_stale_version_problem() {
	# shellcheck disable=SC2310 # its status says whether the name is a version's
	context_version_of_name "${1##*/}" || return 0
	context_version_given_number=${context_version_number}
	context_version_dir=${1%/*}
	[ "${context_version_dir##*/}" = context ] || return 0
	context_version_effort=${context_version_dir%/*}
	# shellcheck disable=SC2310 # its status says whether the folder is an effort's
	crucible_is_effort_name "${context_version_effort##*/}" || return 0
	context_version_efforts=${context_version_effort%/*}
	[ "${context_version_efforts##*/}" = efforts ] || return 0
	context_find_latest_version "${context_version_dir}"
	[ -n "${context_version_latest}" ] || return 0
	[ "${context_version_latest##*/}" != "${1##*/}" ] || return 0
	printf 'is version v%s of its effort, not the latest (v%s: %s)' \
		"${context_version_given_number}" "${context_version_latest_number}" "${context_version_latest}"
}
