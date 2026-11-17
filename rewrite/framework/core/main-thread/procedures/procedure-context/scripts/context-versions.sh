# An effort's context versions, each a context.cut event in its events/, and
# how its latest is found, the one definition context.sh and the dispatch
# scripts share.
# Sourced, so it sets no shell option; its variables start with context_version_.
# Its patterns are byte-wise only under LC_ALL=C, which every sourcing script sets.
# The effort folder name is the crucible skill's rule: source its
# scripts/lib/crucible-space.sh before this file.
# shellcheck shell=sh

# A longer version number is not a version's, so the shell's arithmetic on
# it never overflows.
# shellcheck disable=SC2034 # read by the scripts that source this file
context_version_max_digits=9

# Succeeds when file name $1 is a context.cut event's, <6 digits>-context.cut.json,
# as events.sh names it; fails otherwise.
context_version_of_name() {
	case $1 in
		[0-9][0-9][0-9][0-9][0-9][0-9]-context.cut.json) ;;
		*) return 1 ;;
	esac
}

# Sets context_version_latest to the path of the newest context.cut event in
# events folder $1 and context_version_latest_number to how many there are,
# which is its version, as each cut takes the next number; both empty when it
# holds none. With a file name $2, context_version_given_number is that
# event's version (its place among them), empty when it is none of them. Only
# regular files that are not symlinks count.
context_find_latest_version() {
	context_version_latest='' context_version_latest_number='' context_version_given_number=''
	context_version_count=0
	# The glob expands in byte order (LC_ALL=C), so the 6-digit seq orders it.
	for context_version_candidate in "$1"/[0-9][0-9][0-9][0-9][0-9][0-9]-context.cut.json; do
		[ -f "${context_version_candidate}" ] && [ ! -L "${context_version_candidate}" ] || continue
		context_version_count=$((context_version_count + 1))
		context_version_latest=${context_version_candidate}
		[ "${context_version_candidate##*/}" != "${2:-}" ] || context_version_given_number=${context_version_count}
	done
	[ "${context_version_count}" -eq 0 ] || context_version_latest_number=${context_version_count}
}

# Sets context_version_stale to why context event $1 can't be used: it is a
# context.cut event in an effort's events/ folder
# (<...>/efforts/<effort>/events/<seq>-context.cut.json) that is not that
# effort's newest, which context_version_latest then names. Empty for the
# newest, and for a file anywhere else, which the read checks refuse first.
context_stale_version_problem() {
	context_version_stale=''
	# shellcheck disable=SC2310 # its status says whether the name is a version's
	context_version_of_name "${1##*/}" || return 0
	context_version_dir=${1%/*}
	[ "${context_version_dir##*/}" = events ] || return 0
	context_version_effort=${context_version_dir%/*}
	# shellcheck disable=SC2310 # its status says whether the folder is an effort's
	crucible_is_effort_name "${context_version_effort##*/}" || return 0
	context_version_efforts=${context_version_effort%/*}
	[ "${context_version_efforts##*/}" = efforts ] || return 0
	context_find_latest_version "${context_version_dir}" "${1##*/}"
	[ -n "${context_version_latest}" ] || return 0
	[ "${context_version_latest##*/}" != "${1##*/}" ] || return 0
	context_version_stale="is version v${context_version_given_number:-?} of its effort, not the latest (v${context_version_latest_number}: ${context_version_latest})"
}
