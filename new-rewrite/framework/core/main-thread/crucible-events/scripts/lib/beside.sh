# The one rule for "beside": a component's neighbours are the folders in the
# folder that holds it, as the script was called. The path is read as text,
# with no link resolved: installed, a script runs through its skill link, so
# the folder is the skills folder and core and domain components see each
# other; run by its real path, it is that tree's own folder.
# Sourced, so it sets no shell option; its names start with bs_.
# shellcheck shell=sh

# Prints the folder holding the component of script $1 (its "$0"), where $2
# is how many folders the script sits below its component: 2 for
# scripts/main/x.sh, scripts/internal/x.sh or hooks/stop/x.sh. Fails when
# that folder isn't there.
bs_components() {
	bs_dir=$(dirname -- "$1")
	bs_up=$2
	while [ "${bs_up}" -gt 0 ]; do
		bs_dir="${bs_dir}/.."
		bs_up=$((bs_up - 1))
	done
	(cd -L -- "${bs_dir}/.." 2>/dev/null && pwd -L)
}
