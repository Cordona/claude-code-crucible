#!/usr/bin/env sh
#
# inspect-project.sh — run static-analysis inspections (IntelliJ IDEA's headless
#                      `inspect` CLI and/or a local SonarQube scan) against a
#                      project and normalize the results into JSON an agent or a
#                      human can read directly.
#
# This file is the DISPATCHER: it sources the units in ../lib, parses argv into
# OPT_* globals, validates them, falls back to the interactive menu when the flag
# set is incomplete, sequences the engines, and prints the INSPECT_* success
# lines. Every mechanic it sequences lives in a unit — which is what makes it a
# dispatcher rather than an implementation.
#
# SHAPE. One process assembled from 7 sourced-only units in lib/, in dependency
# order:
#   lib/runtime.sh    constants, cross-unit globals, the temp workdir, the
#                     EXIT/INT/TERM/HUP teardown, the diagnostic writers
#   lib/usage.sh      --help text + the argument-presence assertions
#   lib/gitscope.sh   changed-only's git preconditions, changed-file list, and
#                     the stage-all/restore dance
#   lib/intellij.sh   the IntelliJ engine
#   lib/sonar.sh      the SonarQube engine
#   lib/output.sh     the run directory, the human summary, the machine keys
#   lib/menu.sh       the interactive collection of the same four values
# All are SOURCED, never executed. They are a READABILITY split of one process,
# not a library shared across process boundaries.
#
# =============================================================================
# The two paths, and why their stdout is identical
# =============================================================================
# A complete flag set runs straight through; an incomplete one collects the same
# four values interactively and then enters the SAME execution logic. The human
# summary goes to stderr on BOTH paths and the INSPECT_* lines to stdout on both,
# so the machine-facing output is byte-identical for the same effective inputs
# regardless of how they were collected. An agent always uses the flags.
#
# =============================================================================
# Engine availability policy
# =============================================================================
#   --engine sonar  + Sonar unavailable -> HARD FAILURE (exit 1). An explicitly
#                     requested engine is never silently skipped: a caller who
#                     asked for Sonar and got a clean-looking run with no Sonar
#                     in it has been misled about what was checked.
#   --engine both   + Sonar unavailable -> DEGRADE. IntelliJ runs alone, the
#                     summary says Sonar was skipped and why, and stdout carries
#                     INSPECT_SONAR_SKIPPED_REASON so an agent reading only the
#                     machine channel learns it too.
#
# =============================================================================
# What this script changes outside its own output directory
# =============================================================================
# Two things, both undone before it exits, both via the EXIT trap so an interrupt
# does not leave them:
#   * `<project>/-e/` — the IntelliJ CLI's report directory (see lib/intellij.sh
#     for why the report lands under a name that looks like a flag). Removed
#     after parsing. If one already exists, this script REFUSES to run rather
#     than delete somebody else's directory.
#   * `<project>/-e.lock/` — the atomic reservation of that name, held only for
#     the length of the inspection. It is what makes the refusal above a
#     reservation rather than a check two concurrent runs could both pass; see
#     lib/intellij.sh's reserve_idea_report_dir.
#   * the git index, at changed-only scope with the IntelliJ engine — staged with
#     `git add -A` so the inspection can see every change, then restored
#     best-effort. A restore failure exits non-zero even on an otherwise
#     successful run, because a caller whose staging area was left rearranged has
#     to be told. `.scannerwork/`, which sonar-scanner writes, is the scanner's
#     own artifact and is deliberately left in place.
# It NEVER commits, pushes, or writes to any remote.
#
# =============================================================================
# TRUST ASSUMPTION — what pointing this at a repository actually runs
# =============================================================================
# READ THIS BEFORE INSPECTING A REPOSITORY YOU DID NOT WRITE. This script is
# presented as "run a code inspector", which understates what it does: it
# executes the PROJECT'S OWN TOOLING against the project, so inspecting a
# directory means trusting that directory's contents and configuration with the
# invoking user's privileges.
#
# What is mitigated: every git call this script makes pins `core.fsmonitor` and
# `core.hooksPath` to inert values (lib/gitscope.sh's git_hardened), so the two
# config-driven exec points that `status`/`add -A`/`reset` would otherwise reach
# — an fsmonitor command, and `post-index-change` from a relocated hooks
# directory — cannot fire out of a repository's own `.git/config`. That matters
# because `.git/config` is not tracked content: nobody reviews it by reading the
# code, and a `.git` directory can arrive with a downloaded tarball or zip, or as
# a nested/vendored foreign checkout.
#
# What is NOT, and cannot be from here:
#   * `.gitattributes` clean/smudge filters. They are per-attribute config with
#     no blanket off switch, and `git add` runs the clean filter of a path it
#     stages.
#   * The IntelliJ CLI and sonar-scanner THEMSELVES. Both open the project the
#     way a developer would: IntelliJ's import evaluates Gradle/Maven build logic
#     and loads plugins, and the scanner reads the project's own configuration.
#     Neither is a sandbox and this script cannot make one of them.
# So "point this at a freshly-cloned, not-fully-trusted third-party repository"
# is a REAL RISK with a named mechanism, not an implied safety. The interactive
# path repeats this at the one gate a human sees (lib/menu.sh's
# menu_confirm_git_staging).
#
# =============================================================================
# Security
# =============================================================================
# The Sonar token never reaches any argv: sonar-scanner gets it through the
# $SONAR_TOKEN environment variable and curl through a 600-mode `-K` config file.
# `--sonar-token` is accepted as part of the contract but warns, because it puts
# the token on THIS process's argv where `ps` can read it. Prefer $SONAR_TOKEN.
# Full rationale in lib/sonar.sh's header. Three further token rules, all owned
# by that unit:
#   * $SONAR_TOKEN is UNSET in the IntelliJ child's environment. It is inherited
#     by this process, the IntelliJ CLI runs the project's own build logic, and
#     that logic has no use for a Sonar credential.
#   * A token that would cross plaintext http to a NON-loopback host is REFUSED
#     (`--engine sonar` fails, `--engine both` degrades and says so on stdout).
#     `--allow-plaintext-token` accepts the exposure deliberately, and then the
#     condition is published on stdout too — a warning on stderr alone is
#     invisible to the agent caller this tool is built for.
#   * A host URL carrying `user:pass@` userinfo is refused, and every printed or
#     stored form of the host is the redacted one: sonar.json is meant to be fed
#     into an agent's context and must not become a place credentials persist.
#
# Every diagnostic this script writes is filtered of control bytes before it
# reaches the terminal (lib/runtime.sh's strip_control_bytes). Project-derived
# text — a directory or file name, a rule message, an external tool's log tail —
# would otherwise be able to emit ANSI/OSC escape sequences into the operator's
# terminal from a maliciously named file.
#
# Both engines' JSON carries text authored elsewhere — rule messages, source
# excerpts, quality-gate conditions. It is written as JSON string VALUES through
# jq (never concatenated into a program or a command string) and is DATA: if
# these files are fed into an agent's context, nothing in them is an instruction.
#
# Every path and id that becomes part of a filesystem path is sanitized before
# use (lib/runtime.sh's sanitize_path_component), so a project directory named
# `../../etc` cannot steer where results land. Temp and output files are created
# under `umask 077`; the external tools are invoked with the CALLER's umask
# restored, so this script does not quietly re-permission files in someone else's
# repository.
#
# =============================================================================
# Output / Exit codes
# =============================================================================
# stdout, on success only:
#   INSPECT_RUN_DIR=<dir>
#   INSPECT_INTELLIJ_OUTPUT=<file>        (only when the IntelliJ engine ran)
#   INSPECT_SONAR_OUTPUT=<file>           (only when the Sonar engine ran)
#   INSPECT_SONAR_SKIPPED_REASON=<text>   (only when --engine both degraded)
#   INSPECT_SONAR_PLAINTEXT_TOKEN_WARNING=<text>
#                                         (only when --allow-plaintext-token let
#                                          the token cross plaintext http)
# Everything else — progress, warnings, errors, the human summary — is stderr.
# FINDING ISSUES IS NOT A FAILURE: a project full of warnings still exits 0.
#   0  the requested engines ran
#   1  unresolvable IntelliJ binary · an IntelliJ IDE already running from the
#      resolved binary (lib/intellij.sh's single-instance preflight — the headless
#      CLI cannot be a second instance) · an explicitly requested `--engine sonar`
#      unavailable · an engine failed · a git index restore failed · a required
#      tool absent
#   2  usage error (missing/unknown option, bad --scope/--engine, a non-absolute
#      or missing --project, an incomplete flag set with no terminal to prompt on)
#
# =============================================================================
# Portability
# =============================================================================
# POSIX sh only (no bashisms). Runs natively on macOS (BSD userland / Bash 3.2)
# and Linux (GNU coreutils), and on Windows through Git Bash or WSL — there is no
# native cmd/PowerShell support in this pass, and the IntelliJ resolution steps
# have no Windows branch at all (pass --idea-bin). `jq` is required; `curl` is
# required only for the Sonar engine and `git` only for changed-only scope, and
# each is guarded with `command -v` at the point it becomes necessary. jq is used
# only with static programs fed via --arg/--argjson/--rawfile/--slurpfile, and
# with NO regex builtins, so it needs no Oniguruma-enabled build. The units are
# resolved with pure parameter expansion, never dirname/readlink/realpath/
# basename — the same rule every sibling script in this repository follows.
#
set -eu

LC_ALL=C
export LC_ALL

# shellcheck disable=SC2034  # read by lib/runtime.sh's warn()/error()/note(); shellcheck cannot follow the dynamic sourcing loop below, so it sees no reader
PROG=${0##*/}

# Everything this file reaches for is located RELATIVE TO THIS SCRIPT, using only
# parameter expansion. The `*)` branch is unreachable in practice (the script is
# invoked by a path) but exists so `set -u` can never see an unset SCRIPT_DIR.
case "$0" in
	*/*) SCRIPT_DIR=${0%/*} ;;
	*)   SCRIPT_DIR=. ;;
esac
LIB_DIR="$SCRIPT_DIR/lib"

# Each unit is checked for readability first, so a broken or partial deployment
# fails with a named diagnostic instead of a bare "not found" from the shell.
for _inspect_unit in \
	"$LIB_DIR/runtime.sh" "$LIB_DIR/usage.sh" "$LIB_DIR/gitscope.sh" \
	"$LIB_DIR/intellij.sh" "$LIB_DIR/sonar.sh" "$LIB_DIR/output.sh" \
	"$LIB_DIR/menu.sh" ; do
	[ -r "$_inspect_unit" ] || {
		printf '%s: error: internal: missing unit: %s\n' "${0##*/}" "$_inspect_unit" >&2
		exit 1
	}
	# shellcheck disable=SC1090  # the path is a loop variable by design; each unit is linted individually via its own `shellcheck shell=sh` directive
	. "$_inspect_unit"
done
unset _inspect_unit

# ---------------------------------------------------------------------------
# Argv -> OPT_*
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # block-wide: shellcheck cannot follow the dynamic sourcing loop above, so it sees no reader for the carriers consumed by lib/intellij.sh and lib/sonar.sh
while [ $# -gt 0 ]; do
	case "$1" in
		--project)        need_arg "$1" "${2:-}"; OPT_PROJECT=$2; shift ;;
		--scope)          need_arg "$1" "${2:-}"; OPT_SCOPE=$2; shift ;;
		--engine)         need_arg "$1" "${2:-}"; OPT_ENGINE=$2; shift ;;
		--output-root)    need_arg "$1" "${2:-}"; OPT_OUTPUT_ROOT=$2; shift ;;
		--idea-bin)       need_arg "$1" "${2:-}"; OPT_IDEA_BIN=$2; shift ;;
		--sonar-host-url) need_arg "$1" "${2:-}"; OPT_SONAR_HOST_URL=$2; shift ;;
		--sonar-token)    need_arg "$1" "${2:-}"; OPT_SONAR_TOKEN=$2; shift ;;
		# Valueless, and deliberately so: it is a consent switch, not a setting.
		--allow-plaintext-token) OPT_ALLOW_PLAINTEXT_TOKEN=1 ;;
		# The ONE flag whose empty value is meaningful: `--exclude-ids ''`
		# disables exclusion entirely, which is what makes the default list a
		# default rather than a floor.
		--exclude-ids)    need_arg_allow_empty "$1" "$#"; OPT_EXCLUDE_IDS=$2; OPT_EXCLUDE_IDS_GIVEN=1; shift ;;
		-h|--help)        usage; exit 0 ;;
		--)               shift; break ;;
		-*)               usage >&2; error "unknown option: $1"; exit 2 ;;
		*)                usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

# ---------------------------------------------------------------------------
# Validate whatever was given, BEFORE any tool check or prompt — a caller's own
# typo should surface as a usage error before this script asks whether jq is
# installed or opens an interactive menu.
# ---------------------------------------------------------------------------
if [ -n "$OPT_SCOPE" ]; then
	case "$OPT_SCOPE" in
		all|changed-only) : ;;
		*) usage >&2; error "--scope must be 'all' or 'changed-only', got: $OPT_SCOPE"; exit 2 ;;
	esac
fi

if [ -n "$OPT_ENGINE" ]; then
	case "$OPT_ENGINE" in
		intellij|sonar|both) : ;;
		*) usage >&2; error "--engine must be 'intellij', 'sonar' or 'both', got: $OPT_ENGINE"; exit 2 ;;
	esac
fi

if [ -n "$OPT_PROJECT" ]; then
	case "$OPT_PROJECT" in
		/*) : ;;
		*) usage >&2; error "--project must be an absolute path, got: $OPT_PROJECT"; exit 2 ;;
	esac
	OPT_PROJECT=$(strip_trailing_slashes "$OPT_PROJECT")
	[ -d "$OPT_PROJECT" ] || { error "--project is not a directory: $OPT_PROJECT"; exit 2; }
fi

if [ -n "$OPT_OUTPUT_ROOT" ]; then
	case "$OPT_OUTPUT_ROOT" in
		/*) : ;;
		*) usage >&2; error "--output-root must be an absolute path, got: $OPT_OUTPUT_ROOT"; exit 2 ;;
	esac
	OPT_OUTPUT_ROOT=$(strip_trailing_slashes "$OPT_OUTPUT_ROOT")
fi

if [ -n "$OPT_SONAR_TOKEN" ]; then
	warn "--sonar-token puts the token on this process's argv, where any local user can read it via \`ps\`; prefer \$SONAR_TOKEN"
fi

# ---------------------------------------------------------------------------
# Preconditions common to both paths. jq is unconditional: every engine's output
# is assembled with it, so an absent jq cannot produce a partial result.
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
	error "jq is not installed"
	warn  "install it (e.g. https://jqlang.org) then re-run"
	exit 1
fi

ensure_workdir

# ---------------------------------------------------------------------------
# Flag path or menu path
#
# An incomplete flag set with no terminal to prompt on is a USAGE error, never a
# prompt: a script or an agent invoking this with a missing flag must fail fast
# and say which values are collected interactively, not block forever on a read
# nobody will answer. stdin AND stderr are both required to be a terminal —
# stderr because that is where every prompt is written.
# ---------------------------------------------------------------------------
if [ -z "$OPT_PROJECT" ] || [ -z "$OPT_SCOPE" ] || [ -z "$OPT_ENGINE" ]; then
	if [ ! -t 0 ] || [ ! -t 2 ]; then
		usage >&2
		error "--project, --scope and --engine are all required when there is no terminal to prompt on"
		exit 2
	fi
	MENU_RC=0
	run_menu || MENU_RC=$?
	[ "$MENU_RC" -eq 0 ] || exit 0
fi

OPT_OUTPUT_ROOT=${OPT_OUTPUT_ROOT:-$OUTPUT_ROOT_DEFAULT}

# ---------------------------------------------------------------------------
# Run identity
#
# PROJECT_NAME is the project's real basename and goes into the JSON metadata
# verbatim; PROJECT_DIR_NAME is its sanitized form and is what becomes a path
# component. They are separate on purpose — the metadata should say what the
# directory is actually called, and the filesystem should not be steered by it.
# ---------------------------------------------------------------------------
PROJECT_NAME=${OPT_PROJECT##*/}
[ -n "$PROJECT_NAME" ] || PROJECT_NAME=project
PROJECT_DIR_NAME=$(sanitize_path_component "$PROJECT_NAME")
# shellcheck disable=SC2034  # read by lib/intellij.sh's and lib/sonar.sh's jq metadata blocks; see the SC2034 note on PROG above
GENERATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# ---------------------------------------------------------------------------
# Scope resolution
#
# The changed-file list is computed ONCE, here, BEFORE anything is mutated: the
# IntelliJ path stages everything (destroying the staged/unstaged distinction it
# was read from) and the Sonar path runs after that, so this is the only moment
# at which both engines can be made to agree on what "changed" meant.
#
# For `all` scope the file is still created, empty: it is an unconditional jq
# --rawfile input, and a conditionally-absent input is a conditionally-broken
# invocation.
# ---------------------------------------------------------------------------
CHANGED_FILES_FILE="$WORKDIR/changed-files.txt"
: >"$CHANGED_FILES_FILE"

if [ "$OPT_SCOPE" = changed-only ]; then
	require_changed_scope_preconditions "$OPT_PROJECT" || exit 1
	collect_changed_files "$CHANGED_FILES_FILE" || exit 1
	note "changed-only scope: $(count_changed_files) changed file(s) vs HEAD in $OPT_PROJECT"
fi

# ---------------------------------------------------------------------------
# Sonar availability + the hard-fail/degrade decision
# ---------------------------------------------------------------------------
RUN_SONAR=0
case "$OPT_ENGINE" in
	sonar|both)
		# Idempotent: on the menu path this verdict was already reached to label the
		# `sonar` option, and is reused rather than re-probed — which is part of what
		# keeps the two entry paths' output identical.
		detect_sonar
		if [ "$SONAR_AVAILABLE" -eq 1 ]; then
			RUN_SONAR=1
		elif [ "$OPT_ENGINE" = sonar ]; then
			error "--engine sonar was requested but Sonar is not available: $SONAR_SKIP_REASON"
			exit 1
		else
			# shellcheck disable=SC2034  # read by lib/output.sh's print_run_summary()/print_machine_keys(); shellcheck cannot follow the dynamic sourcing loop above, so it sees no reader
			SONAR_DEGRADED=1
			warn "Sonar is unavailable, running IntelliJ alone: $SONAR_SKIP_REASON"
		fi
		;;
esac

RUN_INTELLIJ=0
case "$OPT_ENGINE" in
	intellij|both) RUN_INTELLIJ=1 ;;
esac

# ---------------------------------------------------------------------------
# Execute
#
# `umask 077` scopes the permissions of everything created from here on: results
# are a private analysis cache, and they quote the project's own source. The
# external tools restore the caller's umask themselves (see ORIG_UMASK).
# ---------------------------------------------------------------------------
umask 077

prepare_run_dir "$OPT_OUTPUT_ROOT" "$PROJECT_DIR_NAME" || exit 1

if [ "$RUN_INTELLIJ" -eq 1 ]; then
	if [ "$OPT_SCOPE" = changed-only ] && [ "$(count_changed_files)" -gt 0 ]; then
		stage_all_changes || exit 1
	fi
	run_intellij_engine || exit 1
	# Restored as soon as the engine that needed it is done, rather than only in
	# the teardown, so the caller's index is not left staged for the length of a
	# Sonar scan. cleanup() still calls it — it is a no-op once it has run.
	restore_git_index || exit 1
fi

if [ "$RUN_SONAR" -eq 1 ]; then
	run_sonar_engine || exit 1
fi

print_run_summary
print_machine_keys
exit 0
