#!/usr/bin/env sh
# shellcheck source-path=SCRIPTDIR
#
# ensure-labels.sh — opt-in, idempotent creation of PERSISTENT project labels.
#
# Purpose:
#   No other script in this skill ever auto-creates a missing label — creating a
#   label is a project-wide, persistent, visible change the user must separately
#   consent to. create-issue.sh PRE-CHECKS its labels and fails naming the
#   missing one; update-issue.sh has no label pre-check at all and lets glab
#   error on an unknown one. Neither creates anything. This is THAT separate,
#   explicit step: the caller runs it FIRST, on the user's opt-in, when they want
#   missing labels created before a create/update runs.
#
# Idempotency:
#   Every requested label is checked against the project's actual labels
#   (`glab label list`, paged — see the page-walk note below) first. An
#   already-existing label is skipped — never re-created, never an error. A
#   label requested more than once (repeated --label, a comma-list, or both) is
#   created at most once.
#
# HOST PINNING — WHY --confirmed-host IS REQUIRED (SEC-001):
#   `procedure-gitlab-auth`'s gate confirms an (account, HOST) pair with the user
#   before any write, but that confirmation used to bind to NOTHING here: this
#   script let `glab` resolve the target instance from ambient state (the cwd's
#   git remotes, an inherited $GITLAB_HOST, glab's own config). On a machine with
#   two configured instances — the very case the gate exists to disambiguate —
#   the gate could confirm host A while these PERSISTENT project labels were
#   created on host B, whenever the same --repo project path resolves on both. A
#   live tracker write is unretractable, and there was no error to notice.
#
#   The fix: the caller passes the ALREADY-CONFIRMED host, and this script
#   exports it as GITLAB_HOST for its OWN process before invoking glab. That is
#   glab's documented per-invocation host selector — glab's README: "you can
#   declare one for the current command with the GITLAB_HOST environment
#   variable"; `glab auth status --help`: the instance is "determined by your
#   current context (git remote, GITLAB_HOST environment variable, or
#   configuration)". Pinning it takes ambient config and glab's gitlab.com
#   default out of the decision, and when the cwd happens to be a checkout of a
#   DIFFERENT instance glab refuses outright ("none of the git remotes …
#   correspond to the GITLAB_HOST environment variable") instead of writing to
#   the wrong place — fail closed either way. It also keeps the existence LOOKUP
#   and the CREATE on one instance, so a label can never be reported "missing"
#   from host A and then created on host B.
#
#   This script does NOT re-implement the account-confirmation UX; that stays
#   `procedure-gitlab-auth`'s job, upstream (see "NOT performed here" below).
#   The flag only ENFORCES that the write targets the host already confirmed.
#
# Usage:
#   ensure-labels.sh --repo PATH --label NAME [--label NAME]...
#                     --confirmed-host HOST
#                     [--color HEX] [--description STR] [-h|--help]
#
#     --repo PATH        Target project path (required). One or more
#                        '/'-separated segments — GitLab subgroups are
#                        supported (e.g. group/subgroup/project).
#     --confirmed-host HOST
#                        The GitLab host the account gate already CONFIRMED
#                        (required) — e.g. gitlab.com or a self-managed
#                        hostname, spelled the way `glab auth status` reports it
#                        (bare host, optional ':port', no scheme). See "HOST
#                        PINNING" above.
#     --label NAME       A label to ensure exists. Required, repeatable, and/or
#                        a comma-separated list in one occurrence.
#     --color HEX        A 6-digit hex color, with or WITHOUT a leading '#',
#                        applied to every label CREATED this run (optional).
#                        glab's own default is '#428BCA'. glab also accepts a
#                        plain color NAME ("red"); this wrapper deliberately
#                        accepts hex only, so the value is unambiguous.
#     --description STR  A description applied to every label CREATED this run
#                        (optional).
#     -h, --help         Show this help.
#
# Output:
#   PM_LABELS_CREATED=<name[,name...]>   labels actually created this run
#   PM_LABELS_EXISTING=<name[,name...]>  requested labels that already existed
#   (either may be empty; diagnostics go to stderr)
#
# Exit codes:
#   0  every requested label exists (created and/or already present)
#   1  glab/awk absent / not authenticated / the labels lookup failed / at
#      least one `glab label create` call itself failed (labels that DID
#      succeed are still created and reported — this is a best-effort run, not
#      all-or-nothing, so one bad --color doesn't lose the rest)
#   2  usage error
#
# NOT performed here (deliberately upstream): the GitLab-ACCOUNT confirmation
# gate — that is `procedure-gitlab-auth`'s job, run by the calling agent BEFORE
# this script (see this skill's SKILL.md). This is an OUTWARD, PERSISTENT
# project write — gate it on the user's explicit opt-in, same as create-issue.sh.
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

for _pm_lib in pm-diag.sh pm-glab-env.sh pm-validate.sh pm-glab-preconditions.sh pm-glab-labels.sh pm-lists.sh; do
	[ -r "$PM_LIB_DIR/$_pm_lib" ] || { printf '%s: error: cannot locate %s at %s (invoke this script by its absolute path)\n' "${0##*/}" "$_pm_lib" "$PM_LIB_DIR" >&2; exit 1; }
done
unset _pm_lib

# shellcheck source=../lib/pm-diag.sh
. "$PM_LIB_DIR/pm-diag.sh"
# shellcheck source=../lib/pm-glab-env.sh
. "$PM_LIB_DIR/pm-glab-env.sh"
# shellcheck source=../lib/pm-validate.sh
. "$PM_LIB_DIR/pm-validate.sh"
# shellcheck source=../lib/pm-glab-preconditions.sh
. "$PM_LIB_DIR/pm-glab-preconditions.sh"
# shellcheck source=../lib/pm-glab-labels.sh
. "$PM_LIB_DIR/pm-glab-labels.sh"
# shellcheck source=../lib/pm-lists.sh
. "$PM_LIB_DIR/pm-lists.sh"

usage() {
	cat <<EOF
Usage: $PROG --repo PATH --label NAME [--label NAME]... --confirmed-host HOST
              [--color HEX] [--description STR] [-h|--help]

Idempotently ensure each requested label exists in the project, creating only
the ones that are missing. Never errors on an already-existing label.

Example:
  $PROG --repo group/subgroup/project --label type:story --label area:billing \\
        --confirmed-host gitlab.com --color '#428BCA'

Options:
  --repo PATH        Target project path (required; subgroups allowed).
  --confirmed-host HOST
                     The GitLab host the account gate already confirmed
                      (required; bare hostname, optional ':port', no scheme).
                      Pins glab to that instance.
  --label NAME       A label to ensure exists. Required, repeatable, and/or
                      comma-separated.
  --color HEX        A 6-digit hex color (leading '#' optional), applied to
                      labels CREATED this run (optional). A plain color name
                      is deliberately NOT accepted.
  --description STR  A description applied to labels CREATED this run
                      (optional).
  -h, --help         Show this help.

Prints:
  PM_LABELS_CREATED=<name[,name...]>
  PM_LABELS_EXISTING=<name[,name...]>

Exit codes:
  0  every requested label exists
  1  glab/awk absent / not authenticated / lookup failed / a create call failed
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
OPT_CONFIRMED_HOST=""
OPT_COLOR=""
OPT_DESCRIPTION=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)        need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--confirmed-host) need_arg "$1" "${2:-}"; OPT_CONFIRMED_HOST=$2; shift ;;
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
is_valid_gitlab_project_path "$OPT_REPO" || { usage >&2; error "--repo must be a GitLab project path with at least one '/' (letters, digits, '.', '_', '-' per segment; subgroups allowed), got: $OPT_REPO"; exit 2; }

[ -n "$LABELS" ] || { usage >&2; error "at least one --label is required"; exit 2; }

if [ -n "$OPT_COLOR" ]; then
	is_valid_hex_color "$OPT_COLOR" || { usage >&2; error "--color must be 6 hex digits (leading '#' optional), got: $OPT_COLOR"; exit 2; }
fi

[ -n "$OPT_CONFIRMED_HOST" ] || { usage >&2; error "--confirmed-host is required (the host procedure-gitlab-auth's account gate confirmed)"; exit 2; }
is_valid_confirmed_host "$OPT_CONFIRMED_HOST" || { usage >&2; error "--confirmed-host must be a bare hostname with an optional ':port' and no scheme, got: $OPT_CONFIRMED_HOST"; exit 2; }

# Pin glab's target instance to the CONFIRMED host. Exported so every `glab`
# child of THIS process inherits it — which is also what keeps the existence
# lookup and the creates on ONE instance; nothing outside this process is
# touched. See "HOST PINNING" in this file's header.
pm_pin_gitlab_host "$OPT_CONFIRMED_HOST"

# ---------------------------------------------------------------------------
# glab preconditions — fail CLOSED: this is an outward, persistent project write.
# ---------------------------------------------------------------------------
require_glab_cli

require_awk "page the label lookup"

require_glab_auth

init_tmp_err pm-glab-ensure-labels

# ---------------------------------------------------------------------------
# Look up the project's actual labels ONCE (paged).
# ---------------------------------------------------------------------------
if ! EXISTING_LABELS=$(list_all_labels "$OPT_REPO"); then
	error "failed to look up labels for project '$OPT_REPO'"
	emit_captured_stderr
	exit 1
fi

# ---------------------------------------------------------------------------
# For each requested label (deduplicated via SEEN): skip if it already exists
# in the project; otherwise create it. Best-effort — a single failed create does
# not abort the labels that succeed before or after it.
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

	# The label NAME goes behind glab's own `--name` FLAG, so — unlike the
	# GitHub sibling, where the name is a POSITIONAL argument and needs a
	# literal `--` in front of it — a name beginning with '-' cannot be
	# misparsed as an option here: glab's flag parser takes the argument
	# following `--name` as that flag's value unconditionally.
	set -- glab label create --repo "$OPT_REPO"
	[ -z "$OPT_COLOR" ]       || set -- "$@" --color "$OPT_COLOR"
	[ -z "$OPT_DESCRIPTION" ] || set -- "$@" --description "$OPT_DESCRIPTION"
	set -- "$@" --name "$label"

	if "$@" >/dev/null 2>"$TMP_ERR"; then
		if [ -z "$CREATED" ]; then CREATED="$label"
		else CREATED="$CREATED,$label"
		fi
	else
		ANY_CREATE_FAILED=1
		error "failed to create label '$label' in project '$OPT_REPO'"
		emit_captured_stderr
	fi
done <<EOF
$LABELS
EOF

printf 'PM_LABELS_CREATED=%s\n'  "$CREATED"
printf 'PM_LABELS_EXISTING=%s\n' "$EXISTED"

[ "$ANY_CREATE_FAILED" -eq 0 ] || exit 1
exit 0
