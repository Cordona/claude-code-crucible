#!/usr/bin/env sh
# Reads and checks the mount record in a repository's git folder. Reads only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gm_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh mount-record.sh --repo FOLDER

Run by the git-mount scripts; not for main to call.
Prints the mount record of the repository's main checkout.

Options:
  --repo FOLDER  any folder of the repository or its worktrees; absolute
Writes:    nothing
Stdout:    the record, one JSON line {version, effort, repo, trees: [{name,
           branch, tip}], start, start_is_snapshot, target, head, branch,
           mounted_at, paths: [{path, before, after, saved?}]}; before and
           after are "absent" or "<mode> <blob sha>"
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
  4  git or jq not found, or no work folder could be made
  5  nothing is mounted
USAGE
}

gm_prog='mount-record.sh'
. "$(dirname -- "$0")/../lib/mount.sh"
repo_in=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--repo) [ $# -ge 2 ] || gm_refuse '--repo needs a value'; repo_in=$2; shift 2 ;;
		*) gm_refuse "unknown argument $1; try --help" ;;
	esac
done
gm_find_self "$0"
gm_set_repo "${repo_in}"
record="${gm_record_dir}/mount.json"
[ -e "${record}" ] || [ -L "${record}" ] || { gm_warn "no mount is recorded in ${gm_record_dir}"; exit 5; }
[ -f "${record}" ] && [ ! -L "${record}" ] || gm_refuse "${record} is not a regular file; remove it by hand"
[ -f "${gm_record_dir}/mount.patch" ] || gm_refuse "${record} has no mount.patch beside it; remove the record by hand"
gm_make_work

# One problem per line, the first "version" when it is another version.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
jq -r --argjson version "${GM_RECORD_VERSION}" '
def sha: type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$");
def state: type == "string" and test("^(absent|(100644|100755|120000) ([0-9a-f]{40}|[0-9a-f]{64}))$");
def folder: type == "string" and startswith("/") and (test("[\u0000-\u001f\u007f]") | not);
def relative: type == "string" and length > 0 and (test("[\u0000\n]") | not)
	and (split("/") | all(. != "" and . != "." and . != ".." and . != ".git"));
def shown: tojson | if length > 80 then .[0:77] + "..." else . end;
def check($where; f; $expected):
	if f then empty
	elif . == null then "\($where): missing; expected \($expected)"
	else "\($where): \(shown) is not allowed; expected \($expected)" end;
def tree_problems($where):
	if type != "object" then check($where; false; "an object of name, branch and tip")
	else (.name | check("\($where).name"; type == "string" and test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$"); "a tree name")),
		(.branch | check("\($where).branch"; type == "string" and startswith("crucible/"); "a crucible/ branch")),
		(.tip | check("\($where).tip"; sha; "a full sha")) end;
def path_problems($where):
	if type != "object" then check($where; false; "an object of path, before and after")
	else (.path | check("\($where).path"; relative; "a root-relative path with no empty, ., .. or .git segment")),
		(.before | check("\($where).before"; state; "absent or <mode> <blob sha>")),
		(.after | check("\($where).after"; state; "absent or <mode> <blob sha>")),
		(if .saved != null and .saved != ((.before | state) and (.before | test("^100(644|755) "))) then
			.saved | check("\($where).saved"; false; "true only when before is a regular file") else empty end) end;
if type != "object" then "record: a JSON \(type) is not a mount record"
elif .version != $version then "version: \(.version | shown) is not this record version; expected \($version), so the record was not read"
else (.effort | check("effort"; folder; "an absolute folder")),
	(.repo | check("repo"; folder; "an absolute folder")),
	(.head | check("head"; sha; "a full sha")),
	(.start | check("start"; sha; "a full sha")),
	(.target | check("target"; sha; "a full sha")),
	(.start_is_snapshot | check("start_is_snapshot"; type == "boolean"; "true or false")),
	(.branch | check("branch"; . == null or type == "string"; "a branch name or null")),
	(.mounted_at | check("mounted_at"; type == "string"; "the mount time")),
	(.trees | if type == "array" and length > 0 then to_entries[] | .key as $i | .value | tree_problems("trees[\($i)]")
		else check("trees"; false; "a non-empty array of trees") end),
	(.paths | if type == "array" and length > 0 then to_entries[] | .key as $i | .value | path_problems("paths[\($i)]")
		else check("paths"; false; "a non-empty array of paths") end) end' "${record}" >"${gm_work}/problems" 2>/dev/null \
	|| gm_refuse "${record} is unreadable or not JSON; remove it by hand"
if [ -s "${gm_work}/problems" ]; then
	head -n 20 "${gm_work}/problems" | while IFS= read -r problem; do gm_warn "$(gm_printable "${problem}")"; done
	gm_refuse "${record} is no version ${GM_RECORD_VERSION} mount record; remove it by hand, or with the tool that made it"
fi
jq -c . "${record}"
