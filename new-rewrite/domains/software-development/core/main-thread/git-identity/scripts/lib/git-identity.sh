# Shared by the git-identity scripts: the refusal line, core found as a
# neighbour skill, and the repository through dev-base.
# Sourced, so it sets no shell option; its names start with gi_.
# shellcheck shell=sh
# shellcheck disable=SC2154 # gi_prog is set by each sourcing script
# shellcheck disable=SC2034 # the gi_ values are read by the sourcing scripts

gi_refuse() {
	printf '%s: %s\n' "${gi_prog}" "$1" >&2
	exit 2
}

# Sets gi_skills, the skills folder holding this component, from the
# script's own path $1 as text, so a skill link holds.
gi_find_skills() {
	gi_self=$1
	case ${gi_self} in /*) ;; *) gi_self="$(pwd)/${gi_self}" ;; esac
	gi_skills=${gi_self%/*/*/*/*}
}

# Sets gi_skills from the script's own path $1, and gi_core_* to core's
# public scripts there. Refuses when core isn't beside this skill.
gi_find_core() {
	gi_find_skills "$1"
	gi_core_writer="${gi_skills}/crucible-events/scripts/internal/event-write.sh"
	gi_core_reader="${gi_skills}/crucible-events/scripts/internal/events-read.sh"
	gi_core_answer="${gi_skills}/crucible-gate/scripts/internal/gate-answer.sh"
	gi_core_state="${gi_skills}/crucible-effort/scripts/main/effort-state.sh"
	for gi_need in "${gi_core_writer}" "${gi_core_reader}" "${gi_core_answer}" "${gi_core_state}"; do
		[ -f "${gi_need}" ] || gi_refuse "core isn't beside this skill (expected ${gi_need}); install first"
	done
}

# Sets gi_repo to the repository folder $1 belongs to, its main checkout,
# as dev-base's repo-of.sh names it. Refuses a folder in no git repository,
# or in a bare one. Needs gi_skills.
gi_set_repo() {
	case $1 in /*) ;; *) gi_refuse "--repo must be an absolute folder" ;; esac
	gi_repo_of="${gi_skills}/dev-base/scripts/internal/repo-of.sh"
	[ -f "${gi_repo_of}" ] || gi_refuse "dev-base isn't beside this skill (expected ${gi_repo_of}); install first"
	gi_said=$(sh "${gi_repo_of}" --dir "$1" 2>&1) || gi_refuse "--repo ${gi_said#repo-of.sh: }"
	gi_repo=$(printf '%s' "${gi_said}" | jq -r '.repo')
}

# Prints the sha256 of file $1. Its own copy: the domain calls core's scripts
# by path and never sources core.
gi_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | cut -d ' ' -f 1
	else shasum -a 256 -- "$1" | cut -d ' ' -f 1; fi
}
