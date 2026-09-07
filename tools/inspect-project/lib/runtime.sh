# shellcheck shell=sh
#
# runtime.sh — the script's process-wide runtime: the tuning constants, every
#              mutable global, the temp workdir, the EXIT/INT/TERM/HUP teardown,
#              and the three diagnostic writers every other unit calls.
#
# Sourced FIRST (see inspect-project.sh's sourcing loop): the globals it declares
# are the state every later unit reads and writes, and its `trap` must be
# installed before any unit can create a temp file, stage a git index, or let
# the IntelliJ CLI write a report directory into the user's project.
#
# Sourced by inspect-project.sh — never executed directly. Sets no shell options
# and runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.
#
# shellcheck disable=SC2034  # file-wide, deliberately: declaring cross-unit globals IS this file's entire job, and shellcheck lints each unit in isolation so it can never see the readers in the other 7

# ---------------------------------------------------------------------------
# Terminal-safety filter
#
# EVERY DIAGNOSTIC THIS SCRIPT WRITES PASSES THROUGH IT, and that is the point.
# Almost everything the three writers below interpolate is authored elsewhere: a
# project's own directory and file names, a report filename, an IntelliJ profile
# name, a Sonar rule message, the tail of an external tool's log. A terminal
# interprets the C0 control bytes in that text — ESC starts an ANSI/OSC sequence
# that can rewrite what is already on screen, set the window title, or (with
# bracketed paste) plant text in the user's input buffer, and CR alone can
# overwrite a line that has already been printed. So a maliciously named file in
# an inspected repository is a terminal-injection sink (CWE-150), and filtering
# at each interpolation site would mean getting it right at every one of the
# ~60 call sites forever. Filtering inside the writers is one place instead.
#
# TAB (\011) AND NEWLINE (\012) ARE DELIBERATELY KEPT — both are ordinary layout
# in this script's own multi-line messages. CR (\015) is NOT kept: nothing here
# emits one on purpose, and it is precisely the byte that lets injected text
# overwrite a line already on screen. Bytes >= 0x80 pass through untouched, so a
# UTF-8 project or file name still renders as itself.
#
# The JSON channel needs none of this: every value there is written as a JSON
# string through jq, which escapes control characters itself.
# ---------------------------------------------------------------------------

# strip_control_bytes — filter stdin to stdout, dropping the C0 controls except
# tab and newline, plus DEL. The one place the byte set is spelled out.
strip_control_bytes() { tr -d '\000-\010\013-\037\177'; }

# sanitize_for_terminal VALUE -> VALUE with the same bytes dropped. For the
# handful of places that build a display string rather than write a whole line.
sanitize_for_terminal() { printf '%s' "$1" | strip_control_bytes; }

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout carries ONLY the INSPECT_* success lines)
# ---------------------------------------------------------------------------
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" | strip_control_bytes >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" | strip_control_bytes >&2; }
# note — human/progress chatter. Unprefixed (it is not a diagnostic about this
# script, it is the running commentary a watching human reads) but still stderr,
# because stdout is the machine channel.
note()  { printf '%s\n' "$*" | strip_control_bytes >&2; }

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
OUTPUT_ROOT_DEFAULT="$HOME/.crucible-inspect-results"
SONAR_HOST_URL_DEFAULT="http://localhost:9000"

# EXCLUDE_IDS_DEFAULT — the linguistic-noise IntelliJ inspections that are near
# pure noise for code-quality triage. A DEFAULT, never a hardcoded floor:
# --exclude-ids replaces this list outright, `--exclude-ids +ID` extends it, and
# `--exclude-ids ''` disables exclusion entirely.
EXCLUDE_IDS_DEFAULT="GrazieInspection,GrazieStyle,SpellCheckingInspection"

# Sonar compute-engine polling: a bounded, early-returning poll (never an
# unbounded wait) — 90 attempts x 2s = a 3-minute ceiling.
SONAR_POLL_MAX_ATTEMPTS=90
SONAR_POLL_INTERVAL=2

# Sonar issue paging. Sonar's own api/issues/search refuses ps>500 and caps the
# reachable result set at 10000, so 20 pages x 500 IS that ceiling rather than an
# arbitrary one.
SONAR_ISSUES_PAGE_SIZE=500
SONAR_ISSUES_MAX_PAGES=20

# How much of a failed external tool's log to echo. Only ever on failure, and
# only the tail — an inspection log is large and quotes the project's own source.
LOG_TAIL_LINES=20

# Run-directory collision suffixes tried before giving up (two runs of the same
# project inside one second).
RUN_DIR_MAX_ATTEMPTS=100

NL='
'

# ORIG_UMASK — the caller's umask, captured before this script tightens it to
# 077 for its own temp and output files. The external tools (the IntelliJ CLI,
# sonar-scanner) are invoked with it RESTORED: both write into the user's own
# project tree (./-e/, ./.scannerwork/), and silently narrowing the permissions
# of files in someone else's repository is a side effect this script has no
# business having.
ORIG_UMASK=$(umask)

OS_NAME=$(uname -s 2>/dev/null || printf 'unknown')

# ---------------------------------------------------------------------------
# Global state (plain vars — this is a single short-lived process, not a
# library, and POSIX sh has no `local`).
#
# CONVENTION for anyone adding or editing a unit: every helper function's
# scratch/parameter variables are plain globals scoped ONLY by a name that is
# unique to that function, via a SHORT PER-FUNCTION PREFIX derived from the
# function's own name (resolve_idea_bin's `rib_*`, sonar_wait_for_task's
# `swft_*`). Never a bare `path`/`file`/`value`/`status` — those read as "any
# function's scratch", which is exactly what makes them collide across a
# caller/callee boundary the shell cannot warn about. Same rule, same reason, as
# procedure-jira's engine.
# ---------------------------------------------------------------------------
WORKDIR=""
RESP_COUNTER=0

# Resolved inputs (argv or the interactive menu — the two paths converge here).
OPT_PROJECT=""
OPT_SCOPE=""
OPT_ENGINE=""
OPT_OUTPUT_ROOT=""
OPT_IDEA_BIN=""
OPT_SONAR_HOST_URL=""
OPT_SONAR_TOKEN=""
OPT_EXCLUDE_IDS=""
OPT_EXCLUDE_IDS_GIVEN=0
# The one opt-in that relaxes a credential-transport refusal: without it, a token
# that would cross plaintext http to a non-loopback host makes Sonar unavailable
# rather than being sent in the clear. See lib/sonar.sh's plaintext-token block.
OPT_ALLOW_PLAINTEXT_TOKEN=0

# Derived run identity.
PROJECT_NAME=""
PROJECT_DIR_NAME=""
GENERATED_AT=""
RUN_DIR=""
CHANGED_FILES_FILE=""

# Written-output paths — empty until that engine has actually produced a file,
# which is what makes them the source of truth for both the summary and the
# INSPECT_* stdout lines.
INTELLIJ_OUTPUT=""
SONAR_OUTPUT=""

# IntelliJ engine state.
IDEA_BIN_RESOLVED=""
IDEA_RESOLUTION_LOG=""
IDEA_EDIR=""
# IDEA_EDIR_LOCK / IDEA_EDIR_OWNED — the atomic reservation of `<project>/-e`
# (lib/intellij.sh's run_intellij_inspection) and the record that THIS run made
# it. OWNED is what licenses the teardown to remove `-e` whatever kind of node
# the CLI actually left there: a file, a symlink, or a directory are all this
# tool's own litter once the reservation succeeded, and leaving any of them
# behind makes every later run refuse until a human removes it by hand.
IDEA_EDIR_LOCK=""
IDEA_EDIR_OWNED=0
# How many IntelliJ report files could not be parsed. Reported in intellij.json's
# metadata, because a parse failure drops that file's findings and a
# machine-readable `total_issues` with no such marker reads as "clean".
INTELLIJ_UNPARSED_REPORT_FILES=0
INTELLIJ_PROFILE="unknown"
SONARLINT_PLUGIN_INSTALLED=false
# The two SonarLint profile signals, both distilled from `.descriptions.json`:
# REGISTERED is any inspection contributed by a plugin whose id mentions sonar,
# ENABLED narrows it to the ones this profile actually switches on. Separate,
# because "installed but switched off" and "never installed" are different
# problems and both read as an empty Sonar result set.
SONARLINT_RULES_REGISTERED=false
SONARLINT_RULES_ENABLED=false

# Git repository geometry, resolved once for `changed-only` scope.
#
# --project is NOT required to be a repository root — inspecting one module of a
# monorepo is an ordinary request. So the repo root and the project's path
# relative to it are resolved up front and every git operation is expressed in
# those terms: `--porcelain` reports paths relative to the ROOT regardless of
# which directory git was invoked from, while both engines report paths relative
# to the PROJECT, and `add`/`reset` pathspecs resolve against git's cwd.
# Conflating the three silently mis-filters Sonar's issues and makes the index
# restore target paths that do not exist.
GIT_REPO_ROOT=""
GIT_PROJECT_PREFIX=""
GIT_PROJECT_PATHSPEC=""

# Git-index mutation state, read by restore_git_index() on every exit path.
#
# GIT_STAGE_ROOT is the REPOSITORY ROOT the staging was applied at — not the
# project. The name says so explicitly because conflating the two bases is the
# exact defect this unit's geometry comment above exists to prevent, and a
# variable called `..._PROJECT` holding a root invites a future edit to
# reintroduce it.
GIT_STAGE_APPLIED=0
GIT_STAGE_ROOT=""
GIT_STAGED_SNAPSHOT=""

# Sonar engine state.
SONAR_HOST=""
# SONAR_HOST_DISPLAY — the ONLY form of the host that may be printed to a
# terminal or written into sonar.json. It is SONAR_HOST with any `user[:pass]@`
# userinfo redacted and control bytes stripped, because sonar.json is explicitly
# meant to be fed into an agent's context and a host URL carrying a credential
# would persist it there. SONAR_HOST itself is what actually reaches curl and
# sonar-scanner; keeping the two apart is what makes "never print the connection
# form" a structural property rather than a rule every message has to remember.
SONAR_HOST_DISPLAY=""
# SONAR_PLAINTEXT_TOKEN_WARNING — non-empty only when --allow-plaintext-token
# was used AND the token really did cross plaintext to a non-loopback host. It
# becomes INSPECT_SONAR_PLAINTEXT_TOKEN_WARNING on stdout, so the machine channel
# is not silent about a credential sent in the clear (stderr, where the matching
# warning goes, is documented as a channel an agent caller does not parse).
SONAR_PLAINTEXT_TOKEN_WARNING=""
SONAR_AVAILABLE=0
SONAR_DETECTED=0
SONAR_SKIP_REASON=""
# SONAR_DEGRADED — set at the ONE place `--engine both` falls back to IntelliJ
# alone. Deliberately a separate flag rather than inferred from a non-empty
# SONAR_SKIP_REASON: the interactive menu probes Sonar on every run just to label
# its own option, so a reason exists even when Sonar was never requested — and
# reporting "Sonar was skipped" to a caller who asked for `--engine intellij` is
# both noise and untrue (nothing was skipped), and made the two entry paths'
# stdout differ for identical effective inputs.
SONAR_DEGRADED=0
SONAR_CHECK_SCANNER=false
SONAR_CHECK_SERVER=false
SONAR_CHECK_CONFIG=false
SONAR_SCANNER_BIN=""
SONAR_PROJECT_KEY=""
SONAR_ANALYSIS_ID=""
SONAR_TOTAL_PROJECT_WIDE=0
SONAR_BODY_FILE=""
SONAR_HTTP_CODE=""
CURL_CONFIG_FILE=""

# ---------------------------------------------------------------------------
# Teardown
#
# WHY THE ORDER BELOW IS THE ORDER. The git index is restored FIRST and its
# failure is allowed to CHANGE the exit status, because it is the only piece of
# teardown that touches state the user cares about keeping: everything else here
# is this script's own litter. A restore failure on an otherwise-successful run
# therefore exits non-zero — the run's findings are still on disk, but the
# caller must be told their staging area is not what they left it as.
#
# The functions this reaches for live in units sourced AFTER this one, which is
# safe because a trap body is evaluated when the trap FIRES, not when it is
# installed — but they are still `command -v`-guarded, so a broken or partial
# deployment that dies mid-sourcing gets a clean exit instead of a
# "command not found" cascade out of the handler.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	cln_ec=$?

	if command -v restore_git_index >/dev/null 2>&1; then
		if ! restore_git_index; then
			[ "$cln_ec" -ne 0 ] || cln_ec=1
		fi
	fi

	if command -v release_idea_report_dir >/dev/null 2>&1; then
		release_idea_report_dir
	fi

	# An empty run directory is a run that produced nothing — remove it rather
	# than litter the results tree with a dated marker for a failed attempt.
	# `rmdir` is the check: it refuses a non-empty directory, so a partial run's
	# output can never be swept away by this.
	if [ -n "$RUN_DIR" ]; then
		rmdir "$RUN_DIR" 2>/dev/null || true
	fi

	if [ -n "$CURL_CONFIG_FILE" ]; then
		rm -f -- "$CURL_CONFIG_FILE" 2>/dev/null || true
		CURL_CONFIG_FILE=""
	fi

	if [ -n "$WORKDIR" ]; then
		rm -rf -- "$WORKDIR" 2>/dev/null || true
		WORKDIR=""
	fi

	exit "$cln_ec"
}

# on_signal NAME NUMBER — the signal half of the teardown, separate from the EXIT
# trap on purpose.
#
# A single `trap cleanup EXIT INT TERM HUP` would run the teardown correctly but
# exit with WHATEVER `$?` happened to hold when the signal landed — which, for a
# script interrupted while waiting on a child, is usually 0. An interrupted run
# reporting success is the one outcome worth extra machinery to avoid, so each
# signal exits 128+signo instead (130 on INT, 143 on TERM, 129 on HUP, the shell
# convention). `exit` still fires the EXIT trap, so cleanup runs exactly once and
# sees the code set here.
# shellcheck disable=SC2329  # invoked indirectly via trap
on_signal() {
	error "interrupted by SIG$1 — cleaning up"
	exit $((128 + $2))
}

trap cleanup EXIT
trap 'on_signal INT 2' INT
trap 'on_signal TERM 15' TERM
trap 'on_signal HUP 1' HUP

ensure_workdir() {
	if [ -z "$WORKDIR" ]; then
		WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/inspect-project.work.XXXXXX")
	fi
}

# ---------------------------------------------------------------------------
# Small generic helpers
# ---------------------------------------------------------------------------

is_macos() { [ "$OS_NAME" = Darwin ]; }

urlencode() {
	jq -rn --arg v "$1" '$v | @uri'
}

# csv_to_lines CSV -> one trimmed, non-empty element per line.
csv_to_lines() {
	printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d'
}

# sanitize_path_component VALUE -> VALUE reduced to [A-Za-z0-9._-], with every
# other byte replaced by `_`. This value becomes a PATH COMPONENT under
# --output-root, so a project directory literally named `../../etc` or holding a
# newline must not be able to steer where results land. `.` and `..` are mapped
# too, for the same reason.
sanitize_path_component() {
	spc_value=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
	case "$spc_value" in
		''|.|..) spc_value=project ;;
	esac
	printf '%s' "$spc_value"
}

# strip_trailing_slashes PATH -> PATH with trailing `/` removed, except for `/`
# itself. Keeps `${var##*/}` basename derivation and every "$PROJECT/x" join
# from producing a doubled separator.
strip_trailing_slashes() {
	sts_value=$1
	while :; do
		case "$sts_value" in
			/) break ;;
			*/) sts_value=${sts_value%/} ;;
			*) break ;;
		esac
	done
	printf '%s' "$sts_value"
}

# strip_prefix VALUE PREFIX -> VALUE with PREFIX removed, or non-zero if VALUE
# does not start with PREFIX. An empty PREFIX always matches and changes nothing.
#
# The non-zero return is the point: a caller rebasing paths onto a narrower base
# needs "this path is not under that base" to be a distinguishable answer rather
# than silently passing the path through unchanged on the wrong base.
strip_prefix() {
	sp_value=$1
	sp_prefix=$2
	[ -n "$sp_prefix" ] || { printf '%s' "$sp_value"; return 0; }
	case "$sp_value" in
		"$sp_prefix"*) printf '%s' "${sp_value#"$sp_prefix"}" ;;
		*) return 1 ;;
	esac
}

# report_log_tail FILE — echo the tail of an external tool's captured output to
# stderr. Called ONLY on that tool's failure: an inspection log is large and
# quotes the project's own source, so it is a diagnostic aid, never routine
# output.
#
# The tail is FILTERED, not echoed raw: it is the most directly attacker-shaped
# text this script prints — an external tool's rendering of the inspected
# project's own source and file names — so it goes through the same filter the
# three writers use. See strip_control_bytes at the top of this file.
report_log_tail() {
	rlt_file=$1
	[ -s "$rlt_file" ] || return 0
	printf '%s: --- last %s lines of %s ---\n' "$PROG" "$LOG_TAIL_LINES" "$rlt_file" |
		strip_control_bytes >&2
	tail -n "$LOG_TAIL_LINES" "$rlt_file" 2>/dev/null | strip_control_bytes >&2 || true
	printf '%s: --- end of captured output ---\n' "$PROG" >&2
}
