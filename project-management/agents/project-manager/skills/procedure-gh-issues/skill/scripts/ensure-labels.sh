#!/usr/bin/env sh
# shellcheck source-path=SCRIPTDIR
#
# ensure-labels.sh — opt-in, idempotent creation of PERSISTENT repo labels.
#
# Purpose:
#   The label pre-checks in create-issue.sh/update-issue.sh deliberately
#   never auto-create a missing label — creating a label is a repo-wide,
#   persistent, visible change the user must separately consent to. This is
#   THAT separate, explicit step: the caller runs it FIRST, on the user's
#   opt-in, when they want missing labels created before create/update runs.
#
# Idempotency:
#   Every requested label is checked against the repo's actual labels
#   (`gh api repos/OWNER/REPO/labels`) first. An already-existing label is
#   skipped — never re-created, never an error. A label requested more than
#   once (repeated --label, a comma-list, or both) is created at most once.
#
# Usage:
#   ensure-labels.sh --repo OWNER/REPO --label NAME [--color HEX]
#                     [--description STR] [-h|--help]
#
#     --repo OWNER/REPO   Target repository (required).
#     --label NAME         A label to ensure exists. Required, repeatable,
#                          and/or a comma-separated list in one occurrence.
#     --color HEX           A 6-digit hex color (no leading '#'), applied to
#                          every label CREATED this run (optional).
#     --description STR     A description applied to every label CREATED
#                          this run (optional).
#     -h, --help             Show this help.
#
# Output:
#   PM_LABELS_CREATED=<name[,name...]>   labels actually created this run
#   PM_LABELS_EXISTING=<name[,name...]>  requested labels that already existed
#   (either may be empty; diagnostics go to stderr)
#
# Exit codes:
#   0  every requested label exists (created and/or already present)
#   1  gh absent / not authenticated / the labels lookup failed / at least
#      one `gh label create` call itself failed (labels that DID succeed are
#      still created and reported — this is a best-effort run, not
#      all-or-nothing, so one bad --color doesn't lose the rest)
#   2  usage error
#
# NOT performed here (deliberately upstream): the GitHub-ACCOUNT confirmation
# gate — that is `procedure-github-auth`'s job, run by the calling agent BEFORE
# this script (see this skill's SKILL.md). This is an OUTWARD, PERSISTENT
# repo write — gate it on the user's explicit opt-in, same as create-issue.sh.
#
# Portability: POSIX sh only (no bashisms). Every external binary is guarded
#   with `command -v`. Sources this skill's own lib/ (see the
#   PM_LIB_DIR preamble below); depends on nothing outside this skill directory.
#
set -eu

# Locate this skill's lib/ RELATIVE TO THIS SCRIPT, using only parameter
# expansion. Never dirname/readlink/realpath/basename: the test harness runs
# every command under a minimal PATH toolbox that deliberately excludes all
# four, so any of them would break the whole suite. The `*)` branch is
# unreachable in practice (the harness and SKILL.md always invoke these scripts
# by an absolute path) but exists so `set -u` can never see an unset
# PM_LIB_DIR.
case "$0" in
	*/*) PM_LIB_DIR=${0%/*}/../lib ;;
	*)   PM_LIB_DIR=../lib ;;
esac

for _pm_lib in pm-diag.sh pm-validate.sh pm-gh-preconditions.sh pm-lists.sh; do
	[ -r "$PM_LIB_DIR/$_pm_lib" ] || { printf '%s: error: cannot locate %s at %s (invoke this script by its absolute path)\n' "${0##*/}" "$_pm_lib" "$PM_LIB_DIR" >&2; exit 1; }
done
unset _pm_lib

# shellcheck source=../lib/pm-diag.sh
. "$PM_LIB_DIR/pm-diag.sh"
# shellcheck source=../lib/pm-validate.sh
. "$PM_LIB_DIR/pm-validate.sh"
# shellcheck source=../lib/pm-gh-preconditions.sh
. "$PM_LIB_DIR/pm-gh-preconditions.sh"
# shellcheck source=../lib/pm-lists.sh
. "$PM_LIB_DIR/pm-lists.sh"

usage() {
	cat <<EOF
Usage: $PROG --repo OWNER/REPO --label NAME [--color HEX]
              [--description STR] [-h|--help]

Idempotently ensure each requested label exists in the repo, creating only
the ones that are missing. Never errors on an already-existing label.

Options:
  --repo OWNER/REPO   Target repository (required).
  --label NAME        A label to ensure exists. Required, repeatable, and/or
                       comma-separated.
  --color HEX         A 6-digit hex color (no '#'), applied to labels
                       CREATED this run (optional).
  --description STR   A description applied to labels CREATED this run
                       (optional).
  -h, --help          Show this help.

Prints:
  PM_LABELS_CREATED=<name[,name...]>
  PM_LABELS_EXISTING=<name[,name...]>

Exit codes:
  0  every requested label exists
  1  gh absent / not authenticated / lookup failed / a create call failed
  2  usage error
EOF
}

# Requested labels, newline-separated (may contain duplicates; deduped below).
# Appended to via csv_accumulate (lib/pm-lists.sh), which comma-splits and trims
# each occurrence, so `--label "a, b" --label c` and `--label a,b,c` are the same.
LABELS=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO=""
OPT_COLOR=""
OPT_DESCRIPTION=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)        need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--label)       need_arg "$1" "${2:-}"; LABELS=$(csv_accumulate "$LABELS" "$2"); shift ;;
		--color)       need_arg "$1" "${2:-}"; OPT_COLOR=$2; shift ;;
		--description) need_arg "$1" "${2:-}"; OPT_DESCRIPTION=$2; shift ;;
		-h|--help)     usage; exit 0 ;;
		--)            shift; break ;;
		-*)            usage >&2; error "unknown option: $1"; exit 2 ;;
		*)             usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ] || { usage >&2; error "--repo is required"; exit 2; }
is_valid_repo_slug "$OPT_REPO" || { usage >&2; error "--repo must be OWNER/REPO (letters, digits, '.', '_', '-' only), got: $OPT_REPO"; exit 2; }

[ -n "$LABELS" ] || { usage >&2; error "at least one --label is required"; exit 2; }

if [ -n "$OPT_COLOR" ]; then
	is_valid_hex_color "$OPT_COLOR" || { usage >&2; error "--color must be 6 hex digits (no '#'), got: $OPT_COLOR"; exit 2; }
fi

# ---------------------------------------------------------------------------
# gh preconditions — fail CLOSED: this is an outward, persistent repo write.
# ---------------------------------------------------------------------------
require_gh_cli

require_gh_auth

init_tmp_err pm-ensure-labels

# ---------------------------------------------------------------------------
# Look up the repo's actual labels ONCE.
# ---------------------------------------------------------------------------
if ! EXISTING_LABELS=$(gh api "repos/${OPT_REPO}/labels" --paginate --jq '.[].name' 2>"$TMP_ERR"); then
	error "failed to look up labels for repo '$OPT_REPO'"
	emit_captured_stderr
	exit 1
fi

# ---------------------------------------------------------------------------
# For each requested label (deduplicated via SEEN): skip if it already
# exists in the repo; otherwise create it. Best-effort — a single failed
# create does not abort the labels that succeed before or after it.
# ---------------------------------------------------------------------------
CREATED=""
EXISTED=""
SEEN=""
ANY_CREATE_FAILED=0

while IFS= read -r label; do
	[ -n "$label" ] || continue
	if printf '%s\n' "$SEEN" | grep -Fxq -- "$label"; then
		continue
	fi
	SEEN=$(append_line "$SEEN" "$label")

	if printf '%s\n' "$EXISTING_LABELS" | grep -Fxq -- "$label"; then
		if [ -z "$EXISTED" ]; then EXISTED="$label"
		else EXISTED="$EXISTED,$label"
		fi
		continue
	fi

	# The label NAME is placed LAST, after a literal `--`, rather than as the
	# first positional right after `create`: a name beginning with '-' would
	# otherwise be misparsed by gh as an option. `--` must be the LAST thing
	# before the name (not right after `create`), because everything
	# following `--` stops being parsed as a flag — placing --repo/--color/
	# --description after it would break those too.
	set -- gh label create --repo "$OPT_REPO"
	[ -z "$OPT_COLOR" ]       || set -- "$@" --color "$OPT_COLOR"
	[ -z "$OPT_DESCRIPTION" ] || set -- "$@" --description "$OPT_DESCRIPTION"
	set -- "$@" -- "$label"

	if "$@" >/dev/null 2>"$TMP_ERR"; then
		if [ -z "$CREATED" ]; then CREATED="$label"
		else CREATED="$CREATED,$label"
		fi
	else
		ANY_CREATE_FAILED=1
		error "failed to create label '$label' in repo '$OPT_REPO'"
		emit_captured_stderr
	fi
done <<EOF
$LABELS
EOF

printf 'PM_LABELS_CREATED=%s\n'  "$CREATED"
printf 'PM_LABELS_EXISTING=%s\n' "$EXISTED"

[ "$ANY_CREATE_FAILED" -eq 0 ] || exit 1
exit 0
