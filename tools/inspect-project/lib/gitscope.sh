# shellcheck shell=sh
#
# gitscope.sh — everything `--scope changed-only` needs from git: the repo/HEAD
#               preconditions, the changed-file list BOTH engines filter
#               against, and the stage-all/restore dance the IntelliJ CLI's
#               `-changes` mode requires.
#
# WHY THE CHANGED-FILE LIST IS COMPUTED ONCE, UP FRONT. Both engines need it and
# neither can derive it later: the IntelliJ path STAGES everything (destroying
# the staged/unstaged distinction it was read from), and the Sonar path runs
# after that. Computing it before any mutation is what makes the two engines
# agree on what "changed" meant for a single run.
#
# THREE DIFFERENT PATH BASES, AND KEEPING THEM APART IS THE POINT.
# `--project` may be a SUBDIRECTORY of the repository (one module of a monorepo
# is an ordinary thing to inspect), and in that case three bases are in play at
# once:
#   * `git status --porcelain` reports paths relative to the REPOSITORY ROOT, no
#     matter which directory git ran in.
#   * both engines report paths relative to the PROJECT, so that is the base the
#     emitted changed-file list must use — Sonar's changed-only filter is a
#     literal path comparison against it, and a base mismatch there filters every
#     issue away and reports a FALSE CLEAN result.
#   * an `add`/`reset` PATHSPEC resolves against git's own cwd, so a root-relative
#     path handed to `git -C <subdir> add` names a path that does not exist.
# Every git call below therefore runs at the resolved repository root, scoped to
# the project's subtree by pathspec, and the root-relative paths it returns are
# rebased onto the project before anything else sees them.
#
# EVERY PATHSPEC IS PASSED LITERALLY, AND THAT IS A CORRECTNESS REQUIREMENT.
# A git pathspec is a WILDMATCH pattern by default, so `*`, `?`, `[`, `]` and a
# leading `:` in an ORDINARY filename are interpreted rather than matched: an
# existing `app/[slug]/page.tsx` (a real Next.js/Nuxt dynamic-route name) handed
# back to `git add -A -- <path>` matches nothing — silently leaving a path the
# caller had staged unstaged — or matches a DIFFERENT path the bracket expression
# happens to cover. `--literal-pathspecs` is therefore passed to every git call
# below (via git_hardened), whether it carries a pathspec or not — one wrapper no
# call site can forget beats a per-site judgment about which ones need it.
#
# It is passed per-invocation rather than exported once as $GIT_LITERAL_PATHSPECS
# because this script also execs the IntelliJ CLI and sonar-scanner, which run
# git themselves: an exported flag would silently change THEIR pathspec
# semantics, and nothing here knows whether they rely on magic pathspecs.
#
# KNOWN, ACCEPTED LIMITATION (documented, not a bug to chase): index restoration
# is best-effort. It unstages everything and re-stages the paths that were staged
# before, which does NOT reconstruct rename detection, partial (`git add -p`)
# hunk staging, or an index entry that differed from both HEAD and the worktree.
# A path whose name contains a newline is likewise out of scope — every list here
# is line-oriented.
#
# EVERY GIT CALL HERE RUNS THROUGH git_hardened, WHICH DISABLES TWO OF GIT'S
# CONFIG-DRIVEN EXEC POINTS. See its own comment for what and why; the trust
# assumption that remains after it is stated in inspect-project.sh's header and
# disclosed to the user by lib/menu.sh's menu_confirm_git_staging.
#
# Sourced by inspect-project.sh — never executed directly.

# git_hardened DIR ARGS... — run `git ARGS...` in DIR with this unit's fixed set
# of options. The ONE way this unit invokes git, so no future call site can
# accidentally omit part of the set.
#
# WHY THESE OPTIONS. `--porcelain`, `add -A` and `reset` all refresh the index,
# and a repository's own CONFIG can attach code to that: `core.fsmonitor` names a
# command git runs to enumerate changes, and `core.hooksPath` relocates the hook
# directory, from which `post-index-change` runs on an index write. Both live in
# the repository's `.git/config`, which is not part of its tracked content and is
# therefore not reviewed by anyone reading the code — so a project whose `.git`
# arrived from somewhere untrusted (a tarball or zip that shipped one, a nested or
# vendored foreign checkout) would get arbitrary code execution as the invoking
# user out of a tool that presents itself as "just running a code inspector".
# Pinning both to inert values on the command line beats the repository's config,
# and costs nothing on a normal repository.
#
# `--literal-pathspecs` is here for a correctness reason, not a security one, and
# is passed per-invocation rather than exported — see the pathspec note above.
git_hardened() {
	gh_dir=$1
	shift
	git -C "$gh_dir" \
		-c core.fsmonitor= \
		-c core.hooksPath=/dev/null \
		--literal-pathspecs \
		"$@"
}

# git_is_work_tree PROJECT -> 0 iff PROJECT is inside a git work tree.
git_is_work_tree() {
	git_hardened "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# git_has_head PROJECT -> 0 iff PROJECT has a resolvable HEAD (i.e. at least one
# commit). An unborn HEAD is refused for `changed-only` rather than special-cased:
# with no commit to diff against, "changed" has no meaning for either engine, and
# the unstage half of the restore has no HEAD to reset to.
git_has_head() {
	git_hardened "$1" rev-parse --verify -q HEAD >/dev/null 2>&1
}

# require_changed_scope_preconditions PROJECT — fail closed, with the remedy
# named, before anything is mutated.
#
# THE INHERITED GIT ENVIRONMENT IS DROPPED FIRST, before any git call in this
# unit runs. $GIT_DIR, $GIT_WORK_TREE, $GIT_INDEX_FILE and $GIT_OBJECT_DIRECTORY
# OVERRIDE `git -C <dir>`'s repository discovery, so with them set every check
# and mutation below could resolve a DIFFERENT repository than the one holding
# --project — including staging and restoring the wrong index. They are commonly
# set in exactly the contexts this script is plausibly invoked from: a git hook,
# `git rebase --exec`, `git bisect run`.
require_changed_scope_preconditions() {
	unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY

	rcsp_project=$1
	if ! command -v git >/dev/null 2>&1; then
		error "--scope changed-only needs git, which is not on PATH"
		return 1
	fi
	if ! git_is_work_tree "$rcsp_project"; then
		error "--scope changed-only needs a git work tree, and this is not one: $rcsp_project"
		warn  "re-run with --scope all"
		return 1
	fi
	if ! git_has_head "$rcsp_project"; then
		error "--scope changed-only needs at least one commit to diff against, and $rcsp_project has none yet"
		warn  "re-run with --scope all"
		return 1
	fi
	resolve_git_geometry "$rcsp_project" || return 1
}

# resolve_git_geometry PROJECT — sets GIT_REPO_ROOT, GIT_PROJECT_PREFIX and
# GIT_PROJECT_PATHSPEC. See the three-path-bases note at the top of this file for
# why all three are needed and what breaks when they are conflated.
#
# GIT_PROJECT_PREFIX is git's own `--show-prefix`: the project's path relative to
# the repository root, empty when they are the same directory and otherwise
# carrying a trailing slash, which is what makes it a plain prefix to strip.
# GIT_PROJECT_PATHSPEC is that prefix as something `add`/`reset`/`status` accept,
# with `.` standing in for the empty case.
resolve_git_geometry() {
	rgg_project=$1
	if ! rgg_root=$(git_hardened "$rgg_project" rev-parse --show-toplevel 2>/dev/null) ||
		[ -z "$rgg_root" ]
	then
		error "could not resolve the git repository root for $rgg_project"
		return 1
	fi
	# An empty prefix is the legitimate answer for a project AT the root, so the
	# command's own exit status is what is checked, never the emptiness.
	if ! rgg_prefix=$(git_hardened "$rgg_project" rev-parse --show-prefix 2>/dev/null); then
		error "could not resolve $rgg_project's path within the git repository at $rgg_root"
		return 1
	fi
	GIT_REPO_ROOT=$rgg_root
	GIT_PROJECT_PREFIX=$rgg_prefix
	GIT_PROJECT_PATHSPEC=${rgg_prefix:-.}
	if [ -n "$rgg_prefix" ]; then
		note "git: repository root is $GIT_REPO_ROOT; the project is the subtree '$GIT_PROJECT_PREFIX'"
	fi
}

# collect_changed_files OUTFILE — write one PROJECT-relative path per line for
# every staged, unstaged or untracked change inside the project subtree.
#
# Runs at the repository root and scopes to GIT_PROJECT_PATHSPEC, so a change
# elsewhere in a monorepo is never counted as this project's; the root-relative
# paths that come back are then rebased onto the project by stripping
# GIT_PROJECT_PREFIX. Both are no-ops when the project IS the repository root.
#
# THREE FLAGS, ALL LOAD-BEARING, none cosmetic:
#   -z                    without it, porcelain C-QUOTES any path needing it —
#                         verified, and it includes a plain SPACE, so `my file.c`
#                         arrives as `"my file.c"` and matches nothing Sonar or
#                         the filesystem reports. `-z` never quotes.
#   --no-renames          `-z` reports a rename as TWO NUL fields in one record
#                         (new, then old), which a field-per-line reader cannot
#                         tell apart from two separate entries. Disabling rename
#                         detection turns each into a plain delete + add, so
#                         every record is exactly one field.
#   --untracked-files=all the default collapses an untracked directory to a
#                         single `dir/` entry, which would never match the
#                         per-file paths Sonar reports — silently dropping every
#                         new file in a new directory from a changed-only result.
#
# NUL is then translated to newline, which is what makes the result a line-
# oriented file the rest of this script can read. A path containing a literal
# newline is therefore out of scope, consistent with the limitation note at the
# top of this file.
#
# git's output is captured to a file and its status checked BEFORE parsing,
# rather than piped into the read loop: a failing `git` in the left half of a
# pipeline is invisible to `set -e`, and reading from a file also keeps the loop
# out of a subshell.
collect_changed_files() {
	ccf_out=$1
	ccf_raw="$WORKDIR/git-status.z"
	ccf_lines="$WORKDIR/git-status.lines"

	if ! git_hardened "$GIT_REPO_ROOT" \
		status --porcelain -z --no-renames --untracked-files=all \
		-- "$GIT_PROJECT_PATHSPEC" >"$ccf_raw" 2>/dev/null
	then
		error "could not read git status in $GIT_REPO_ROOT"
		return 1
	fi
	# Checked, not assumed: `set -e` is suspended in this function (every caller
	# invokes it as `f || …`), and a failed `tr` would leave an EMPTY file that is
	# indistinguishable from a genuinely clean work tree — a false "0 changed
	# files" run that inspects nothing and reports success.
	if ! tr '\0' '\n' <"$ccf_raw" >"$ccf_lines"; then
		error "could not decode git's NUL-separated status output"
		return 1
	fi

	: >"$ccf_out"
	while IFS= read -r ccf_field; do
		[ -n "$ccf_field" ] || continue
		# Porcelain v1: two status columns, a space, then the path.
		ccf_path=${ccf_field#???}
		[ -n "$ccf_path" ] || continue
		ccf_path=$(strip_prefix "$ccf_path" "$GIT_PROJECT_PREFIX") || continue
		printf '%s\n' "$ccf_path" >>"$ccf_out"
	done <"$ccf_lines"
}

# count_changed_files -> how many paths the current run considers changed.
count_changed_files() {
	if [ -z "$CHANGED_FILES_FILE" ] || [ ! -f "$CHANGED_FILES_FILE" ]; then
		printf '0'
		return 0
	fi
	ccf_count=$(wc -l <"$CHANGED_FILES_FILE" | tr -d ' ')
	printf '%s' "${ccf_count:-0}"
}

# stage_all_changes — snapshot which of the project's paths were staged, then
# stage the project's subtree.
#
# SCOPED TO THE PROJECT SUBTREE, not the whole repository. `git add -A` from a
# subdirectory stages the ENTIRE work tree, so inspecting one module of a monorepo
# would rearrange the index for every unrelated module in it. The pathspec keeps
# the mutation — and therefore the restore — no wider than what the inspection
# actually needs to see.
#
# GIT_STAGE_APPLIED is set BEFORE the add, deliberately: a partially-applied
# `git add` (interrupt, disk full, a hook refusing one path) still needs
# restoring, so arming the restore is not allowed to depend on the add having
# succeeded.
stage_all_changes() {
	GIT_STAGE_ROOT=$GIT_REPO_ROOT
	GIT_STAGED_SNAPSHOT="$WORKDIR/staged-before.txt"
	sac_raw="$WORKDIR/staged-before.z"

	# `-z --no-renames` for the same two reasons collect_changed_files documents:
	# unquoted paths, and one field per record. These stay ROOT-relative and are
	# deliberately NOT rebased — they are handed straight back to `git add` at the
	# root, which is the base a pathspec there resolves against.
	if ! git_hardened "$GIT_REPO_ROOT" \
		diff --cached --name-only -z --no-renames HEAD \
		-- "$GIT_PROJECT_PATHSPEC" >"$sac_raw" 2>/dev/null
	then
		error "could not snapshot the staged paths under $GIT_REPO_ROOT/$GIT_PROJECT_PREFIX — refusing to stage anything"
		return 1
	fi
	# Checked BEFORE the `git add`, and a failure aborts the whole staging step:
	# `set -e` is suspended here (the caller invokes this as `f || exit 1`), and a
	# failed `tr` would leave an EMPTY snapshot that restore_git_index's `[ -s ]`
	# test cannot tell apart from "nothing was staged" — so the caller's real
	# staging area would be discarded by the restore instead of rebuilt.
	if ! tr '\0' '\n' <"$sac_raw" >"$GIT_STAGED_SNAPSHOT"; then
		error "could not decode git's NUL-separated list of staged paths — refusing to stage anything"
		return 1
	fi

	GIT_STAGE_APPLIED=1
	if ! git_hardened "$GIT_REPO_ROOT" add -A -- "$GIT_PROJECT_PATHSPEC"; then
		error "\`git add -A -- $GIT_PROJECT_PATHSPEC\` failed in $GIT_REPO_ROOT"
		return 1
	fi
}

# restore_git_index — put the index back, as close to as found as the limitation
# note at the top of this file allows. Called from cleanup() on EVERY exit path,
# so it must be safe to call when nothing was staged (the common case) and safe
# to call twice.
#
# Returns non-zero if ANY part of the restore failed. cleanup() promotes that to
# a non-zero exit even on an otherwise-successful run, because a caller whose
# staging area was left rearranged has to be told.
restore_git_index() {
	[ "$GIT_STAGE_APPLIED" -eq 1 ] || return 0
	GIT_STAGE_APPLIED=0
	rgi_status=0

	# Scoped to the same subtree that was staged, so an index entry elsewhere in a
	# monorepo — which this script never touched — is never unstaged either.
	if ! git_hardened "$GIT_STAGE_ROOT" reset -q -- "$GIT_PROJECT_PATHSPEC"; then
		error "could not unstage '$GIT_PROJECT_PATHSPEC' in $GIT_STAGE_ROOT — the index may still hold this script's \`git add\`"
		return 1
	fi

	if [ -n "$GIT_STAGED_SNAPSHOT" ] && [ -s "$GIT_STAGED_SNAPSHOT" ]; then
		while IFS= read -r rgi_path; do
			[ -n "$rgi_path" ] || continue
			# `add -A -- PATH` rather than `add -- PATH`, so a path that was
			# staged as a DELETION is re-staged as one. `--literal-pathspecs` is
			# what makes an ordinary name like `app/[slug]/page.tsx` re-stageable
			# at all — see the pathspec note at the top of this file.
			if ! git_hardened "$GIT_STAGE_ROOT" add -A -- "$rgi_path" >/dev/null 2>&1; then
				warn "could not re-stage: $rgi_path"
				rgi_status=1
			fi
		done <"$GIT_STAGED_SNAPSHOT"
	fi

	if [ "$rgi_status" -ne 0 ]; then
		error "the git index in $GIT_STAGE_ROOT was only partially restored — check \`git status\` before committing"
	fi
	return "$rgi_status"
}
