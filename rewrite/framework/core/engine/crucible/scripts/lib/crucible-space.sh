# The Crucible space's shared rules, one copy for every script that finds or
# checks a path in it: where the space is, what an effort folder is named, what
# an ID and an item label are, how an ID is minted and an item named, and where
# an effort's item lies.
# Sourced, so it sets no shell option; its names start with crucible_.
# Installed at ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/crucible/scripts/lib/;
# crucible.sh sources it from beside itself.
# shellcheck shell=sh
# shellcheck disable=SC2034 # its crucible_ values are read by the sourcing scripts

# The NAME part of an effort folder's name, as effort.sh start sets it.
crucible_effort_name_max_chars=40
crucible_effort_name_rule="<YYYYMMDDTHHMMSS>-<4 lowercase hex>-<NAME>, NAME words of a-z and 0-9 joined by single dashes, 1 to ${crucible_effort_name_max_chars} characters"
# An item label is part of a file name; 60 characters keep a name readable in a
# listing and far below any file system's name limit.
crucible_label_max_chars=60
crucible_label_rule="lowercase a-z, 0-9 and -, 1 to ${crucible_label_max_chars} characters"
# A clash needs the same second, label and 4 random hex digits; a handful of
# fresh draws makes a repeat practically impossible.
crucible_max_create_attempts=5
# Every item file, of any kind, is JSON.
crucible_item_extension=json

# Sets crucible_root to the space, ${CRUCIBLE_HOME:-$HOME/.crucible} without
# trailing slashes, and crucible_root_source to the variable it came from.
# Fails when it is unusable, with crucible_root_fault set to usage (a value to
# fix: relative, or /) or space (no variable set, or the root a symbolic
# link) and crucible_root_problem to "<what>; expected <x>; try <y>".
crucible_resolve_root() {
	crucible_root_fault='' crucible_root_problem=''
	if [ -n "${CRUCIBLE_HOME:-}" ]; then
		crucible_root=${CRUCIBLE_HOME}
		crucible_root_source=CRUCIBLE_HOME
	elif [ -n "${HOME:-}" ]; then
		crucible_root="${HOME}/.crucible"
		crucible_root_source=HOME
	else
		crucible_root_fault=space
		crucible_root_problem='neither CRUCIBLE_HOME nor HOME is set; expected one of them to name the space; try setting CRUCIBLE_HOME'
		return 1
	fi
	case ${crucible_root} in
		/*) ;;
		*)
			crucible_root_fault=usage
			crucible_root_problem="${crucible_root_source} gives ${crucible_root}, which is not absolute; expected an absolute path; try a path that starts with /"
			return 1
			;;
	esac
	while [ "${crucible_root}" != "${crucible_root%/}" ]; do crucible_root=${crucible_root%/}; done
	if [ -z "${crucible_root}" ]; then
		crucible_root_fault=usage
		crucible_root_problem='CRUCIBLE_HOME is /; expected a folder of its own; try unsetting it for the default'
		return 1
	fi
	if [ -L "${crucible_root}" ]; then
		crucible_root_fault=space
		crucible_root_problem="${crucible_root} is a symbolic link; expected a real folder; try pointing CRUCIBLE_HOME at the target instead"
		return 1
	fi
}

# Succeeds when $1 is a Crucible ID: <YYYYMMDDTHHMMSS>-<4 lowercase hex>.
crucible_is_id() {
	case $1 in
		[0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789]T[0123456789][0123456789][0123456789][0123456789][0123456789][0123456789]-[0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef]) ;;
		*) return 1 ;;
	esac
}

# Succeeds when $1 is the hex part of an ID alone: 4 lowercase hex digits.
crucible_is_id_hex() {
	case $1 in
		[0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef]) ;;
		*) return 1 ;;
	esac
}

# Sets crucible_name_id and crucible_name_rest when name $1 is
# <ID>-<rest>, rest not empty; fails, both empty, otherwise.
crucible_split_id() {
	crucible_name_id='' crucible_name_rest=''
	crucible_split_rest=${1#????????????????????-}
	[ "${crucible_split_rest}" != "$1" ] && [ -n "${crucible_split_rest}" ] || return 1
	crucible_split_head=${1%-"${crucible_split_rest}"}
	crucible_is_id "${crucible_split_head}" || return 1
	crucible_name_id=${crucible_split_head}
	crucible_name_rest=${crucible_split_rest}
}

# Succeeds when $1 keeps the effort NAME rule: words of a-z and 0-9 joined by
# single dashes, 1 to crucible_effort_name_max_chars characters.
crucible_is_effort_words() {
	case $1 in
		'' | *[!abcdefghijklmnopqrstuvwxyz0123456789-]* | -* | *- | *--*) return 1 ;;
		*) ;;
	esac
	[ "${#1}" -le "${crucible_effort_name_max_chars}" ]
}

# Succeeds when folder name $1 is an effort folder's: crucible_effort_name_rule.
# Sets crucible_name_id and crucible_name_rest (the NAME) as crucible_split_id does.
crucible_is_effort_name() {
	crucible_split_id "$1" || return 1
	crucible_is_effort_words "${crucible_name_rest}"
}

# Succeeds when $1 is an item label: crucible_label_rule. Fails with
# crucible_label_problem set to why, without the label itself, which may hold
# anything, and crucible_label_refusal to the sentence a script refusing a
# --label prints: "bad --label: <why>; expected <the rule>".
crucible_is_label() {
	crucible_label_problem='' crucible_label_refusal=''
	case $1 in
		'') crucible_label_problem='it is empty' ;;
		*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) crucible_label_problem='it holds a character outside a-z, 0-9 and -' ;;
		*)
			[ "${#1}" -le "${crucible_label_max_chars}" ] ||
				crucible_label_problem="it is ${#1} characters, over ${crucible_label_max_chars}"
			;;
	esac
	[ -n "${crucible_label_problem}" ] || return 0
	crucible_label_refusal="bad --label: ${crucible_label_problem}; expected ${crucible_label_rule}"
	return 1
}

# Sets crucible_item_file_name to the file name of an item of ID $1 and label
# $2: <ID>-<label>.<crucible_item_extension>.
crucible_name_item() {
	crucible_item_file_name="$1-$2.${crucible_item_extension}"
}

# Sets crucible_id to a fresh <YYYYMMDDTHHMMSS>-<hex>: the local time and 4
# random lowercase hex digits. Fails with crucible_id_problem set
# ("<what>; expected <x>; try <y>") when date or od does not deliver.
crucible_mint_id() {
	crucible_id='' crucible_id_problem=''
	if ! crucible_stamp=$(date +%Y%m%dT%H%M%S 2>/dev/null); then
		crucible_id_problem='date failed; expected the local time; try a POSIX date on PATH'
		return 1
	fi
	case ${crucible_stamp} in
		[0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789]T[0123456789][0123456789][0123456789][0123456789][0123456789][0123456789]) ;;
		*)
			crucible_id_problem='date printed no YYYYMMDDTHHMMSS time; expected a POSIX date; try a POSIX date on PATH'
			return 1
			;;
	esac
	if ! crucible_bytes=$(od -An -N2 -tx1 /dev/urandom 2>/dev/null); then
		crucible_id_problem='reading /dev/urandom failed; expected a random source; try od and /dev/urandom'
		return 1
	fi
	crucible_high='' crucible_low=''
	read -r crucible_high crucible_low <<EOF || true
${crucible_bytes}
EOF
	if ! crucible_is_id_hex "${crucible_high}${crucible_low}"; then
		crucible_id_problem='od printed no 2 hex bytes; expected 4 lowercase hex digits; try a POSIX od'
		return 1
	fi
	crucible_id="${crucible_stamp}-${crucible_high}${crucible_low}"
}

# Succeeds when path $1 (trailing slashes allowed) names a real effort folder
# of the space: absolute, directly in <crucible_root>/efforts/, named as
# crucible_effort_name_rule sets, existing, and neither it nor efforts/ a
# symbolic link; sets crucible_effort to $1 without its trailing slashes.
# Fails with crucible_effort_fault usage (the path itself breaks the rule) or
# space (efforts/ or the folder missing, not a folder or a symbolic link),
# crucible_effort_problem "<what>; expected <x>", which does not repeat $1,
# and crucible_effort_refusal the sentence a script refusing an --effort
# prints: "--effort $1: <crucible_effort_problem>".
# Run crucible_resolve_root first.
crucible_check_effort_folder() {
	crucible_effort_refusal=''
	crucible_effort_check "$1" && return 0
	crucible_effort_refusal="--effort $1: ${crucible_effort_problem}"
	return 1
}

# The checks of crucible_check_effort_folder, which names their refusal.
crucible_effort_check() {
	crucible_effort=$1 crucible_effort_fault=usage crucible_effort_problem=''
	while [ "${crucible_effort}" != "${crucible_effort%/}" ]; do crucible_effort=${crucible_effort%/}; done
	crucible_efforts_dir="${crucible_root}/efforts"
	crucible_effort_name=${crucible_effort#"${crucible_efforts_dir}/"}
	case ${crucible_effort} in
		/*) ;;
		*)
			crucible_effort_problem='not an absolute path; expected the absolute path of an effort folder effort.sh start printed'
			return 1
			;;
	esac
	case ${crucible_effort_name} in
		"${crucible_effort}" | '' | */*)
			crucible_effort_problem="not directly in ${crucible_efforts_dir}/; expected ${crucible_efforts_dir}/<id>-<name>, an effort folder of this Crucible space"
			return 1
			;;
		*) ;;
	esac
	if ! crucible_is_effort_name "${crucible_effort_name}"; then
		crucible_effort_problem="its name breaks the effort folder name rule; expected ${crucible_effort_name_rule}"
		return 1
	fi
	crucible_effort_fault=space
	if [ -L "${crucible_efforts_dir}" ] || [ ! -d "${crucible_efforts_dir}" ]; then
		crucible_effort_problem="${crucible_efforts_dir} is missing, not a folder or a symbolic link; expected the real efforts folder effort.sh start creates"
		return 1
	fi
	if [ -L "${crucible_effort}" ] || [ ! -d "${crucible_effort}" ]; then
		crucible_effort_problem='missing, not a folder or a symbolic link; expected the real effort folder effort.sh start created'
		return 1
	fi
	crucible_effort_fault=''
}

# Creates a new empty file in folder $1, named as an item of label $2
# (crucible_name_item), without overwriting (noclobber), and sets
# crucible_claimed_file to its path and crucible_id to its ID. With a
# function name $3, the file is kept only when "$3 <ID>" succeeds, and is
# otherwise removed. A clash of either retries with a fresh ID, up to
# crucible_max_create_attempts tries. Fails with crucible_claim_fault id (no
# ID minted), create (folder $1 takes no new file) or taken (every try
# clashed), and crucible_claim_problem "<what>; expected <x>".
crucible_claim_item_file() {
	crucible_claimed_file='' crucible_claim_fault='' crucible_claim_problem=''
	crucible_claim_try=1
	while :; do
		if ! crucible_mint_id; then
			crucible_claim_fault=id
			crucible_claim_problem=${crucible_id_problem}
			return 1
		fi
		crucible_name_item "${crucible_id}" "$2"
		crucible_claim_path="$1/${crucible_item_file_name}"
		if (
			set -C
			: >"${crucible_claim_path}"
		) 2>/dev/null; then
			if [ -z "${3:-}" ] || "$3" "${crucible_id}"; then
				crucible_claimed_file=${crucible_claim_path}
				return 0
			fi
			rm -f "${crucible_claim_path}"
		elif [ ! -L "${crucible_claim_path}" ] && [ ! -e "${crucible_claim_path}" ]; then
			crucible_claim_fault=create
			crucible_claim_problem="cannot create a file in $1; expected a writable folder"
			return 1
		fi
		if [ "${crucible_claim_try}" -ge "${crucible_max_create_attempts}" ]; then
			crucible_claim_fault=taken
			crucible_claim_problem="${crucible_max_create_attempts} tries in $1 found the name or its ID taken; expected a free one, try again"
			return 1
		fi
		crucible_claim_try=$((crucible_claim_try + 1))
	done
}

# Sets crucible_effort to the effort folder <crucible_root>/efforts/<effort>
# that path $1 lies inside (the folder itself excluded), by its text alone;
# fails when $1 is no path inside an effort folder. Run crucible_resolve_root first.
crucible_effort_of() {
	crucible_effort=''
	case $1 in
		"${crucible_root}/efforts/"*/?*) ;;
		*) return 1 ;;
	esac
	crucible_effort_rest=${1#"${crucible_root}/efforts/"}
	crucible_effort_name=${crucible_effort_rest%%/*}
	crucible_is_effort_name "${crucible_effort_name}" || return 1
	crucible_effort="${crucible_root}/efforts/${crucible_effort_name}"
}

# Succeeds when path $1 names a file directly in kind folder $2 (such as
# dispatches or cache/gates) of an effort folder of the space, and the space,
# efforts/, the effort folder and every level of the kind folder are real
# folders, none a symbolic link; sets crucible_effort. Fails with
# crucible_item_problem ("<what>; expected <x>") otherwise. The file itself is
# not checked. Run crucible_resolve_root first.
crucible_check_effort_item() {
	crucible_item_problem="not a file directly in <effort>/$2/ of an effort folder of ${crucible_root}/efforts/; expected a path ${crucible_root}/efforts/<effort>/$2/<name>, no folder of it a symbolic link"
	crucible_effort_of "$1" || return 1
	crucible_item_name=${1#"${crucible_effort}/$2/"}
	case ${crucible_item_name} in
		"$1" | '' | */*) return 1 ;;
		*) ;;
	esac
	crucible_layout_dir=${1%/*}
	while :; do
		[ -d "${crucible_layout_dir}" ] && [ ! -L "${crucible_layout_dir}" ] || return 1
		[ "${crucible_layout_dir}" != "${crucible_root}" ] || break
		crucible_layout_dir=${crucible_layout_dir%/*}
	done
}
