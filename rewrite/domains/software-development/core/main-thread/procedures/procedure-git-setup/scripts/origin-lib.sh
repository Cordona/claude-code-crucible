# Sourced by settings.sh, render-git-setup.sh and render-identity.sh, never
# run: whether a --repo is a git work tree, and whether it has the remote an
# effort pushes to. Uses the sourcing script's die and printable, and expects
# it to have unset git's repository overrides (GIT_DIR and the like); sets no
# shell option of its own.
# shellcheck shell=sh
# shellcheck disable=SC2034 # the sourcing scripts read repo_has_origin and shown_repo

# Sets shown_repo, or exits 3 when $1 is no absolute path to a git work tree.
check_repo() {
	shown_repo=$(printable "$1")
	case $1 in
		*[[:cntrl:]]*) die 3 "--repo ${shown_repo} holds a control character; expected a plain path" ;;
		/*) ;;
		*) die 3 "--repo ${shown_repo} is not absolute; expected an absolute path" ;;
	esac
	inside=$(git -C "$1" -c core.fsmonitor=false rev-parse --is-inside-work-tree 2>/dev/null) || inside=''
	[ "${inside}" = true ] ||
		die 3 "--repo ${shown_repo} is not a git work tree; expected the repository the session runs in; try git -C DIR status"
}

# Sets repo_has_origin to yes or no for whether repo $1 has remote $2, the
# one settings.jq's settings_remote names, after check_repo.
check_repo_origin() {
	check_repo "$1"
	if git -C "$1" -c core.fsmonitor=false remote get-url "$2" >/dev/null 2>&1; then
		repo_has_origin=yes
	else
		repo_has_origin=no
	fi
}
