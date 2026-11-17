#!/usr/bin/env sh
# A rule of report-commit-hook.sh: it blocks a tester's stop while its
# mutation copy (../../../mutation/mutation-copy.sh) still exists, so code
# broken on purpose never outlives the tester's run.
set -eu

readonly PROG='mutation-copy.sh'
readonly COPY_FOLDER='mutation'
# From this folder to the script that opens and removes the copy.
readonly COPY_SCRIPT='../../../mutation/mutation-copy.sh'
LC_ALL=C
export LC_ALL

usage() {
	cat <<EOF
usage: sh ${PROG} --effort FOLDER --seat S
       sh ${PROG} --help | -h

A rule of report-commit-hook.sh. Looks for seat S's mutation copy,
<effort>/drafts/agents/<S>/${COPY_FOLDER}, a symbolic link there included.

stdout: one line when it exists, "Your mutation copy <path> is still
  there: remove it once your mutations are done: sh <script> remove
  --effort <effort> --seat <S>", <script> ${COPY_SCRIPT##*/}'s absolute
  path, control characters as "?"; nothing otherwise. Writes nothing.

exit codes:
  0  no mutation copy
  1  wrong command line
  3  the copy exists; stdout says so
  4  could not check (stderr says why): --effort not absolute, or S no
     seat name

needs: POSIX sh; ${COPY_SCRIPT} from this script's folder (named, not run)
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

fault() {
	warn "$1"
	exit 4
}

usage_error() {
	warn "$1"
	printf "Try 'sh %s --help'.\n" "${PROG}" >&2
	exit 1
}

parse_args() {
	effort_folder='' seat=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--effort | --seat)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 VALUE"
				if [ "$1" = --effort ]; then
					[ -z "${effort_folder}" ] || usage_error '--effort given twice; expected it once'
					effort_folder=$2
				else
					[ -z "${seat}" ] || usage_error '--seat given twice; expected it once'
					seat=$2
				fi
				shift 2
				;;
			*) usage_error 'unknown option; expected --effort FOLDER, --seat S or --help' ;;
		esac
	done
	[ -n "${effort_folder}" ] || usage_error '--effort is missing; expected --effort FOLDER'
	[ -n "${seat}" ] || usage_error '--seat is missing; expected --seat S'
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

parse_args "$@"
case ${effort_folder} in
	/*) ;;
	*) fault '--effort is not absolute; expected the effort folder, absolute' ;;
esac
case ${seat} in
	*[!a-z0-9-]* | -*) fault '--seat is no seat name; expected one like test-agent-alpha' ;;
	*) ;;
esac
while [ "${effort_folder}" != "${effort_folder%/}" ]; do effort_folder=${effort_folder%/}; done
copy="${effort_folder}/drafts/agents/${seat}/${COPY_FOLDER}"
[ -e "${copy}" ] || [ -L "${copy}" ] || exit 0
own_path=$(script_dir)
own_dir=$(cd -P -- "${own_path}" && pwd -P) || fault 'this script'\''s folder could not be entered'
copy_script="${own_dir}/${COPY_SCRIPT}"
copy_dir=$(cd -P -- "${copy_script%/*}" 2>/dev/null && pwd -P) && copy_script="${copy_dir}/${copy_script##*/}"
printf 'Your mutation copy %s is still there: remove it once your mutations are done: sh %s remove --effort %s --seat %s' \
	"${copy}" "${copy_script}" "${effort_folder}" "${seat}" | tr '[:cntrl:]' '?'
printf '\n'
exit 3
