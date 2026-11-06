# Sourced by mount.sh, unmount.sh and mount-status.sh, never run: the main
# checkout's shape, where its mount record lives, the record's contract and
# the state of a path in the checkout. Uses the sourcing script's warn, die,
# printable and work_dir; sets no shell option of its own.
#
# A path's state is absent or "<mode> <blob sha>", the blob as git would
# store the checkout's file: clean filters applied, a symlink's target text.
# The checkout can also hold what no tree can, each a mismatch: directory,
# beyond-symlink (a parent folder is a symlink) or other (no file, folder or
# symlink). A spec file holds one "<before><TAB><after><TAB><path>" line per
# path, in the record's order. Every git call runs with fsmonitor off, so
# a read never refreshes an index.
# shellcheck disable=SC2034,SC2154 # the sourcing scripts read the variables set here and set work_dir

readonly RECORD_FOLDER='crucible'
readonly MAX_LISTED=20
readonly tab='	'

# A version 1 record holds one seat (slot, worktree, seat_commit) and its
# base; it reads as version 2 with that one seat, start = base and target =
# seat_commit.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly RECORD_JQ='def sha: type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$");
def state: type == "string" and test("^(absent|(100644|100755|120000) ([0-9a-f]{40}|[0-9a-f]{64}))$");
def folder: type == "string" and startswith("/") and (test("[\u0000-\u001f\u007f]") | not);
def relative: type == "string" and length > 0 and (test("[\u0000\n]") | not)
	and (split("/") | all(. != "" and . != "." and . != ".." and . != ".git"));
def slot_name: type == "string" and test("^[a-z][a-z0-9]*-[1-9][0-9]*$");
def common_fits: (.effort | folder) and (.repo | folder) and (.head | sha)
	and (.branch == null or (.branch | type == "string")) and (.mounted_at | type == "string")
	and (.paths | type == "array" and length > 0
		and all(type == "object" and (.path | relative) and (.before | state) and (.after | state)
			and (.saved == null or .saved == (.before | test("^100(644|755) ")))));
def v1_fits: common_fits and (.worktree | folder) and (.slot | slot_name)
	and (.base | sha) and (.seat_commit | sha) and (.base_is_snapshot | type == "boolean");
def v2_fits: common_fits and (.start | sha) and (.target | sha) and (.start_is_snapshot | type == "boolean")
	and (.seats | type == "array" and length > 0
		and all(type == "object" and (.slot | slot_name) and (.worktree | folder) and (.seat_commit | sha))
		and (map(.slot) | unique | length) == length)
	and ((.seats | length > 1) or .seats[0].seat_commit == .target);
if type == "object" and .version == 1 and v1_fits then
	{effort, repo, start: .base, target: .seat_commit, head, seats: [{slot, worktree, seat_commit}], paths}
elif type == "object" and .version == 2 and v2_fits then .
else error("not a version 1 or 2 mount record") end
| .effort, .repo, .start, .target, .head, (.seats | length), (.seats[] | "\(.slot)\t\(.worktree)\t\(.seat_commit)"),
	(.paths[] | "\(.before)\t\(.after)\t\(.path)")'

# Sets checkout_problem to why $1 is not a main checkout's top folder, empty
# when it is; then also checkout_dir (physical), git_dir and record_dir.
locate_checkout() {
	checkout_problem='' checkout_dir='' git_dir='' record_dir=''
	shown_checkout=$(printable "$1")
	case $1 in
		*[[:cntrl:]]*)
			checkout_problem="${shown_checkout} holds a control character; expected a path printable on one line"
			return 0
			;;
		/*) ;;
		*)
			checkout_problem="${shown_checkout} is not absolute; expected an absolute path"
			return 0
			;;
	esac
	[ -d "$1" ] || {
		checkout_problem="${shown_checkout} is not a folder; expected a main checkout's top folder"
		return 0
	}
	inside=$(git -C "$1" -c core.fsmonitor=false rev-parse --is-inside-work-tree 2>/dev/null) || inside=''
	[ "${inside}" = true ] || {
		checkout_problem="${shown_checkout} is not a git work tree; expected a main checkout, not bare"
		return 0
	}
	physical_checkout=$(cd -P -- "$1" && pwd -P) || physical_checkout=''
	top_folder=$(git -C "$1" -c core.fsmonitor=false rev-parse --show-toplevel 2>/dev/null) || top_folder=''
	[ -n "${top_folder}" ] && [ "${physical_checkout}" = "${top_folder}" ] || {
		shown_top_folder=$(printable "${top_folder}")
		checkout_problem="${shown_checkout} is not the checkout's top folder; expected ${shown_top_folder}"
		return 0
	}
	located_git_dir=$(git -C "$1" -c core.fsmonitor=false rev-parse --absolute-git-dir 2>/dev/null) || located_git_dir=''
	common_dir=$(git -C "$1" -c core.fsmonitor=false rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common_dir=''
	[ -n "${located_git_dir}" ] && [ -n "${common_dir}" ] ||
		die 4 "git could not name the git folders of ${shown_checkout}; expected git 2.26+"
	[ "${located_git_dir}" = "${common_dir}" ] || {
		checkout_problem="${shown_checkout} is a linked worktree; expected the main checkout"
		return 0
	}
	checkout_dir=${physical_checkout} git_dir=${located_git_dir}
	record_dir="${git_dir}/${RECORD_FOLDER}"
}

# Warns, prefixed $1, each reason the located checkout can't take a mount and
# counts it in problems; sets head, empty when there is no HEAD commit.
check_checkout_idle() {
	for under_way in MERGE_HEAD:merge rebase-merge:rebase rebase-apply:rebase CHERRY_PICK_HEAD:cherry-pick \
		REVERT_HEAD:revert sequencer:cherry-pick\ or\ revert BISECT_START:bisect; do
		[ ! -e "${git_dir}/${under_way%%:*}" ] || {
			warn "$1 has a ${under_way#*:} under way; expected none"
			problems=$((problems + 1))
		}
	done
	sparse=$(git -C "${checkout_dir}" -c core.fsmonitor=false config --type=bool core.sparseCheckout 2>/dev/null) || sparse=false
	[ "${sparse}" != true ] || {
		warn "$1 is a sparse checkout; expected a full checkout"
		problems=$((problems + 1))
	}
	head=$(git -C "${checkout_dir}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || head=''
	[ -n "${head}" ] || {
		warn "$1 has no HEAD commit; expected a branch or detached HEAD on a commit"
		problems=$((problems + 1))
	}
}

# Sets record_present; when true also rec_effort, rec_repo, rec_start,
# rec_target, rec_head, rec_slots (the slots, space-separated, in order),
# the seats file work_dir/rec-seats ("<slot><TAB><worktree><TAB><seat
# commit>" per seat) and the spec file work_dir/spec. Exits 3 on a record
# that fails the contract.
read_record() {
	record_file="${record_dir}/mount.json"
	record_present=false
	[ -e "${record_file}" ] || [ -L "${record_file}" ] || return 0
	record_present=true
	shown_record=$(printable "${record_file}")
	[ -f "${record_file}" ] && [ ! -L "${record_file}" ] ||
		die 3 "the mount record ${shown_record} is not a regular file; expected mount.sh's record"
	jq -r "${RECORD_JQ}" "${record_file}" >"${work_dir}/record" 2>/dev/null ||
		die 3 "the mount record ${shown_record} is unreadable or not version 1 or 2; expected mount.sh's record"
	rec_slots=''
	{
		IFS= read -r rec_effort
		IFS= read -r rec_repo
		IFS= read -r rec_start
		IFS= read -r rec_target
		IFS= read -r rec_head
		IFS= read -r rec_seat_count
		while [ "${rec_seat_count}" -gt 0 ]; do
			IFS= read -r rec_seat
			printf '%s\n' "${rec_seat}"
			rec_slots="${rec_slots:+${rec_slots} }${rec_seat%%"${tab}"*}"
			rec_seat_count=$((rec_seat_count - 1))
		done >"${work_dir}/rec-seats"
		cat >"${work_dir}/spec"
	} <"${work_dir}/record"
}

# Writes to $2 the checkout state of each path in spec file $1, one per line.
# Regular files are hashed in one git call, which reads them by path through
# their clean filters; symlinks are hashed from their target text.
checkout_states() {
	while IFS= read -r spec_line; do
		state_path=${spec_line#*"${tab}"}
		path_state "${state_path#*"${tab}"}"
		printf '%s\n' "${state}"
	done <"$1" >"${work_dir}/states" 3>"${work_dir}/to-hash"
	if [ -s "${work_dir}/to-hash" ]; then
		# hash-object --stdin-paths C-unquotes a line that starts with a quote
		# and drops a trailing CR, so every path goes in C-quoted.
		sed 's/[\\"]/\\&/g; s/^/"/; s/$/"/' "${work_dir}/to-hash" |
			git -C "${checkout_dir}" -c core.fsmonitor=false hash-object --stdin-paths >"${work_dir}/hashes" 2>"${work_dir}/stderr" ||
			git_failed 'git hash-object of the mounted paths'
		awk 'NR == FNR { blob[NR] = $0; next } /^hash / { n++; print substr($0, 6) " " blob[n]; next } { print }' \
			"${work_dir}/hashes" "${work_dir}/states" >"$2" || die 4 'awk failed merging the path states; expected a POSIX awk'
	else
		mv -f -- "${work_dir}/states" "$2" || die 4 'could not move the path states in the work folder'
	fi
}

# Sets state for checkout path $1; a regular file's is "hash <mode>", its
# path written to fd 3 for checkout_states to hash.
path_state() {
	full_path="${checkout_dir}/$1"
	rest=$1 parent=${checkout_dir}
	while :; do
		case ${rest} in
			*/*) ;;
			*) break ;;
		esac
		parent="${parent}/${rest%%/*}"
		rest=${rest#*/}
		[ ! -L "${parent}" ] || {
			state='beyond-symlink'
			return 0
		}
	done
	if [ -L "${full_path}" ]; then
		shown_path=$(printable "$1")
		target=$(readlink -- "${full_path}") || die 4 "readlink failed on ${shown_path}"
		blob=$(printf '%s' "${target}" | git -C "${checkout_dir}" -c core.fsmonitor=false hash-object --stdin) ||
			die 4 "git hash-object failed on the symlink ${shown_path}"
		state="120000 ${blob}"
	elif [ -d "${full_path}" ]; then
		state='directory'
	elif [ -f "${full_path}" ]; then
		state='hash 100644'
		[ ! -x "${full_path}" ] || state='hash 100755'
		printf '%s\n' "$1" >&3
	elif [ -e "${full_path}" ]; then
		state='other'
	else
		state='absent'
	fi
}

# Writes to $5 one "<kind><TAB><path>" line per path of spec file $1 whose
# state in states file $2 differs from spec column $3 (1 before, 2 after);
# $4 names the kind of a path found where absent was expected.
list_mismatches() {
	paste -d "${tab}" "$2" "$1" | awk -F "${tab}" -v column="$3" -v present="$4" '
		{
			actual = $1
			expected = (column == 1 ? $2 : $3)
			path = $0
			for (i = 0; i < 3; i++) path = substr(path, index(path, FS) + 1)
			if (actual == expected) next
			if (actual == "directory") kind = "a folder in the way"
			else if (actual == "beyond-symlink") kind = "a parent folder is a symlink"
			else if (actual == "other") kind = "neither a file nor a symlink"
			else if (expected == "absent") kind = present
			else if (actual == "absent") kind = "deleted"
			else if (substr(actual, 8) == substr(expected, 8)) kind = "mode changed"
			else kind = "modified"
			print kind FS path
		}' >"$5" || die 4 'paste or awk failed comparing the path states; expected POSIX tools'
}

# Warns one line per mismatch in file $1, at most MAX_LISTED, then a count
# of the rest: "$2<path>: <kind>$3".
warn_mismatches() {
	mismatch_count=0
	while IFS= read -r mismatch; do
		mismatch_count=$((mismatch_count + 1))
		[ "${mismatch_count}" -le "${MAX_LISTED}" ] || continue
		shown_path=$(printable "${mismatch#*"${tab}"}")
		warn "$2${shown_path}: ${mismatch%%"${tab}"*}$3"
	done <"$1"
	[ "${mismatch_count}" -le "${MAX_LISTED}" ] || warn "$2... and $((mismatch_count - MAX_LISTED)) more paths$3"
}

# Sets finished: HEAD $2 is not the record's head and every record path holds
# in the checkout (states file $1) what HEAD's tree holds, so the human
# committed what the mount left. Writes the paths that differ to
# work_dir/uncommitted as list_mismatches does.
check_finished() {
	finished=false
	: >"${work_dir}/uncommitted"
	[ -n "$2" ] && [ "$2" != "${rec_head}" ] || return 0
	cut -f 3- "${work_dir}/spec" | tr '\n' '\000' |
		GIT_LITERAL_PATHSPECS=1 xargs -0 git -C "${checkout_dir}" -c core.fsmonitor=false ls-tree -r -z --full-tree "$2" -- \
			>"${work_dir}/head-tree" 2>"${work_dir}/stderr" || git_failed "git ls-tree of HEAD $2"
	# Each ls-tree entry is "<mode> <type> <sha><TAB><path>"; a path HEAD's
	# tree lacks is absent there.
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -Rsr --rawfile spec "${work_dir}/spec" '
		(split("\u0000") | map(select(. != "") | split("\t") as $entry
			| {key: ($entry[1:] | join("\t")), value: ($entry[0] | split(" ") | "\(.[0]) \(.[2])")}) | from_entries) as $tree
		| $spec | rtrimstr("\n") | split("\n")[] | split("\t") | (.[2:] | join("\t")) as $path
		| ($tree[$path] // "absent") as $state | "\($state)\t\($state)\t\($path)"' \
		"${work_dir}/head-tree" >"${work_dir}/head-spec" 2>"${work_dir}/stderr" || git_failed "jq reading HEAD's tree"
	list_mismatches "${work_dir}/head-spec" "$1" 1 'present though HEAD has none' "${work_dir}/uncommitted"
	[ -s "${work_dir}/uncommitted" ] || finished=true
}

# Removes the record: mount.json first, so a half-removed record reads as no
# mount, then the patch, the saved copies and the folder when it is empty.
remove_record() {
	shown_record_dir=$(printable "${record_dir}")
	rm -f -- "${record_dir}/mount.json" || die 4 "the record ${shown_record_dir}/mount.json could not be removed"
	rm -rf -- "${record_dir}/mount.patch" "${record_dir}/before" ||
		warn "could not remove the patch or the saved copies in ${shown_record_dir}; nothing is mounted"
	rmdir -- "${record_dir}" 2>/dev/null || :
}

# Writes to work_dir/saved one "<n><TAB><path>" line per record path whose
# bytes before the mount are saved as record_dir/before/<n>; n counts from 0.
list_saved() {
	jq -r '.paths | to_entries[] | select(.value.saved == true) | .key' "${record_dir}/mount.json" \
		>"${work_dir}/saved-indexes" 2>"${work_dir}/stderr" || git_failed 'jq reading the saved copies of the record'
	awk 'NR == FNR { saved[$0] = 1; next }
		(FNR - 1) in saved { path = $0; for (i = 0; i < 2; i++) path = substr(path, index(path, "\t") + 1); print (FNR - 1) "\t" path }' \
		"${work_dir}/saved-indexes" "${work_dir}/spec" >"${work_dir}/saved" || die 4 'awk failed listing the saved copies; expected a POSIX awk'
}

# Puts back, bytes and mode, each saved file whose bytes git apply -R did not
# restore exactly (line endings under eol attributes), through a temp file
# beside it; then checks every saved file's bytes. Lines of work_dir/saved
# are "<n><TAB><path>"; $1 ends the message of an exit 4.
restore_saved_bytes() {
	while IFS= read -r saved_line; do
		saved_copy="${record_dir}/before/${saved_line%%"${tab}"*}"
		restored_path="${checkout_dir}/${saved_line#*"${tab}"}"
		! cmp -s -- "${saved_copy}" "${restored_path}" || continue
		restore_temp=$(mktemp "${restored_path%/*}/.crucible-restore.XXXXXX") || restore_failed "$1"
		cp -p -- "${saved_copy}" "${restore_temp}" || restore_failed "$1"
		mv -f -- "${restore_temp}" "${restored_path}" || restore_failed "$1"
		restore_temp=''
	done <"${work_dir}/saved"
	unrestored=0
	while IFS= read -r saved_line; do
		cmp -s -- "${record_dir}/before/${saved_line%%"${tab}"*}" "${checkout_dir}/${saved_line#*"${tab}"}" && continue
		unrestored=$((unrestored + 1))
		shown_path=$(printable "${saved_line#*"${tab}"}")
		warn "after reversing, ${shown_path} does not hold its bytes from before the mount"
	done <"${work_dir}/saved"
	[ "${unrestored}" -eq 0 ] || die 4 "the restored bytes did not verify; $1"
}

restore_failed() {
	shown_path=$(printable "${saved_line#*"${tab}"}")
	die 4 "could not put back the saved bytes of ${shown_path}; $1"
}

# Exits 4 naming step $1 and the first line of work_dir/stderr.
git_failed() {
	first_line=$(head -n 1 "${work_dir}/stderr" 2>/dev/null) || first_line=''
	shown_line=$(printable "${first_line}")
	die 4 "$1 failed: ${shown_line}"
}
