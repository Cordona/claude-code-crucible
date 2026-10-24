#!/usr/bin/env sh
#
# run-git-tests.sh — the git-index save/restore dance: `--scope changed-only`
#                    stages the project's subtree so IntelliJ's `-changes` mode
#                    can see untracked files, then puts the index back.
#
# WHY THIS SUITE IS THE FIRST ONE. It is the only part of inspect-project that
# mutates state the user cares about keeping, it has already carried one
# HIGH-severity defect (an unscoped `git add -A` that rearranged the index of every
# unrelated module in a monorepo), and its blast radius is somebody's real
# repository. Everything here runs against REAL git repositories in a temp
# directory — see lib/gitfixture.sh for why a git stub would verify this author's
# beliefs about git instead of the tool.
#
# THE CENTRAL ASSERTION SHAPE is `git status --porcelain -uall` captured before the
# run and compared BYTE-FOR-BYTE after it. Two things make that comparison mean
# something rather than pass vacuously: every fixture carries all three change
# kinds at once (staged, unstaged, untracked — lib/gitfixture.sh's
# git_seed_mixed_changes), and the recorded git argv is asserted separately, because
# an unscoped `add -A` that is then perfectly undone leaves state identical too.
#
# Usage:  sh run-git-tests.sh
#         VERBOSE=1 sh run-git-tests.sh
# Exit 0 = all passed, 1 = one or more failed.
#
set -eu

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/lib/harness.sh
. "$TESTS_DIR/lib/harness.sh"
# shellcheck source=SCRIPTDIR/lib/stubs.sh
. "$TESTS_DIR/lib/stubs.sh"
# shellcheck source=SCRIPTDIR/lib/rig.sh
. "$TESTS_DIR/lib/rig.sh"
# shellcheck source=SCRIPTDIR/lib/gitfixture.sh
. "$TESTS_DIR/lib/gitfixture.sh"

rig_setup "$TESTS_DIR" git

# GIT_HARDENED_OPTS — the fixed option set lib/gitscope.sh's git_hardened puts in
# front of EVERY git call it makes, in its exact argv order, as the recorder logs
# it. Named once rather than spelled at each of the seven argv assertions below,
# for the reason lib/gitfixture.sh's GIT_SEEDED_CHANGE_COUNT is: a change to the
# wrapper must break those assertions in one place, not leave six of them stale.
#
# THE THREE OPTIONS ARE HERE FOR TWO DIFFERENT REASONS, and the assertions that
# read this constant carry both claims at once. `-c core.fsmonitor=` and
# `-c core.hooksPath=/dev/null` beat a repository's own config at the two exec
# points an index refresh would otherwise reach — asserted for EFFECT, not only
# for presence, by the hostile-config section further down. `--literal-pathspecs`
# is the pathspec-correctness flag the glob-metachar sections are about.
GIT_HARDENED_OPTS='-c core.fsmonitor= -c core.hooksPath=/dev/null --literal-pathspecs'

# run SELECTOR COMMAND... — the PATH-toolbox selector map, the one part of the
# runner that is genuinely per-suite. `git` comes from the RECORDER directory in
# every selector but `nogit`, so it shadows the toolbox's real git and every call
# is logged while still executing for real.
run() {
	r_selector=$1; shift
	case "$r_selector" in
		full)  r_path="$BIN_GIT:$BIN_TR:$BIN_DATE:$BIN_IDEA:$TOOLBOX" ;;
		nogit) r_path="$BIN_TR:$BIN_DATE:$BIN_IDEA:$TOOLBOX" ;;
		*) printf 'FATAL: bad run() selector: %s\n' "$r_selector" >&2; exit 1 ;;
	esac
	harness_run "$r_path" "$@"
}

# inspect PROJECT RESULTS_TAG [DEVIATION...] — the one invocation this whole suite
# is about (changed-only, IntelliJ, git on PATH), so no test spells the eight flags
# itself. EVERY run in this suite goes through here, including the two that
# deliberately vary the scope or drop git from PATH.
#
# EVERY STUB CONTROL IS RESET FIRST and every deviation from the default is passed
# HERE, as an explicit argument. Nothing is left set for the next test to inherit —
# see rig.sh's rig_reset_stub_state for why an ambient set/hand-reset pair is a
# defect rather than a style choice.
#
#   --edir SRC        the report directory the CLI stub writes
#   --exit N          the exit status the CLI stub ends with
#   --signal NAME     a signal the CLI stub sends the script before exiting
#   --git-fail TOKENS make the git recorder fail the call carrying every TOKEN
#   --tr-fail N       make the Nth `tr '\0' '\n'` decode fail
#   --env VAR=VALUE   an environment variable inspect-project INHERITS, set the
#                     way a git hook would (see the `env` note in rig.sh).
#                     Repeatable.
#   --scope SCOPE     `all` instead of `changed-only`
#   --selector NAME   a different PATH composition (`nogit`)
inspect() {
	i_project=$1
	i_results=$(results_root "$2")
	shift 2
	rig_reset_stub_state
	IDEA_STUB_EDIR_SRC="$FIXTURES/edir-basic"
	i_inherited=""
	i_scope=changed-only
	i_selector=full
	set -- "$@" --
	while [ "$1" != -- ]; do
		case "$1" in
			--edir)     IDEA_STUB_EDIR_SRC=$2; shift 2 ;;
			--exit)     IDEA_STUB_EXIT=$2; shift 2 ;;
			--signal)   IDEA_STUB_SIGNAL_PARENT=$2; shift 2 ;;
			--git-fail) GIT_STUB_FAIL_TOKENS=$2; shift 2 ;;
			--tr-fail)  TR_STUB_FAIL_NUL_CALL=$2; shift 2 ;;
			--env)      i_inherited="$i_inherited $2"; shift 2 ;;
			--scope)    i_scope=$2; shift 2 ;;
			--selector) i_selector=$2; shift 2 ;;
			*) printf 'FATAL: bad inspect deviation: %s\n' "$1" >&2; exit 1 ;;
		esac
	done
	rig_reset_logs
	# shellcheck disable=SC2086  # $i_inherited is a deliberately word-split list of VAR=VALUE tokens, which is exactly the argument form `env` takes
	run "$i_selector" env $i_inherited "$INSPECT" \
		--project "$i_project" --scope "$i_scope" --engine intellij \
		--output-root "$i_results" --idea-bin "$BIN_IDEA/idea"
}

# ===========================================================================
section "changed-only, --project AT the repository root"
# ===========================================================================
ROOT_REPO="$WORK/projects/rootrepo"
git_init_repo "$ROOT_REPO"
git_seed_mixed_changes "$ROOT_REPO" ""
ROOT_BEFORE=$(git_status_snapshot "$ROOT_REPO")
# git's own spelling of the repository root, which is what every recorded `git -C`
# argv carries. Taken from git rather than from $ROOT_REPO because git resolves
# symlinks (on macOS /var is a link to /private/var) and an argv assertion has to
# match the bytes that were actually passed.
ROOT_TOPLEVEL=$(git_fix "$ROOT_REPO" rev-parse --show-toplevel)

inspect "$ROOT_REPO" root
ROOT_AFTER=$(git_status_snapshot "$ROOT_REPO")

expect_rc "root repo: the run succeeds" 0
equals "root repo: git status is byte-identical before and after" "$ROOT_AFTER" "$ROOT_BEFORE"
equals "root repo: the previously staged path is staged again" \
	"$(git_status_of "$ROOT_REPO" staged.rs)" "A "
equals "root repo: the unstaged modification is unstaged again" \
	"$(git_status_of "$ROOT_REPO" tracked.rs)" " M"
equals "root repo: the untracked file is untracked again" \
	"$(git_status_of "$ROOT_REPO" untracked.rs)" "??"
# The three change shapes the `-z` / `--untracked-files=all` / `add -A` flags are
# individually load-bearing for. Each was previously absent from every fixture, so
# dropping any one of those flags left the whole suite green.
equals "root repo: a STAGED path containing a SPACE is staged again" \
	"$(git_status_of "$ROOT_REPO" 'staged with space.rs')" "A "
equals "root repo: an untracked file inside a NEW untracked directory is untracked again" \
	"$(git_status_of "$ROOT_REPO" newdir/nested.rs)" "??"
equals "root repo: a STAGED DELETION comes back as a staged deletion, not an unstaged one" \
	"$(git_status_of "$ROOT_REPO" doomed.rs)" "D "
log_has_token "root repo: the inspection is invoked with -changes" "$IDEA_STUB_ARGV_LOG" "-changes"
stderr_has "root repo: every seeded change is counted" \
	"changed-only scope: $GIT_SEEDED_CHANGE_COUNT changed file(s)"
equals "root repo: the stage-all call is scoped to the whole-repo pathspec '.'" \
	"$(git_recorded_call add "$GIT_STUB_ARGV_LOG")" \
	"-C $ROOT_TOPLEVEL $GIT_HARDENED_OPTS add -A -- ."
equals "root repo: the restore unstages that same pathspec" \
	"$(git_recorded_call reset "$GIT_STUB_ARGV_LOG")" \
	"-C $ROOT_TOPLEVEL $GIT_HARDENED_OPTS reset -q -- ."

# ===========================================================================
section "changed-only, --project a SUBDIRECTORY of a larger repository"
# ===========================================================================
# The defect class this section exists for: `git add -A` run from a subdirectory
# stages the ENTIRE work tree, so inspecting one module rearranges the index of
# every unrelated module in the monorepo.
MONO="$WORK/projects/mono"
git_init_repo "$MONO"
git_seed_mixed_changes "$MONO" "mod-a/"
git_seed_mixed_changes "$MONO" "mod-b/"
printf 'root-level\n' >"$MONO/root-untracked.rs"
MONO_BEFORE=$(git_status_snapshot "$MONO")
MONO_TOPLEVEL=$(git_fix "$MONO" rev-parse --show-toplevel)

inspect "$MONO/mod-a" mono
MONO_AFTER=$(git_status_snapshot "$MONO")

expect_rc "subtree: the run succeeds" 0
equals "subtree: the WHOLE repository's git status is byte-identical" "$MONO_AFTER" "$MONO_BEFORE"
equals "subtree: the stage-all call is scoped to the project subtree, not the repo" \
	"$(git_recorded_call add "$GIT_STUB_ARGV_LOG")" \
	"-C $MONO_TOPLEVEL $GIT_HARDENED_OPTS add -A -- mod-a/"
equals "subtree: the restore is scoped to that same subtree" \
	"$(git_recorded_call reset "$GIT_STUB_ARGV_LOG")" \
	"-C $MONO_TOPLEVEL $GIT_HARDENED_OPTS reset -q -- mod-a/"
equals "subtree: a staged file OUTSIDE the subtree is left staged" \
	"$(git_status_of "$MONO" mod-b/staged.rs)" "A "
equals "subtree: a modification OUTSIDE the subtree is left unstaged" \
	"$(git_status_of "$MONO" mod-b/tracked.rs)" " M"
equals "subtree: an untracked file OUTSIDE the subtree is left untracked" \
	"$(git_status_of "$MONO" mod-b/untracked.rs)" "??"
equals "subtree: an untracked file at the repo ROOT is left untracked" \
	"$(git_status_of "$MONO" root-untracked.rs)" "??"
equals "subtree: a staged DELETION outside the subtree is left staged" \
	"$(git_status_of "$MONO" mod-b/doomed.rs)" "D "
stderr_has "subtree: the changed count covers ONLY the subtree" \
	"changed-only scope: $GIT_SEEDED_CHANGE_COUNT changed file(s)"
stderr_has "subtree: the resolved geometry names the subtree" "the project is the subtree 'mod-a/'"

# ===========================================================================
section "a filename git reads as a PATHSPEC PATTERN still round-trips"
# ===========================================================================
# A git pathspec is a WILDMATCH pattern by default, so `[`, `]`, `?`, `*` and a
# leading `:` in an ORDINARY filename are INTERPRETED rather than matched. Two
# concrete pre-fix failures, both reproduced against git 2.50 before this section
# was written (see lib/gitfixture.sh's git_seed_glob_metachar_names for the exact
# commands): `:leading-colon.txt` is rejected outright as pathspec MAGIC, and
# `app/[slug]/page.tsx` stages the unrelated `app/s/page.tsx` alongside itself.
# Either one corrupts the stage/restore cycle of somebody's real repository.
GLOB_REPO="$WORK/projects/globrepo"
git_init_repo "$GLOB_REPO"
git_seed_glob_metachar_names "$GLOB_REPO"
GLOB_BEFORE=$(git_status_snapshot "$GLOB_REPO")
GLOB_TOPLEVEL=$(git_fix "$GLOB_REPO" rev-parse --show-toplevel)

inspect "$GLOB_REPO" glob
expect_rc "glob names: the run succeeds" 0
equals "glob names: git status is byte-identical before and after" \
	"$(git_status_snapshot "$GLOB_REPO")" "$GLOB_BEFORE"
equals "glob names: a bracketed dynamic-route path is staged again" \
	"$(git_status_of "$GLOB_REPO" 'app/[slug]/page.tsx')" "A "
equals "glob names: and the file its bracket expression would have matched is NOT" \
	"$(git_status_of "$GLOB_REPO" app/s/page.tsx)" "??"
equals "glob names: a path with \`?\` and \`*\` is staged again" \
	"$(git_status_of "$GLOB_REPO" 'weird?name*.ts')" "A "
equals "glob names: and the file its wildcards would have matched is NOT" \
	"$(git_status_of "$GLOB_REPO" weirdXnameY.ts)" "??"
equals "glob names: a LEADING-COLON path — pathspec magic, not a name — is staged again" \
	"$(git_status_of "$GLOB_REPO" ':leading-colon.txt')" "A "
stderr_not_has "glob names: nothing was reported as un-restorable" "could not re-stage"
stderr_not_has "glob names: and the restore was not partial" "only partially restored"
equals "glob names: the pathspec is passed literally on the stage-all call" \
	"$(git_recorded_call add "$GIT_STUB_ARGV_LOG")" \
	"-C $GLOB_TOPLEVEL $GIT_HARDENED_OPTS add -A -- ."

# --- the SUBTREE PREFIX itself is a pattern ---------------------------------
# The four call sites carry two DIFFERENT pathspecs: a per-PATH one (covered
# above) and the PROJECT PREFIX, which is the only pathspec `status` and
# `diff --cached` ever see. So a module directory whose name git reads as a
# pattern is the only way to reach those two.
#
# THE LEADING COLON IS WHAT MAKES THEM REACHABLE, and the brackets alone are not —
# established by mutation, not by reasoning. Verified against git 2.50: a bracket
# expression in a pathspec still matches its own literal spelling (which is also
# why `app/[slug]/page.tsx` above stages the decoy IN ADDITION to itself rather
# than instead of it), so dropping --literal-pathspecs from `status` left a
# `mod-[a]/` prefix working and this section green. A LEADING `:` is pathspec
# MAGIC rather than a character, and git rejects it outright — which is what turns
# a dropped flag here into the failure this section is really about: `status`
# failing means an EMPTY changed-file list, and an empty list means a module with
# pending changes is reported as having none. A FALSE CLEAN.
GLOB_MONO="$WORK/projects/globmono"
git_init_repo "$GLOB_MONO"
git_seed_mixed_changes "$GLOB_MONO" ':mod-[a]/'
GLOB_MONO_BEFORE=$(git_status_snapshot "$GLOB_MONO")
GLOB_MONO_TOPLEVEL=$(git_fix "$GLOB_MONO" rev-parse --show-toplevel)

inspect "$GLOB_MONO/:mod-[a]" glob-subtree
expect_rc "glob subtree: the run succeeds" 0
stderr_has "glob subtree: the module's changes are COUNTED, not silently reduced to zero" \
	"changed-only scope: $GIT_SEEDED_CHANGE_COUNT changed file(s)"
stderr_has "glob subtree: and the resolved geometry names the pattern-shaped subtree" \
	"the project is the subtree ':mod-[a]/'"
equals "glob subtree: the whole repository's status is byte-identical" \
	"$(git_status_snapshot "$GLOB_MONO")" "$GLOB_MONO_BEFORE"
equals "glob subtree: the staged path inside it is staged again" \
	"$(git_status_of "$GLOB_MONO" ':mod-[a]/staged.rs')" "A "
equals "glob subtree: the staged snapshot survived, so the staged deletion is one again" \
	"$(git_status_of "$GLOB_MONO" ':mod-[a]/doomed.rs')" "D "
equals "glob subtree: the stage-all pathspec is that prefix, passed literally" \
	"$(git_recorded_call add "$GIT_STUB_ARGV_LOG")" \
	"-C $GLOB_MONO_TOPLEVEL $GIT_HARDENED_OPTS add -A -- :mod-[a]/"

# ===========================================================================
section "a failed NUL decode is a named error, never an empty result"
# ===========================================================================
# Both of lib/gitscope.sh's `tr '\0' '\n'` calls turn a failure into an EMPTY
# file, and an empty file is indistinguishable from the two most dangerous
# possible answers: "the work tree is clean" and "nothing was staged". The first
# would inspect nothing and report success; the second would make the restore
# DISCARD the caller's real staging area instead of rebuilding it. See
# lib/stubs.sh's init_tr_stub for why the failure is injected rather than induced.
TR_REPO="$WORK/projects/trrepo"
git_init_repo "$TR_REPO"
git_seed_mixed_changes "$TR_REPO" ""
TR_BEFORE=$(git_status_snapshot "$TR_REPO")

inspect "$TR_REPO" tr-status --tr-fail 1
expect_rc "tr failure (changed-file list): the run fails rather than inspecting nothing" 1
stderr_has "tr failure (changed-file list): the decode is named as the fault" \
	"could not decode git's NUL-separated status output"
stderr_not_has "tr failure (changed-file list): and it is NOT reported as a clean tree" \
	"changed-only scope: 0 changed file(s)"
equals "tr failure (changed-file list): no \`git add\` was issued at all" \
	"$(git_recorded_call add "$GIT_STUB_ARGV_LOG")" ""
equals "tr failure (changed-file list): so the index is untouched" \
	"$(git_status_snapshot "$TR_REPO")" "$TR_BEFORE"

inspect "$TR_REPO" tr-snapshot --tr-fail 2
expect_rc "tr failure (staged snapshot): the run fails" 1
stderr_has "tr failure (staged snapshot): the decode is named, and so is the refusal" \
	"could not decode git's NUL-separated list of staged paths — refusing to stage anything"
equals "tr failure (staged snapshot): \`git add -A\` NEVER ran, so the real index was never touched" \
	"$(git_recorded_call add "$GIT_STUB_ARGV_LOG")" ""
equals "tr failure (staged snapshot): and the index is byte-for-byte as it was" \
	"$(git_status_snapshot "$TR_REPO")" "$TR_BEFORE"

# ===========================================================================
section "an INHERITED git environment cannot redirect the run at another repo"
# ===========================================================================
# $GIT_DIR, $GIT_WORK_TREE, $GIT_INDEX_FILE and $GIT_OBJECT_DIRECTORY OVERRIDE
# `git -C <dir>`'s repository discovery, and they are commonly already set in the
# contexts this script is plausibly invoked from: a git hook, `git rebase --exec`,
# `git bisect run`. Pre-fix, a run started from one of those staged and restored
# the WRONG repository's index.
TARGET_REPO="$WORK/projects/targetrepo"
git_init_repo "$TARGET_REPO"
git_seed_mixed_changes "$TARGET_REPO" ""
TARGET_BEFORE=$(git_status_snapshot "$TARGET_REPO")
TARGET_TOPLEVEL=$(git_fix "$TARGET_REPO" rev-parse --show-toplevel)

# The decoy carries a DIFFERENT number of changes on purpose. With the same count
# in both, "the target's changes are the ones counted" passes whichever repository
# was resolved — established by mutation: with matching fixtures, removing the
# `unset` left that assertion green.
DECOY_REPO="$WORK/projects/decoyrepo"
git_init_repo "$DECOY_REPO"
printf 'decoy\n' >"$DECOY_REPO/decoy-only.rs"
DECOY_BEFORE=$(git_status_snapshot "$DECOY_REPO")

inspect "$TARGET_REPO" inherited-gitdir \
	--env "GIT_DIR=$DECOY_REPO/.git" --env "GIT_WORK_TREE=$DECOY_REPO"
expect_rc "inherited \$GIT_DIR: the run succeeds against the project it was given" 0
equals "inherited \$GIT_DIR: the staged pathspec is resolved at the TARGET's root, not the decoy's" \
	"$(git_recorded_call add "$GIT_STUB_ARGV_LOG")" \
	"-C $TARGET_TOPLEVEL $GIT_HARDENED_OPTS add -A -- ."
stderr_has "inherited \$GIT_DIR: and the TARGET's changes are the ones counted" \
	"changed-only scope: $GIT_SEEDED_CHANGE_COUNT changed file(s)"
equals "inherited \$GIT_DIR: the target's index is staged and restored" \
	"$(git_status_snapshot "$TARGET_REPO")" "$TARGET_BEFORE"
# A status comparison cannot carry this claim on its own: a repository that was
# staged and then perfectly restored looks identical to one never touched (the same
# reason this suite's header gives for asserting the recorded argv separately). So
# the claim is that the decoy's path never appeared in ANY git invocation.
equals "inherited \$GIT_DIR: not one git call in the whole run names the decoy" \
	"$(grep -Fc -- "$DECOY_REPO" "$GIT_STUB_ARGV_LOG" || true)" "0"
equals "inherited \$GIT_DIR: and its working tree is untouched" \
	"$(git_status_snapshot "$DECOY_REPO")" "$DECOY_BEFORE"

DECOY_INDEX="$WORK/decoy-index"
DECOY_OBJECTS="$WORK/decoy-objects"
inspect "$TARGET_REPO" inherited-gitindex \
	--env "GIT_INDEX_FILE=$DECOY_INDEX" --env "GIT_OBJECT_DIRECTORY=$DECOY_OBJECTS"
expect_rc "inherited \$GIT_INDEX_FILE: the run succeeds" 0
path_absent "inherited \$GIT_INDEX_FILE: the alternate index file is never written" "$DECOY_INDEX"
path_absent "inherited \$GIT_OBJECT_DIRECTORY: nor does any blob land in the alternate object store" \
	"$DECOY_OBJECTS"
equals "inherited \$GIT_INDEX_FILE: the project's OWN index is the one staged and restored" \
	"$(git_status_snapshot "$TARGET_REPO")" "$TARGET_BEFORE"
equals "inherited \$GIT_INDEX_FILE: with the staged path really re-staged there" \
	"$(git_status_of "$TARGET_REPO" staged.rs)" "A "

# ===========================================================================
section "a repository's OWN config cannot attach code to this tool's git calls"
# ===========================================================================
# `core.fsmonitor` names a command git runs to enumerate changes and
# `core.hooksPath` relocates the hook directory `post-index-change` runs from, and
# BOTH live in `.git/config` — untracked content nobody reviews by reading the
# code, which can arrive with a downloaded tarball or as a vendored foreign
# checkout. `status`, `add -A` and `reset` all refresh the index, so a tool that
# presents itself as "just running a code inspector" would hand that config
# arbitrary code execution as the invoking user. lib/gitscope.sh's git_hardened
# pins both to inert values on the command line, where they beat the repository's.
#
# ARGV PRESENCE IS ASSERTED ABOVE (via $GIT_HARDENED_OPTS) AND IS NOT ENOUGH. That
# assertion says the two options were passed; it cannot say they WORK — a typo'd
# key, a value git ignores, or a git version that resolves the config differently
# would all still match the recorded argv. This section asserts the EFFECT, against
# a real repository whose own config really does execute code.
#
# THE NEGATIVE CONTROL IS THE POINT OF THE SECTION. "No marker file was created" is
# exactly the assertion an INERT fixture also passes, so the fixture is shown
# FIRING first, under a plain unhardened git, before the same fixture is handed to
# the tool. Without that first half this whole section would be untestable
# reassurance.
HOSTILE_REPO="$WORK/projects/hostilerepo"
HOSTILE_HOOKS="$WORK/hostile-hooks"
HOSTILE_MARKERS="$WORK/hostile-markers"
git_init_repo "$HOSTILE_REPO"
git_seed_mixed_changes "$HOSTILE_REPO" ""
# Snapshotted BEFORE the config is planted, because git_status_snapshot runs an
# UNHARDENED git and would otherwise fire the very hooks this section is about.
HOSTILE_BEFORE=$(git_status_snapshot "$HOSTILE_REPO")
git_plant_hostile_exec_config "$HOSTILE_REPO" "$HOSTILE_HOOKS" "$HOSTILE_MARKERS"

# --- the positive control: the fixture really is a working exploit -----------
rm -f "$HOSTILE_MARKERS/hook-fired" "$HOSTILE_MARKERS/fsmonitor-fired"
git_run_unhardened "$HOSTILE_REPO" status --porcelain -z --no-renames --untracked-files=all >/dev/null
path_exists "hostile config: a plain \`git status\` DOES run the planted post-index-change hook" \
	"$HOSTILE_MARKERS/hook-fired"
path_exists "hostile config: and DOES execute the planted core.fsmonitor command" \
	"$HOSTILE_MARKERS/fsmonitor-fired"

# --- the tool, against that same repository ---------------------------------
rm -f "$HOSTILE_MARKERS/hook-fired" "$HOSTILE_MARKERS/fsmonitor-fired"
inspect "$HOSTILE_REPO" hostile-exec
expect_rc "hostile config: the run succeeds — the hardening is invisible to a normal repository" 0
path_absent "hostile config: yet the hook never fired once in the whole run" \
	"$HOSTILE_MARKERS/hook-fired"
path_absent "hostile config: nor was the fsmonitor command ever executed" \
	"$HOSTILE_MARKERS/fsmonitor-fired"
equals "hostile config: neither exec point fired, stated as one verdict" \
	"$(git_hostile_markers_present "$HOSTILE_MARKERS")" "silent"
stderr_has "hostile config: and the run still did the work — every seeded change is counted" \
	"changed-only scope: $GIT_SEEDED_CHANGE_COUNT changed file(s)"
# LAST in this section, deliberately: it runs an unhardened git and therefore
# re-creates the markers the assertions above are about.
equals "hostile config: with the index staged and restored as usual" \
	"$(git_status_snapshot "$HOSTILE_REPO")" "$HOSTILE_BEFORE"

# ===========================================================================
section "the restore runs on every exit path, not just the happy one"
# ===========================================================================
FAIL_REPO="$WORK/projects/failrepo"
git_init_repo "$FAIL_REPO"
git_seed_mixed_changes "$FAIL_REPO" ""
FAIL_BEFORE=$(git_status_snapshot "$FAIL_REPO")

# --- the CLI fails and writes no report at all ------------------------------
inspect "$FAIL_REPO" fail-noreport --edir '' --exit 9
expect_rc "clean failure: a report-less non-zero CLI exit fails the run" 1
stderr_has "clean failure: the missing report directory is named" "wrote no report directory"
equals "clean failure: the index is still restored" \
	"$(git_status_snapshot "$FAIL_REPO")" "$FAIL_BEFORE"

# --- the CLI fails but DID write a report -----------------------------------
inspect "$FAIL_REPO" fail-withreport --exit 3
expect_rc "noisy success: a written report is parsed despite a non-zero exit" 0
stderr_has "noisy success: the non-zero exit is disclosed, not swallowed" \
	"the IntelliJ CLI exited 3 but did write"
equals "noisy success: the index is still restored" \
	"$(git_status_snapshot "$FAIL_REPO")" "$FAIL_BEFORE"
path_absent "noisy success: the report directory is removed" "$FAIL_REPO/-e"

# --- interrupted mid-run ----------------------------------------------------
inspect "$FAIL_REPO" fail-sigint --signal INT
expect_rc "SIGINT: the run exits 128+2 rather than reporting success" 130
stderr_has "SIGINT: the interruption is announced" "interrupted by SIGINT"
equals "SIGINT: the index is still restored" \
	"$(git_status_snapshot "$FAIL_REPO")" "$FAIL_BEFORE"
path_absent "SIGINT: the report directory is not left in the repository" "$FAIL_REPO/-e"

inspect "$FAIL_REPO" fail-sigterm --signal TERM
expect_rc "SIGTERM: the run exits 128+15" 143
equals "SIGTERM: the index is still restored" \
	"$(git_status_snapshot "$FAIL_REPO")" "$FAIL_BEFORE"

# ===========================================================================
section "a FAILED restore is reported, never silently accepted"
# ===========================================================================
# lib/gitscope.sh promises a restore failure exits non-zero even on an otherwise
# successful run, because a caller whose staging area was left rearranged has to be
# told. The real causes (a refusing hook, a full disk, a stale index.lock) are not
# inducible from a test, so the recorder injects the failure — see
# lib/stubs.sh's init_git_recorder.
inspect "$FAIL_REPO" restore-reset-fails --git-fail reset
expect_rc "failed unstage: the run exits non-zero although the inspection worked" 1
stderr_has "failed unstage: the caller is told the index may still be staged" \
	"the index may still hold this script's \`git add\`"
equals "failed unstage: and the index really was left rearranged" \
	"$(git_status_of "$FAIL_REPO" untracked.rs)" "A "

# Put the fixture back by hand — the run under test deliberately did not.
# `rm --cached` for doomed.rs, not `rm`: the worktree copy is already gone, so only
# the index entry the `reset` above put back has to be removed again.
git_fix "$FAIL_REPO" reset -q -- .
git_fix "$FAIL_REPO" add -- staged.rs 'staged with space.rs'
git_fix "$FAIL_REPO" rm -q --cached -- doomed.rs
equals "failed unstage: fixture restored for the next test" \
	"$(git_status_snapshot "$FAIL_REPO")" "$FAIL_BEFORE"

inspect "$FAIL_REPO" restore-restage-fails --git-fail 'add staged.rs'
expect_rc "failed re-stage: the run exits non-zero" 1
stderr_has "failed re-stage: the un-restorable path is named" "could not re-stage: staged.rs"
stderr_has "failed re-stage: the partial restore is called out" "only partially restored"

git_fix "$FAIL_REPO" add -- staged.rs
equals "failed re-stage: fixture restored for the next test" \
	"$(git_status_snapshot "$FAIL_REPO")" "$FAIL_BEFORE"

# ===========================================================================
section "--scope all never touches git at all"
# ===========================================================================
inspect "$MONO/mod-a" scope-all --scope all
expect_rc "scope all: the run succeeds" 0
equals "scope all: NOT ONE git command was invoked" \
	"$(grep -c GIT_CALL_BEGIN "$GIT_STUB_ARGV_LOG" || true)" "0"
equals "scope all: the whole repository's status is untouched" \
	"$(git_status_snapshot "$MONO")" "$MONO_BEFORE"
log_not_has_token "scope all: the inspection is invoked WITHOUT -changes" \
	"$IDEA_STUB_ARGV_LOG" "-changes"
stderr_not_has "scope all: no changed-file count is reported" "changed-only scope:"

# ===========================================================================
section "nothing to stage is not the same as staging nothing"
# ===========================================================================
# stage_all_changes is gated on the changed-file count, so a clean tree must reach
# the inspection with `-changes` and yet never see an `add`.
CLEAN_REPO="$WORK/projects/cleanrepo"
git_init_repo "$CLEAN_REPO"
inspect "$CLEAN_REPO" clean
expect_rc "clean tree: the run succeeds" 0
stderr_has "clean tree: zero changed files are reported" "changed-only scope: 0 changed file(s)"
log_has_token "clean tree: -changes is still passed to the inspection" \
	"$IDEA_STUB_ARGV_LOG" "-changes"
equals "clean tree: no \`git add\` is issued when there is nothing to stage" \
	"$(git_recorded_call add "$GIT_STUB_ARGV_LOG")" ""
equals "clean tree: and therefore no \`git reset\` either" \
	"$(git_recorded_call reset "$GIT_STUB_ARGV_LOG")" ""

# ===========================================================================
section "KNOWN, ACCEPTED LIMITATIONS of the restore"
# ===========================================================================
# lib/gitscope.sh documents the restore as best-effort: it unstages everything and
# re-stages the paths that WERE staged, which cannot reconstruct an index entry
# that differed from both HEAD and the worktree. These tests pin the ACTUAL,
# accepted outcome. They are deliberately not written as the ideal — a real
# limitation asserted as if it were a bug would fail forever and teach the reader
# to ignore this file.

# --- partial (`git add -p`-shaped) staging IS observably lost ---------------
PARTIAL="$WORK/projects/partial"
git_init_repo "$PARTIAL"
printf 'v1\n' >"$PARTIAL/f.rs"
git_fix "$PARTIAL" add -A
git_fix "$PARTIAL" commit -q -m v1
printf 'v2\n' >"$PARTIAL/f.rs"
git_fix "$PARTIAL" add -- f.rs
printf 'v3\n' >"$PARTIAL/f.rs"

equals "partial staging: the index starts out differing from BOTH HEAD and the worktree" \
	"$(git_status_of "$PARTIAL" f.rs)" "MM"
inspect "$PARTIAL" partial
expect_rc "partial staging: the run still succeeds" 0
equals "partial staging: ACCEPTED — the intermediate index state is not reconstructed" \
	"$(git_status_of "$PARTIAL" f.rs)" "M "
equals "partial staging: ACCEPTED — the index now holds the worktree content instead" \
	"$(git_fix "$PARTIAL" show :f.rs)" "v3"

# --- a rename, by contrast, comes back looking identical --------------------
# Not because the restore reconstructs one: git's index never stores a rename at
# all, it is DETECTED at diff time from content similarity. Re-staging the delete
# and the add separately therefore lets `git status` re-derive the same rename. The
# limitation note is about what the index holds, and this is what the user
# observes — so this is the behaviour to pin.
RENAMED="$WORK/projects/renamed"
git_init_repo "$RENAMED"
printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' >"$RENAMED/old.rs"
git_fix "$RENAMED" add -A
git_fix "$RENAMED" commit -q -m old
git_fix "$RENAMED" mv old.rs new.rs
RENAMED_BEFORE=$(git_status_snapshot "$RENAMED")
equals "rename: the fixture really does present a staged rename" \
	"$RENAMED_BEFORE" "R  old.rs -> new.rs"

inspect "$RENAMED" renamed
expect_rc "rename: the run succeeds" 0
equals "rename: ACCEPTED — git re-detects the rename, so status is unchanged" \
	"$(git_status_snapshot "$RENAMED")" "$RENAMED_BEFORE"

# ===========================================================================
section "changed-only preconditions fail closed, before anything is mutated"
# ===========================================================================
NOT_A_REPO=$(new_project notarepo src/main.rs)
inspect "$NOT_A_REPO" notarepo
expect_rc "no work tree: exit 1" 1
stderr_has "no work tree: the reason is named" "needs a git work tree, and this is not one"
stderr_has "no work tree: the remedy is named" "re-run with --scope all"

UNBORN="$WORK/projects/unborn"
mkdir -p "$UNBORN"
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$UNBORN" init -q -b main
printf 'x\n' >"$UNBORN/a.rs"
inspect "$UNBORN" unborn
expect_rc "unborn HEAD: exit 1" 1
stderr_has "unborn HEAD: the reason is named" "needs at least one commit to diff against"
equals "unborn HEAD: nothing was staged" "$(git_status_snapshot "$UNBORN")" "?? a.rs"

inspect "$ROOT_REPO" nogit --selector nogit
expect_rc "git absent from PATH: exit 1" 1
stderr_has "git absent from PATH: the reason is named" \
	"--scope changed-only needs git, which is not on PATH"
equals "git absent from PATH: the repository is untouched" \
	"$(git_status_snapshot "$ROOT_REPO")" "$ROOT_BEFORE"

summarize
