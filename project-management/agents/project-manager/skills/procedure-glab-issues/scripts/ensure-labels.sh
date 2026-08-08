#!/usr/bin/env sh
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
#   with `command -v`. Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

# Pin glab's own optional output/behavior so stdout stays parseable and this
# non-interactive script can never block on a prompt. NOTE: `glab label create`
# has NO `--yes` flag (verified against glab 1.112.0's --help), so
# GLAB_NO_PROMPT is the only prompt suppression available here — passing `--yes`
# would make glab reject the whole invocation as an unknown flag.
GLAB_NO_PROMPT=true
GLAB_CHECK_UPDATE=false
GLAB_SHOW_WHATS_NEW=false
export GLAB_NO_PROMPT GLAB_CHECK_UPDATE GLAB_SHOW_WHATS_NEW

PROG=${0##*/}

warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

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

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# is_valid_gitlab_project_path VALUE — allow-list: letters, digits, '.', '_',
# '-' per segment, and ONE OR MORE '/'-separated segments, with no empty
# segment and no '.'/'..' path segment.
#
# WHY this is NOT procedure-gh-issues' is_valid_repo_slug: a GitHub slug is
# always exactly OWNER/REPO (that validator hard-rejects a second '/'), but
# GitLab supports nested groups, so a real project path can be
# "group/subgroup/project" or deeper. Rejecting the extra segments would make
# every subgroup project unreachable. A LONE segment with no '/' at all is
# still rejected: a bare project name is never a valid full path.
is_valid_gitlab_project_path() {
	case "$1" in
		*[!A-Za-z0-9._/-]*) return 1 ;;   # character allow-list
		*//*) return 1 ;;                 # empty segment
		/*|*/) return 1 ;;                # leading / trailing slash
		..|../*|*/..|*/../*) return 1 ;;  # parent-dir traversal segment
		.|./*|*/.|*/./*) return 1 ;;      # current-dir segment
		*/*) return 0 ;;                  # at least one separator: accept
		*) return 1 ;;                    # a single bare segment: reject
	esac
}

# is_valid_confirmed_host VALUE — allow-list for the host the ACCOUNT GATE
# confirmed, before it becomes this process's GITLAB_HOST: letters, digits, '.',
# '-', '_' and an optional ':port'. Rejects whitespace, shell metacharacters, a
# leading '-', and any empty label. Spelled the way `glab auth status` reports a
# host — and the way manage_glab_accounts.sh's own is_valid_hostname accepts one
# — so the gate's answer can be passed straight through.
#
# A SCHEME-QUALIFIED value ("https://gitlab.com") is rejected on purpose: glab
# accepts both spellings, so allowing them here would let two different strings
# name one host, and the whole point of this flag is a single unambiguous target
# the caller and this script agree on.
is_valid_confirmed_host() {
	case "$1" in
		'') return 1 ;;
		*[!A-Za-z0-9._:-]*) return 1 ;;
		-*) return 1 ;;
		.*|*.|*..*) return 1 ;;
		*) return 0 ;;
	esac
}

# is_valid_hex_color VALUE — exactly 6 hex digits, with an OPTIONAL leading '#'
# (glab's own default is written '#428BCA', so both spellings are natural
# here). `case` patterns have no {n} quantifier, so the 6 positions are spelled
# out.
is_valid_hex_color() {
	case "$1" in
		[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
		'#'[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
		*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# Label lookup paging.
#
# `glab label list` has NO `--paginate` equivalent (unlike `gh api`, which the
# GitHub sibling uses) and its own default page size is only 30 — so a single
# bare call would silently MISS every label past the first page and then try to
# re-create a label that already exists (glab rejects that, and the run would
# report a spurious failure). Hence an explicit page walk with the API's
# maximum page size.
# ---------------------------------------------------------------------------
LABELS_PER_PAGE=100
LABELS_MAX_PAGES=50

# list_all_labels REPO — print every label name in REPO, one per line, walking
# `glab label list` a page at a time until a SHORT page proves the last page
# was reached. Returns 1 if any page query fails; glab's own diagnostics
# accumulate in $TMP_ERR, which must already exist.
#
# Each page is normalized with awk: a SURROUNDING PAIR of double quotes glab's
# --jq may apply to a string result is stripped and blank lines dropped, the same
# defensive normalization procedure-glab-mr applies to its own --jq rows.
#
# A SURROUNDING PAIR only, never `gsub(/"/)`: a global strip removed EVERY quote
# anywhere in the value, so a label legitimately named `say "hi"` came back as
# `say hi` and was then reported missing (and re-created) even though it exists.
# Only the surrounding pair is glab's, so only the surrounding pair is removed —
# and only when BOTH ends carry one (`/^".*"$/` is checked FIRST): stripping the
# two ends independently would eat the closing quote of that same `say "hi"` name,
# which ends with a quote without starting with one.
list_all_labels() {
	_repo=$1
	_page=1
	while [ "$_page" -le "$LABELS_MAX_PAGES" ]; do
		if ! _raw=$(glab label list --repo "$_repo" --output json \
			--per-page "$LABELS_PER_PAGE" --page "$_page" \
			--jq '.[].name' 2>>"$TMP_ERR"); then
			return 1
		fi
		_clean=$(printf '%s\n' "$_raw" | awk '{ if ($0 ~ /^".*"$/) { sub(/^"/, ""); sub(/"$/, "") } if ($0 != "") print }')
		[ -n "$_clean" ] || return 0
		printf '%s\n' "$_clean"
		_count=$(printf '%s\n' "$_clean" | awk 'END { print NR }')
		[ "$_count" -ge "$LABELS_PER_PAGE" ] || return 0
		_page=$((_page + 1))
	done
	warn "label lookup stopped after $LABELS_MAX_PAGES pages — a label beyond the first $((LABELS_MAX_PAGES * LABELS_PER_PAGE)) may be misreported as missing"
	return 0
}

# add_label VALUE — split VALUE on commas (comma-list support) and append each
# non-empty, trimmed token as a new line onto $LABELS.
LABELS=""       # newline-separated (may contain duplicates; deduped below)
add_label() {
	value=$1
	old_ifs=$IFS
	IFS=','
	set -f
	# shellcheck disable=SC2086  # deliberate split of a comma-list on IFS=','; -f (above) blocks globbing
	set -- $value
	set +f
	IFS=$old_ifs
	for tok in "$@"; do
		tok=$(printf '%s' "$tok" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		[ -n "$tok" ] || continue
		if [ -z "$LABELS" ]; then LABELS=$tok
		else LABELS="$LABELS
$tok"
		fi
	done
}

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
		--label)       need_arg "$1" "${2:-}"; add_label "$2"; shift ;;
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
GITLAB_HOST=$OPT_CONFIRMED_HOST
export GITLAB_HOST

# ---------------------------------------------------------------------------
# glab preconditions — fail CLOSED: this is an outward, persistent project write.
# ---------------------------------------------------------------------------
if ! command -v glab >/dev/null 2>&1; then
	error "GitLab CLI (glab) is not installed"
	warn  "install it from https://gitlab.com/gitlab-org/cli then re-run"
	exit 1
fi

if ! command -v awk >/dev/null 2>&1; then
	error "awk is not installed (required to page the label lookup)"
	exit 1
fi

# The bare form checks only the current context's instance, so --all is the
# fallback before declaring glab unauthenticated (same as procedure-glab-mr).
if ! glab auth status >/dev/null 2>&1 && ! glab auth status --all >/dev/null 2>&1; then
	error "glab is installed but not authenticated"
	warn  "authenticate with: glab auth login"
	exit 1
fi

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-glab-ensure-labels.err.XXXXXX")
# TWO traps, not one combined `EXIT INT TERM`: a Ctrl-C during a slow `glab`
# call would otherwise leak the temp file, but a combined handler would clean up
# and then RESUME the interrupted command's error path, which goes on to read the
# file it just unlinked. The INT/TERM handler therefore terminates the script
# itself (130 = SIGINT's conventional status). The EXIT trap still runs after it,
# and a second `rm -f` on an already-removed path is a no-op.
trap 'rm -f "$TMP_ERR"' EXIT
trap 'rm -f "$TMP_ERR"; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Look up the project's actual labels ONCE (paged).
# ---------------------------------------------------------------------------
if ! EXISTING_LABELS=$(list_all_labels "$OPT_REPO"); then
	error "failed to look up labels for project '$OPT_REPO'"
	sed 's/^/  /' "$TMP_ERR" >&2
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
	if [ -z "$SEEN" ]; then SEEN="$label"
	else SEEN="$SEEN
$label"
	fi

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
		sed 's/^/  /' "$TMP_ERR" >&2
	fi
done <<EOF
$LABELS
EOF

printf 'PM_LABELS_CREATED=%s\n'  "$CREATED"
printf 'PM_LABELS_EXISTING=%s\n' "$EXISTED"

[ "$ANY_CREATE_FAILED" -eq 0 ] || exit 1
exit 0
