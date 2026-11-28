# A job agent's base, from its agent type, in one home: every hook that
# meets a job agent's tool call or stop asks it first. Reads no event, so
# every other agent passes cheaply. Sourced, so it sets no shell option;
# its names start with at_.
# shellcheck shell=sh

# Prints the base agent of agent type $1 among the components in folder
# $2: the type itself when it is a base (a component with submissions/),
# or the base it starts with and a dash (an agent file agent-files.sh
# wrote, named for its base). Fails for any other type.
at_base() {
	case $1 in '' | *[!a-z0-9-]*) return 1 ;; *) ;; esac
	if [ -d "$2/$1/submissions" ]; then printf '%s\n' "$1"; return 0; fi
	for at_sub in "$2"/*/submissions; do
		[ -d "${at_sub}" ] || continue
		at_name=${at_sub%/submissions}
		at_name=${at_name##*/}
		case $1 in "${at_name}"-*) printf '%s\n' "${at_name}"; return 0 ;; *) ;; esac
	done
	return 1
}
