#!/usr/bin/env sh
#
# diff-scope.sh — the ONE source of the diff that flow-review reviews and
#                 flow-testing tests. Computes the working tree's change set
#                 against a base and writes it OUTSIDE the repo: the patch, the
#                 list of changed files and of their changed lines, and the
#                 full candidate change set.
#
# WHY one script owns the diff: review and test cover the current effort's
# diff and nothing else. Every writer that records findings or a test plan
# (review-create.sh, review-add-round.sh, test-plan-create.sh,
# test-plan-challenge.sh, test-plan-amend.sh) takes the diff-files.tsv (or
# diff-files.txt) this script writes as a required --diff-files, and refuses
# anything outside it; review-update-status.sh takes it to verify a
# resolution. A diff computed ad hoc per caller could quietly differ from the
# one the writers enforce.
#
# WHY the changed lines too: a finding located outside the diff is in scope
# only through a relates_to on the code the diff changed, and a file the
# diff touches is not enough — the line must be one it changed.
# diff-hunks.tsv lists each selected file's new-side line ranges, which
# review-create.sh and review-add-round.sh take as --diff-hunks. A deleted
# or binary file has no line to point at and is listed whole ("0 0"). Each
# file's ranges come from its own zero-context diff, read off hunk headers
# whose path is known, so no path is ever parsed out of a patch.
#
# WHAT the change set is: every file that differs between the base commit
# and the working tree — committed on the branch since the base, staged, or
# unstaged — plus every untracked, non-ignored file as an addition. The base
# is HEAD by default, so the change set is the uncommitted work only: work
# already committed was reviewed before it was committed. --whole-branch
# takes the merge-base of HEAD with the branch's parent instead, and --base
# the merge-base of HEAD with REF.
#
# WHY the parent is found in this order: the branch's reflog records the ref
# it was created from, exactly as typed, so a ref name or a sha there is the
# parent; a start point relative to a moving ref (HEAD, -, @{-1}, @{u},
# main~2) no longer names the fork point and is skipped. Without one (a
# detached HEAD, or a reflog expired after gc.reflogExpire), the parent is
# taken to be the branch HEAD has the fewest commits beyond. The branch
# itself is never its own parent, so a remote branch of its name is skipped
# (and its upstream only when that is one). A branch that already holds HEAD
# ends this step with no parent: one made from this branch, or a copy of it,
# cannot be told apart from a parent HEAD has not moved past, a detached HEAD
# at a pull request's tip is held by that branch, and any other branch is
# farther than the one HEAD is at, so the default branch is taken instead.
#
# WHY snapshots: two efforts can change the same file, and a path-level
# selection (--paths-file) cannot tell their hunks apart. --snapshot-out
# records the working tree as it is before an effort starts — a git tree
# object of every tracked and untracked, non-ignored file at its
# working-tree content, .crucible/ included — and --since-snapshot then
# diffs that tree against the working tree as it is now, so the change set,
# the selection, the patch and its coverage check hold only what changed
# after the snapshot. Both trees keep .crucible/ whatever
# --include-crucible says, so a .crucible/ change made since the snapshot
# is listed as X (or, with --include-crucible, as an ordinary change), and
# one made before it only as the X listing of the branch's .crucible/
# changes (see the WHY on .crucible/). Both trees are built in a private temporary index
# (GIT_INDEX_FILE), seeded from the repo's index entries without touching it;
# the only write to the repo is the blob and tree objects git stores. A
# snapshot tree is referenced by no ref, so `git gc` may prune it once it is
# older than gc.pruneExpire (two weeks by default). Since a snapshot, an
# untracked file is a plain addition (A, never U), and a nested repository
# is left out as in the default mode.
#
# WHY .crucible/ is left out by default: it holds the framework's own
# artifacts (review artifacts, test plans), which the flows write while they
# run; they are never the effort under review or test. Every changed path
# at or under .crucible/, committed or untracked alike, is kept out of the
# selection and the patch and listed in changes.txt with status X, so the
# orchestrator can show what was left out; an X path is never selectable.
# --include-crucible keeps them as ordinary changes. A review artifact is
# trusted only while changes.txt does not list it, so with every base but
# --whole-branch's (the default, --base and --since-snapshot all start past
# the fork point) every .crucible/ path that differs between the branch's
# fork point from its parent (found as for --whole-branch) and the working
# tree is listed too, as X unless already listed — even with
# --include-crucible — and with no parent found, every tracked .crucible/
# path is: an artifact edited in an earlier commit on the branch is never
# trusted. These X lines alone never make the diff non-empty.
#
# WHY --paths-file: the working tree can hold uncommitted changes from several
# efforts, some already reviewed and tested. changes.txt always lists the full
# change set so the orchestrator can see every change and pick the current
# effort's files; --paths-file then restricts diff.patch and diff-files.txt to
# those files. A listed path outside the change set is refused, never
# silently dropped.
#
# WHAT runs against the repo: git with GIT_OPTIONAL_LOCKS=0 (no
# opportunistic index refresh), no fetch, no external diff or textconv
# program, and no fsmonitor hook; every output goes to --out-dir, which must
# lie outside the repo. Configured clean/process filters (e.g. git-lfs) still
# run: comparing the working tree with the index passes each file whose
# stat changed through them, as any `git diff` does.
#
# WHY some path names fail closed: every list this script writes is one path
# per line, and changes.txt and diff-files.tsv are tab-delimited. A path
# holding a newline would become two paths; one holding a tab would split
# into fields (a diff-files.txt line "src/a<TAB>-" would read as a
# diff-files.tsv line); one ending in a carriage return loses it to any
# reader that strips CRLF; one starting with a double quote reads as git's
# C-quoted form to any reader that unquotes.
#
# WHY the patch is checked after it is written: a pathspec names a directory
# too, so a selected path that was a file at the base and is a directory now
# also pulls in the changed files under it, and a selected rename's old path
# brings in its own change if it changed again. Any file the tracked diff
# covers outside the selection — other than the old path of a selected
# rename, paired as in changes.txt — fails the run.
#
# WHY a changed symlink is listed but never selected: its diff and blob are
# the link text, while every tool that opens the path reads the target, which
# can lie outside the change set or the repo; a review or test of it would
# judge one and act on the other. It is listed in changes.txt with status S,
# kept out of the selection and the patch like an X path, and naming it in
# --paths-file is refused. A deleted path is no longer a link and stays an
# ordinary D change.
#
# Usage: see --help.
#
# Output files (in --out-dir, each replaced atomically):
#   diff.patch      The unified diff of the selected files: tracked changes
#                     against the base, then each untracked file as a new
#                     file.
#   diff-files.txt  The selected files' repo-relative paths, one per line,
#                     sorted and unique. Includes deleted files and the new
#                     path of a renamed file. Accepted as --diff-files by
#                     every writer.
#   diff-files.tsv  The same files in the same order, one line each:
#                     <path><TAB><blob-sha>, the blob-sha as in changes.txt.
#                     The --diff-files every writer takes, so each artifact
#                     records which content it covered.
#   diff-hunks.tsv  The lines the selected files changed, one line per
#                     new-side hunk, sorted by path then line:
#                     <path><TAB><start><TAB><end>; a pure deletion is
#                     anchored at the line before it (at least 1), and a
#                     deleted or binary file is one "0 0" line. The
#                     --diff-hunks the review writers take.
#   changes.txt     The FULL change set, whatever --paths-file selects, one
#                     line per file, sorted by path:
#                       <status><TAB><path><TAB><blob-sha>
#                     status: M modified, A added, D deleted, R renamed (the
#                     new path), U untracked (never since a snapshot,
#                     where an untracked file is A), X excluded (at or under
#                     .crucible/; never selected), S symlink (never
#                     selected). blob-sha: `git hash-object` of the
#                     working-tree content (an X symlink hashes its target
#                     text), or "-" for a deleted path, an S symlink, or a
#                     non-file entry (a submodule). No path holds a tab.
#
# Output (stdout, machine-parseable):
#   DIFF_PATCH=<absolute path>
#   DIFF_FILES=<absolute path>
#   DIFF_FILES_TSV=<absolute path>
#   DIFF_HUNKS=<absolute path>
#   DIFF_CHANGES=<absolute path>
#   DIFF_BASE=<base commit sha, or the snapshot tree sha with --since-snapshot>
#   DIFF_BASE_REF=<what the base was taken from: HEAD, the parent or --base
#                  ref as named, or the snapshot tree sha>
#   DIFF_BASE_FROM=head|reflog|nearest-branch|default|explicit|snapshot
#   DIFF_FILE_COUNT=<number of selected files>
#   DIFF_SCOPE=effort   (--paths-file given) | all
#   With --snapshot-out, only:
#   DIFF_SNAPSHOT=<tree sha>   (the line written to FILE)
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  diff written
#   1  git absent / not a git work tree / HEAD has no commit / no parent
#      branch for --whole-branch / no merge-base with the base /
#      a changed path name that cannot be listed / a selected path that
#      became a symlink during the run / without --paths-file, a patch
#      covering a file outside the selection / --out-dir cannot be created /
#      git or write failure
#   2  usage error (missing/invalid argument; --repo-root not the top level;
#      --out-dir not a directory or inside the repo; --paths-file
#      unreadable, empty, naming a path outside the change set, an excluded
#      (X) path or a symlink (S), or selecting a path whose diff pulls in
#      unselected changed files; --since-snapshot not a tree in the repo;
#      --snapshot-out a directory, in a missing directory, or inside the
#      repo; options that do not combine)
#   3  the diff is empty, or holds only X and S lines: nothing to review or
#      test
#
# Env:
#   None — every path is supplied via an argument. GIT_DIR, GIT_WORK_TREE and
#   GIT_INDEX_FILE are unset so the caller's environment cannot redirect git
#   to another repository, and GIT_LITERAL_PATHSPECS, GIT_GLOB_PATHSPECS,
#   GIT_NOGLOB_PATHSPECS and GIT_ICASE_PATHSPECS so it cannot change how a
#   pathspec matches. GIT_INDEX_FILE is set only inside the snapshot build,
#   to its private index.
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland) and Linux (GNU coreutils). git is the only non-ubiquitous
#   dependency and is guarded with `command -v`; standard tools (awk, cat,
#   cp, cut, mkdir, mktemp, mv, readlink, rm, sed, sort, tr, wc) are
#   assumed present. A --paths-file selection too large for the system's
#   argument limit fails with a git error.
#
# shellcheck disable=SC2310  # every function called as a condition is one git command (repo_git) or checks each of its own steps explicitly, so its status holds whether or not set -e is active inside it
set -eu

LC_ALL=C
export LC_ALL

GIT_OPTIONAL_LOCKS=0
export GIT_OPTIONAL_LOCKS
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS

PROG=${0##*/}

TAB=$(printf '\t')

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout stays machine-clean)
# ---------------------------------------------------------------------------
note()  { printf '%s: note: %s\n'    "$PROG" "$*" >&2; }
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG --repo-root PATH --out-dir PATH
       [--whole-branch | --base REF | --since-snapshot SHA]
       [--paths-file PATH] [--include-crucible] [-h|--help]
       $PROG --repo-root PATH --snapshot-out FILE [--include-crucible]

Compute the diff that flow-review reviews and flow-testing tests: the working
tree (staged, unstaged, and untracked non-ignored files, plus whatever is
committed since the base) against a base, minus .crucible/. Writes
diff.patch, diff-files.txt, diff-files.tsv, diff-hunks.tsv and changes.txt
into --out-dir, which must lie outside the repo. With --snapshot-out, record
the working tree as a snapshot instead.

The base (one of these; the last three exclude each other):
  default            HEAD: the uncommitted work only. Commits already on
                       the branch are left out.
  --whole-branch     The merge-base of HEAD with the branch's parent:
                       everything since the branch left it, committed or
                       not. For a whole-branch or pull/merge-request review.
  --base REF         The merge-base of HEAD with REF.
  --since-snapshot SHA
                     A snapshot tree (full sha): only the changes made
                       after the snapshot.

The parent for --whole-branch is, in order:
  1. the ref the branch's reflog says it was created from, when it is a
     branch, tag or sha that still exists (not HEAD, a relative start point
     such as -, @{-1}, @{u} or main~2, the branch itself or a remote branch
     of its name);
  2. else the local or remote-tracking branch HEAD has the fewest commits
     beyond; a tie goes to a local branch, then main or master, then the
     name. Never the branch itself or a remote branch of its name; and none
     when a branch already holds HEAD (such as one made from it). With a
     detached HEAD this is the first step;
  3. else origin/HEAD's target, else main, else master.
None found is an error (exit 1): pass --base REF.

Options:
  --repo-root PATH   The repository's top-level directory (required).
  --out-dir PATH     Output directory outside the repo (required unless
                       --snapshot-out; created, with any missing parents,
                       when missing).
  --whole-branch     See the base above.
  --base REF         See the base above.
  --since-snapshot SHA
                     See the base above.
  --snapshot-out FILE
                     Record the working tree (tracked and untracked
                       non-ignored files, .crucible/ included) as a git
                       tree built in a private index, write its sha to
                       FILE atomically (outside the repo, in a directory
                       that exists), print DIFF_SNAPSHOT=<sha>.
                       Takes only --repo-root (--include-crucible is
                       accepted and does not change the snapshot).
  --paths-file PATH  The current effort's files: repo-relative paths, one per
                       line, matched exactly, blank lines skipped, each in
                       the change set and not an X or S line. Restricts
                       diff.patch, diff-files.txt/.tsv and diff-hunks.tsv
                       to them; changes.txt stays complete.
  --include-crucible Treat changed paths under .crucible/ (the framework's
                       own artifacts) as ordinary changes instead of X.
  -h, --help         Show this help.

changes.txt lines: <status><TAB><path><TAB><blob-sha>, status M|A|D|R|U|X|S
(U = untracked, never since a snapshot; X = excluded under .crucible/,
S = symlink; X and S are never selectable), blob-sha "-" for a deleted
path, an S symlink, or a non-file entry (a submodule). With every base but
--whole-branch (whose base already is the fork point), X lines also cover
.crucible/ changes since the branch's parent (found as for --whole-branch;
every tracked .crucible/ path when none is found), so a review artifact
edited anywhere on the branch is never trusted.
diff-files.tsv lines: <path><TAB><blob-sha> for the selected files.
diff-hunks.tsv lines: <path><TAB><start><TAB><end>, one per changed line
range of a selected file ("0 0" for a deleted or binary file).

On success, prints:
  DIFF_PATCH=<path>  DIFF_FILES=<path>  DIFF_FILES_TSV=<path>
  DIFF_HUNKS=<path>  DIFF_CHANGES=<path>  DIFF_BASE=<sha>
  DIFF_BASE_REF=<ref>  DIFF_BASE_FROM=<how>  DIFF_FILE_COUNT=<n>
  DIFF_SCOPE=effort|all
(one per line; DIFF_BASE is the snapshot with --since-snapshot), or with
--snapshot-out only DIFF_SNAPSHOT=<sha>. DIFF_BASE_REF is what the base was
taken from: HEAD, the parent or --base ref as named, or the snapshot sha.
DIFF_BASE_FROM is how it was chosen: head (default), reflog, nearest-branch
or default (--whole-branch steps 1-3), explicit (--base), or snapshot.

Exit codes:
  0  diff written
  1  git absent / not a git work tree / HEAD has no commit / no parent
     branch for --whole-branch / no merge-base with the base /
     a changed path name that cannot be listed / a selected path that
     became a symlink during the run / without --paths-file, a patch
     covering a file outside the selection / --out-dir cannot be created /
     git or write failure
  2  usage error (missing/invalid argument; --repo-root not the top level;
     --out-dir not a directory or inside the repo; --paths-file
     unreadable, empty, naming a path outside the change set, an excluded
     (X) path or a symlink (S), or selecting a path whose diff pulls in
     unselected changed files; --since-snapshot not a tree in the repo;
     --snapshot-out a directory, in a missing directory, or inside the
     repo; options that do not combine)
  3  the diff is empty, or holds only X and S lines: nothing to review or
     test
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# git at the repo top level, no fsmonitor hook, pathspecs taken literally (a
# path like ":(glob)*" names that file, never a pattern): every git call once
# the top level is known, except the two all-mode diffs, whose fixed
# whole-tree pathspec needs pathspec magic.
repo_git() {
	git_at_top --literal-pathspecs "$@"
}

# git at the repo top level with no fsmonitor hook; pathspec magic applies.
git_at_top() {
	git -C "$TOP" -c core.fsmonitor=false --no-pager "$@"
}

# The diff options shared by the tracked and the untracked diffs: no external
# diff or textconv program, no color, the standard a/ b/ prefixes whatever the
# user's config says.
DIFF_OPTS="--no-ext-diff --no-textconv --no-color --src-prefix=a/ --dst-prefix=b/"

# show_paths < FILE — each path on its own indented stderr line, control
# characters replaced so a path cannot forge or split a diagnostic line.
show_paths() {
	sed 's/[[:cntrl:]]/?/g; s/^/  /' >&2
}

# fail_on_unlistable_paths FILE KIND — FILE holds git's NUL-separated
# output; any newline or tab byte in it belongs to a path, and so does any
# record starting with a double quote or ending in a carriage return (no git
# status token does any of these).
fail_on_unlistable_paths() {
	newline_count=$(tr -cd '\n' <"$1" | wc -c | tr -d ' ')
	if [ "$newline_count" != "0" ]; then
		error "$2 path contains a newline; one-path-per-line lists cannot represent it — rename the file"
		exit 1
	fi
	tr '\000' '\n' <"$1" | awk 'index($0, "\t") > 0' >"$1.tab-paths"
	if [ -s "$1.tab-paths" ]; then
		error "$2 path contains a tab; the tab-delimited lists cannot carry it unambiguously — rename the file (tab shown as ?):"
		show_paths <"$1.tab-paths"
		exit 1
	fi
	if tr '\000' '\n' <"$1" | awk '/^"/ || /\r$/ { found = 1 } END { exit !found }'; then
		error "$2 path starts with a double quote or ends in a carriage return; one-path-per-line lists cannot carry it unambiguously — rename the file"
		exit 1
	fi
}

# build_worktree_tree DIR — print the sha of a tree object holding the
# working tree as it is now (see the header's WHY on snapshots). Built in a
# private index under DIR, which must exist: seeded with the repo index's
# entries (read, never written), then every tracked path brought to its
# working-tree content and every untracked, non-ignored file added —
# .crucible/ included, a nested repository not. Runs in a subshell so
# GIT_INDEX_FILE never reaches another git call; each step is checked, and
# any failure exits the subshell with 1.
build_worktree_tree() (
	repo_git ls-files -s -z >"$1/index-entries" || {
		error "git ls-files -s failed in $TOP"
		exit 1
	}
	GIT_INDEX_FILE=$1/index
	export GIT_INDEX_FILE
	repo_git update-index -z --index-info <"$1/index-entries" || {
		error "failed to seed the snapshot index in $TOP"
		exit 1
	}
	repo_git add -u || {
		error "git add -u failed for the snapshot index in $TOP"
		exit 1
	}
	repo_git ls-files -z --others --exclude-standard >"$1/untracked.z" || {
		error "git ls-files --others failed in $TOP"
		exit 1
	}
	fail_on_unlistable_paths "$1/untracked.z" "an untracked"
	# The paths hold no newline (fail_on_unlistable_paths), so they can be
	# filtered line by line and turned back into NUL-separated records.
	tr '\000' '\n' <"$1/untracked.z" | awk '!/\/$/' | tr '\n' '\000' >"$1/untracked-files.z"
	repo_git update-index --add -z --stdin <"$1/untracked-files.z" || {
		error "failed to add the untracked files to the snapshot index in $TOP"
		exit 1
	}
	repo_git write-tree || {
		error "git write-tree failed for the snapshot index in $TOP"
		exit 1
	}
)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO_ROOT=""
OPT_OUT_DIR=""
OPT_BASE=""
OPT_WHOLE_BRANCH=0
OPT_PATHS_FILE=""
OPT_INCLUDE_CRUCIBLE=0
OPT_SINCE_SNAPSHOT=""
OPT_SNAPSHOT_OUT=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo-root)  need_arg "$1" "${2:-}"; OPT_REPO_ROOT=$2; shift ;;
		--out-dir)    need_arg "$1" "${2:-}"; OPT_OUT_DIR=$2; shift ;;
		--base)       need_arg "$1" "${2:-}"; OPT_BASE=$2; shift ;;
		--paths-file) need_arg "$1" "${2:-}"; OPT_PATHS_FILE=$2; shift ;;
		--whole-branch) OPT_WHOLE_BRANCH=1 ;;
		--include-crucible) OPT_INCLUDE_CRUCIBLE=1 ;;
		--since-snapshot) need_arg "$1" "${2:-}"; OPT_SINCE_SNAPSHOT=$2; shift ;;
		--snapshot-out) need_arg "$1" "${2:-}"; OPT_SNAPSHOT_OUT=$2; shift ;;
		-h|--help)    usage; exit 0 ;;
		--)           shift; break ;;
		-*)           usage >&2; error "unknown option: $1"; exit 2 ;;
		*)            usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO_ROOT" ] || { usage >&2; error "--repo-root is required"; exit 2; }

if [ -n "$OPT_SNAPSHOT_OUT" ]; then
	if [ -n "$OPT_OUT_DIR" ] || [ -n "$OPT_BASE" ] || [ "$OPT_WHOLE_BRANCH" -eq 1 ] || [ -n "$OPT_PATHS_FILE" ] || [ -n "$OPT_SINCE_SNAPSHOT" ]; then
		usage >&2
		error "--snapshot-out takes only --repo-root (and --include-crucible, which does not change the snapshot); record one with: $PROG --repo-root PATH --snapshot-out FILE"
		exit 2
	fi
else
	[ -n "$OPT_OUT_DIR" ] || { usage >&2; error "--out-dir is required"; exit 2; }
fi

base_option_count=$OPT_WHOLE_BRANCH
[ -z "$OPT_BASE" ] || base_option_count=$((base_option_count + 1))
[ -z "$OPT_SINCE_SNAPSHOT" ] || base_option_count=$((base_option_count + 1))
if [ "$base_option_count" -gt 1 ]; then
	usage >&2
	error "--base, --whole-branch and --since-snapshot are mutually exclusive"
	exit 2
fi

if [ -n "$OPT_SINCE_SNAPSHOT" ]; then
	case "$OPT_SINCE_SNAPSHOT" in
		*[!0-9a-f]*) since_snapshot_is_hex=false ;;
		*)           since_snapshot_is_hex=true ;;
	esac
	if [ "$since_snapshot_is_hex" = false ] || { [ "${#OPT_SINCE_SNAPSHOT}" -ne 40 ] && [ "${#OPT_SINCE_SNAPSHOT}" -ne 64 ]; }; then
		usage >&2
		error "invalid --since-snapshot: $OPT_SINCE_SNAPSHOT (expected the full 40- or 64-hex sha a --snapshot-out run printed)"
		exit 2
	fi
fi

case "$OPT_BASE" in
	-*) usage >&2; error "invalid --base: $OPT_BASE (a ref cannot start with \"-\")"; exit 2 ;;
	*)  : ;;
esac

if [ ! -d "$OPT_REPO_ROOT" ]; then
	usage >&2
	error "--repo-root does not exist or is not a directory: $OPT_REPO_ROOT"
	exit 2
fi

if [ -n "$OPT_OUT_DIR" ] && [ -e "$OPT_OUT_DIR" ] && [ ! -d "$OPT_OUT_DIR" ]; then
	usage >&2
	error "--out-dir exists and is not a directory: $OPT_OUT_DIR"
	exit 2
fi

if [ -n "$OPT_PATHS_FILE" ] && { [ ! -f "$OPT_PATHS_FILE" ] || [ ! -r "$OPT_PATHS_FILE" ]; }; then
	usage >&2
	error "--paths-file does not exist or is not readable: $OPT_PATHS_FILE"
	exit 2
fi

if ! command -v git >/dev/null 2>&1; then
	error "git is not installed"
	exit 1
fi

# ---------------------------------------------------------------------------
# --repo-root must be the work tree's top level: every path this script
# writes, and every path a writer checks against, is relative to it.
# ---------------------------------------------------------------------------
PHYSICAL_REPO_ROOT=$(cd "$OPT_REPO_ROOT" && pwd -P) || {
	error "cannot resolve --repo-root: $OPT_REPO_ROOT"
	exit 1
}

if ! TOP=$(git -C "$PHYSICAL_REPO_ROOT" rev-parse --show-toplevel 2>/dev/null) || [ -z "$TOP" ]; then
	error "--repo-root is not inside a git work tree: $OPT_REPO_ROOT"
	exit 1
fi

PHYSICAL_TOP=$(cd "$TOP" && pwd -P) || {
	error "cannot resolve the repository top level: $TOP"
	exit 1
}

if [ "$PHYSICAL_TOP" != "$PHYSICAL_REPO_ROOT" ]; then
	usage >&2
	error "--repo-root must be the repository top level: $OPT_REPO_ROOT is inside $PHYSICAL_TOP"
	exit 2
fi
TOP=$PHYSICAL_TOP

# ---------------------------------------------------------------------------
# Private work directories, removed on every exit path: WORK_DIR inside
# --out-dir (same filesystem, so each output is published by an atomic
# rename), and with --snapshot-out the snapshot's index directory and staged
# file beside FILE.
# ---------------------------------------------------------------------------
WORK_DIR=""
SNAPSHOT_WORK_DIR=""
SNAPSHOT_TMP=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[ -z "$WORK_DIR" ]          || rm -rf "$WORK_DIR" 2>/dev/null || true
	[ -z "$SNAPSHOT_WORK_DIR" ] || rm -rf "$SNAPSHOT_WORK_DIR" 2>/dev/null || true
	[ -z "$SNAPSHOT_TMP" ]      || rm -f "$SNAPSHOT_TMP" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ---------------------------------------------------------------------------
# --snapshot-out: record the working tree and stop. FILE's directory must
# exist and lie outside the repo, so neither the file nor the snapshot's
# private index can show up as an untracked change of the tree being
# recorded.
# ---------------------------------------------------------------------------
if [ -n "$OPT_SNAPSHOT_OUT" ]; then
	snapshot_name=${OPT_SNAPSHOT_OUT##*/}
	case "$OPT_SNAPSHOT_OUT" in
		*/*) snapshot_parent=${OPT_SNAPSHOT_OUT%/*}; [ -n "$snapshot_parent" ] || snapshot_parent=/ ;;
		*)   snapshot_parent=. ;;
	esac
	if [ -z "$snapshot_name" ] || [ -d "$OPT_SNAPSHOT_OUT" ]; then
		usage >&2
		error "--snapshot-out must name a file, not a directory: $OPT_SNAPSHOT_OUT"
		exit 2
	fi
	if [ ! -d "$snapshot_parent" ]; then
		usage >&2
		error "--snapshot-out's directory does not exist: $snapshot_parent"
		exit 2
	fi
	PHYSICAL_SNAPSHOT_DIR=$(cd "$snapshot_parent" && pwd -P) || {
		error "cannot resolve --snapshot-out's directory: $snapshot_parent"
		exit 1
	}
	case "$PHYSICAL_SNAPSHOT_DIR" in
		"$TOP"|"$TOP"/*)
			usage >&2
			error "--snapshot-out must lie outside the repo: $PHYSICAL_SNAPSHOT_DIR is inside $TOP"
			exit 2
			;;
		*) : ;;
	esac

	SNAPSHOT_WORK_DIR=$(mktemp -d "$PHYSICAL_SNAPSHOT_DIR/.diff-scope-snapshot.XXXXXX") || {
		error "failed to create a work directory in $PHYSICAL_SNAPSHOT_DIR"
		exit 1
	}
	SNAPSHOT_TREE=$(build_worktree_tree "$SNAPSHOT_WORK_DIR") || {
		error "failed to record the working tree of $TOP as a snapshot"
		exit 1
	}
	SNAPSHOT_TMP=$(mktemp "$PHYSICAL_SNAPSHOT_DIR/.diff-scope-snapshot-out.XXXXXX") || {
		error "failed to stage --snapshot-out in $PHYSICAL_SNAPSHOT_DIR"
		exit 1
	}
	printf '%s\n' "$SNAPSHOT_TREE" >"$SNAPSHOT_TMP"
	if ! mv -f "$SNAPSHOT_TMP" "$PHYSICAL_SNAPSHOT_DIR/$snapshot_name"; then
		error "failed to publish --snapshot-out: $PHYSICAL_SNAPSHOT_DIR/$snapshot_name"
		exit 1
	fi
	SNAPSHOT_TMP=""
	printf 'DIFF_SNAPSHOT=%s\n' "$SNAPSHOT_TREE"
	exit 0
fi

# ---------------------------------------------------------------------------
# --out-dir: resolved physically and checked against the repo BEFORE anything
# is created, so a missing --out-dir inside the repo is refused, never made.
# The deepest existing ancestor is resolved through its symlinks; the missing
# components below it cannot be symlinks, and "." or ".." among them is
# refused rather than interpreted.
# ---------------------------------------------------------------------------
refuse_out_dir_inside_repo() {
	case "$1" in
		"$TOP"|"$TOP"/*)
			usage >&2
			error "--out-dir must lie outside the repo: $1 is inside $TOP"
			exit 2
			;;
		*) : ;;
	esac
}

case "$OPT_OUT_DIR" in
	/*) out_dir_path=$OPT_OUT_DIR ;;
	*)  out_dir_path=$(pwd -P)/$OPT_OUT_DIR ;;
esac
while :; do
	case "$out_dir_path" in
		?*/) out_dir_path=${out_dir_path%/} ;;
		*)   break ;;
	esac
done

out_dir_ancestor=$out_dir_path
out_dir_missing=""
while [ ! -d "$out_dir_ancestor" ]; do
	out_dir_missing="/${out_dir_ancestor##*/}$out_dir_missing"
	out_dir_ancestor=${out_dir_ancestor%/*}
	[ -n "$out_dir_ancestor" ] || out_dir_ancestor=/
done
case "$out_dir_missing/" in
	*/./*|*/../*)
		usage >&2
		error "--out-dir does not exist and its missing part holds a \".\" or \"..\" component: $OPT_OUT_DIR"
		exit 2
		;;
	*) : ;;
esac

PHYSICAL_OUT_ANCESTOR=$(cd "$out_dir_ancestor" && pwd -P) || {
	error "cannot resolve --out-dir: $OPT_OUT_DIR"
	exit 1
}
refuse_out_dir_inside_repo "${PHYSICAL_OUT_ANCESTOR%/}$out_dir_missing"

if [ -n "$out_dir_missing" ] && ! mkdir -p "${PHYSICAL_OUT_ANCESTOR%/}$out_dir_missing"; then
	error "cannot create --out-dir: $OPT_OUT_DIR"
	exit 1
fi

ABS_OUT_DIR=$(cd "$OPT_OUT_DIR" && pwd -P) || {
	error "cannot resolve --out-dir: $OPT_OUT_DIR"
	exit 1
}
refuse_out_dir_inside_repo "$ABS_OUT_DIR"

WORK_DIR=$(mktemp -d "$ABS_OUT_DIR/.diff-scope.XXXXXX") || {
	error "failed to create a work directory in $ABS_OUT_DIR"
	exit 1
}

# ---------------------------------------------------------------------------
# The parent of the current branch, for --whole-branch (see the header's WHY
# on the parent's order). Each finder sets PARENT_REF, the ref git resolves,
# and PARENT_NAME, the name DIFF_BASE_REF shows, or fails when it finds none.
# OWN_BRANCH_REFS lists the refs that are the branch itself: the branch, the
# branch of its name on each remote, and its upstream when that is a remote's
# branch of the same name (an upstream of another name, or a local one, is a
# parent, as with `git switch -c feat origin/main`).
# ---------------------------------------------------------------------------
OWN_BRANCH_REFS="$WORK_DIR/own-branch-refs"

list_own_branch_refs() {
	: >"$OWN_BRANCH_REFS" || {
		error "failed to write $OWN_BRANCH_REFS"
		exit 1
	}
	[ -n "$CURRENT_BRANCH_REF" ] || return 0
	printf '%s\n' "$CURRENT_BRANCH_REF" >>"$OWN_BRANCH_REFS" || {
		error "failed to write $OWN_BRANCH_REFS"
		exit 1
	}
	if ! upstream_fields=$(repo_git for-each-ref --format='%(upstream)%09%(upstream:remotename)%09%(upstream:remoteref)' "$CURRENT_BRANCH_REF"); then
		error "git for-each-ref failed in $TOP"
		exit 1
	fi
	upstream_ref=${upstream_fields%%"$TAB"*}
	upstream_remote_ref=${upstream_fields##*"$TAB"}
	upstream_remote=${upstream_fields#*"$TAB"}
	upstream_remote=${upstream_remote%"$TAB"*}
	if [ -n "$upstream_ref" ] && [ -n "$upstream_remote" ] && [ "$upstream_remote" != . ] \
		&& [ "$upstream_remote_ref" = "$CURRENT_BRANCH_REF" ]; then
		printf '%s\n' "$upstream_ref" >>"$OWN_BRANCH_REFS" || {
			error "failed to write $OWN_BRANCH_REFS"
			exit 1
		}
	fi
	if ! repo_git remote >"$WORK_DIR/remotes"; then
		error "git remote failed in $TOP"
		exit 1
	fi
	BRANCH_NAME=${CURRENT_BRANCH_REF#refs/heads/} \
		awk '{ print "refs/remotes/" $0 "/" ENVIRON["BRANCH_NAME"] }' "$WORK_DIR/remotes" >>"$OWN_BRANCH_REFS" || {
		error "failed to list the remote branches of HEAD's name in $TOP"
		exit 1
	}
}

# reflog_parent — the start point the branch's oldest reflog entry records,
# when it is a ref or a sha that still names a commit. A start point relative
# to HEAD, to the previous branch or to an upstream, or one with a revision
# suffix or a path, resolves differently now than when the branch was made.
reflog_parent() {
	[ -n "$CURRENT_BRANCH_REF" ] || return 1
	creation_subject=$(repo_git log -g --no-show-signature --format=%gs "$CURRENT_BRANCH_REF" -- 2>/dev/null | tail -n 1)
	case "$creation_subject" in
		"branch: Created from "?*) created_from=${creation_subject#branch: Created from } ;;
		*) return 1 ;;
	esac
	case "$created_from" in
		-*|HEAD|@|*@\{*|*[~^:]*) return 1 ;;
		*[!0-9a-f]*)
			created_from_ref=$(repo_git rev-parse --symbolic-full-name "$created_from" 2>/dev/null) || return 1
			case "$created_from_ref" in
				refs/*) : ;;
				*) return 1 ;;
			esac
			if grep -qxF -- "$created_from_ref" "$OWN_BRANCH_REFS"; then
				return 1
			fi
			;;
		*) created_from_ref=$created_from ;;
	esac
	repo_git rev-parse --verify --quiet "$created_from_ref^{commit}" >/dev/null 2>&1 || return 1
	PARENT_REF=$created_from_ref
	PARENT_NAME=$created_from
}

# nearest_branch_parent — the local or remote-tracking branch HEAD has the
# fewest commits beyond; a tie goes to a local branch, then main or master,
# then the name. A symbolic ref (origin/HEAD) or one of OWN_BRANCH_REFS is no
# candidate. When a candidate already holds HEAD (no commit beyond it), none
# is chosen: that branch cannot be told apart from a parent, and any other is
# farther than it. One git call per branch.
nearest_branch_parent() {
	if ! repo_git for-each-ref --format='%(refname)%09%(symref)' refs/heads refs/remotes >"$WORK_DIR/branch-refs"; then
		error "git for-each-ref failed in $TOP"
		exit 1
	fi
	awk -F "$TAB" 'FILENAME == ARGV[1] { own[$0] = 1; next }
	     $2 == "" && !($1 in own) { print $1 }' "$OWN_BRANCH_REFS" "$WORK_DIR/branch-refs" >"$WORK_DIR/branch-candidates" || {
		error "failed to list the candidate parent branches in $TOP"
		exit 1
	}
	while IFS= read -r ref_name; do
		if ! commits_beyond=$(repo_git rev-list --count "$ref_name..HEAD" --); then
			error "git rev-list failed for a branch in $TOP"
			exit 1
		fi
		case "$ref_name" in
			refs/heads/*) branch_name=${ref_name#refs/heads/}; branch_locality=0 ;;
			*)            branch_name=${ref_name#refs/remotes/}; branch_locality=1 ;;
		esac
		case "$branch_locality:$branch_name" in
			0:main|0:master|1:*/main|1:*/master) branch_preference=0 ;;
			*)                                   branch_preference=1 ;;
		esac
		printf '%s\t%s\t%s\t%s\t%s\n' "$commits_beyond" "$branch_locality" "$branch_preference" "$branch_name" "$ref_name"
	done <"$WORK_DIR/branch-candidates" >"$WORK_DIR/branch-distances" || {
		error "failed to write $WORK_DIR/branch-distances"
		exit 1
	}
	sort -t "$TAB" -k1,1n -k2,2n -k3,3n -k4,4 "$WORK_DIR/branch-distances" >"$WORK_DIR/branch-distances.sorted" || {
		error "failed to sort the candidate parent branches"
		exit 1
	}
	nearest_branch=$(head -n 1 "$WORK_DIR/branch-distances.sorted")
	[ -n "$nearest_branch" ] || return 1
	case "$nearest_branch" in
		"0$TAB"*)
			note "a branch already holds HEAD (${nearest_branch##*"$TAB"}), so no nearest branch is taken as the parent"
			return 1
			;;
		*) : ;;
	esac
	PARENT_REF=${nearest_branch##*"$TAB"}
	nearest_branch=${nearest_branch%"$TAB"*}
	PARENT_NAME=${nearest_branch##*"$TAB"}
}

# default_branch_parent — origin/HEAD's target, else main, else master.
default_branch_parent() {
	if default_ref=$(repo_git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) && [ -n "$default_ref" ]; then
		PARENT_REF=$default_ref
		PARENT_NAME=${default_ref#refs/remotes/}
	elif repo_git rev-parse --verify --quiet refs/heads/main >/dev/null 2>&1; then
		PARENT_REF=refs/heads/main
		PARENT_NAME=main
	elif repo_git rev-parse --verify --quiet refs/heads/master >/dev/null 2>&1; then
		PARENT_REF=refs/heads/master
		PARENT_NAME=master
	else
		return 1
	fi
}

# find_branch_parent — the parent of the current branch, in the header's
# order; sets PARENT_REF, PARENT_NAME and PARENT_FOUND_BY, or fails.
find_branch_parent() {
	CURRENT_BRANCH_REF=$(repo_git symbolic-ref --quiet HEAD 2>/dev/null) || CURRENT_BRANCH_REF=""
	list_own_branch_refs
	if reflog_parent; then
		PARENT_FOUND_BY="reflog"
	elif nearest_branch_parent; then
		PARENT_FOUND_BY="nearest-branch"
	elif default_branch_parent; then
		PARENT_FOUND_BY="default"
	else
		return 1
	fi
}

# list_branch_crucible_paths FILE — write to FILE, NUL-separated, every
# tracked path at or under .crucible/ that differs between the branch's fork
# point from its parent and the working tree (see the header's WHY on
# .crucible/). With no parent or no fork point, every tracked path there.
list_branch_crucible_paths() {
	if find_branch_parent \
		&& fork_point=$(repo_git merge-base HEAD "$PARENT_REF" 2>/dev/null) && [ -n "$fork_point" ]; then
		if ! repo_git diff --name-only -z --no-renames --no-relative --no-ext-diff "$fork_point" -- .crucible >"$1"; then
			error "git diff --name-only failed for .crucible/ in $TOP"
			exit 1
		fi
		return 0
	fi
	note "no parent branch of HEAD found: every tracked path under .crucible/ is listed as X"
	if ! repo_git ls-files -z -- .crucible >"$1"; then
		error "git ls-files failed for .crucible/ in $TOP"
		exit 1
	fi
}

# ---------------------------------------------------------------------------
# The base, and how it was chosen (DIFF_BASE_FROM) from what (DIFF_BASE_REF):
# the --since-snapshot tree; else HEAD (the default); else the merge-base of
# HEAD with --base or with the parent --whole-branch finds. Never guessed
# past the parent's order. DIFF_TARGET is the tree the base is diffed
# against: empty for the working tree, or (since a snapshot) the current
# tree.
# ---------------------------------------------------------------------------
DIFF_TARGET=""
HEAD_COMMIT=$(repo_git rev-parse --verify --quiet "HEAD^{commit}" 2>/dev/null) || HEAD_COMMIT=""
if [ -n "$OPT_SINCE_SNAPSHOT" ]; then
	snapshot_type=$(repo_git cat-file -t "$OPT_SINCE_SNAPSHOT" 2>/dev/null) || snapshot_type=""
	if [ "$snapshot_type" != tree ]; then
		usage >&2
		error "--since-snapshot $OPT_SINCE_SNAPSHOT is not a tree object in $TOP (take one with --snapshot-out; an unreferenced snapshot can be pruned by git gc)"
		exit 2
	fi
	DIFF_BASE=$OPT_SINCE_SNAPSHOT
	DIFF_BASE_REF=$OPT_SINCE_SNAPSHOT
	DIFF_BASE_FROM="snapshot"
	BASE_DESCRIPTION="the snapshot $DIFF_BASE"
elif [ -z "$HEAD_COMMIT" ]; then
	error "HEAD has no commit yet in $TOP — commit once, or diff since a snapshot (--snapshot-out, then --since-snapshot)"
	exit 1
elif [ -n "$OPT_BASE" ]; then
	BASE_REF=$OPT_BASE
	BASE_LABEL="--base $OPT_BASE"
	DIFF_BASE_REF=$OPT_BASE
	DIFF_BASE_FROM="explicit"
elif [ "$OPT_WHOLE_BRANCH" -eq 1 ]; then
	if find_branch_parent; then
		DIFF_BASE_FROM=$PARENT_FOUND_BY
	else
		error "cannot find the parent branch of HEAD in $TOP (no usable reflog start point, no nearest branch or one already holds HEAD, no origin/HEAD, main or master) — pass --base REF"
		exit 1
	fi
	BASE_REF=$PARENT_REF
	BASE_LABEL="the parent branch $PARENT_NAME"
	DIFF_BASE_REF=$PARENT_NAME
	note "--whole-branch: the parent branch is $PARENT_NAME (found by: $DIFF_BASE_FROM)"
else
	DIFF_BASE=$HEAD_COMMIT
	DIFF_BASE_REF=HEAD
	DIFF_BASE_FROM="head"
	BASE_DESCRIPTION="HEAD ($DIFF_BASE)"
fi

if [ "$DIFF_BASE_FROM" = explicit ] || [ "$OPT_WHOLE_BRANCH" -eq 1 ]; then
	if ! BASE_COMMIT=$(repo_git rev-parse --verify --quiet "$BASE_REF^{commit}" 2>/dev/null); then
		error "$BASE_LABEL does not name a commit in $TOP"
		exit 1
	fi
	if ! DIFF_BASE=$(repo_git merge-base HEAD "$BASE_COMMIT" 2>/dev/null) || [ -z "$DIFF_BASE" ]; then
		error "HEAD has no merge-base with $BASE_LABEL in $TOP (unrelated histories)"
		exit 1
	fi
	BASE_DESCRIPTION="$DIFF_BASE ($BASE_LABEL's merge-base with HEAD)"
fi

if [ -n "$OPT_SINCE_SNAPSHOT" ]; then
	mkdir "$WORK_DIR/current-tree" || {
		error "failed to create a work directory in $WORK_DIR"
		exit 1
	}
	DIFF_TARGET=$(build_worktree_tree "$WORK_DIR/current-tree") || {
		error "failed to record the current working tree of $TOP"
		exit 1
	}
fi

TRACKED_Z="$WORK_DIR/tracked.z"
UNTRACKED_Z="$WORK_DIR/untracked.z"
STATUS_RECORDS="$WORK_DIR/status-records"
RENAMES="$WORK_DIR/renames"
CHANGE_LINES="$WORK_DIR/change-lines"
UNTRACKED="$WORK_DIR/untracked"
SELECTED="$WORK_DIR/selected"
PATH_KINDS="$WORK_DIR/path-kinds"
HASH_PATHS="$WORK_DIR/hash-paths"
HASHES="$WORK_DIR/hashes"
PATCH_COVERAGE_Z="$WORK_DIR/patch-coverage.z"
SYMLINK_EXCLUDES="$WORK_DIR/symlink-excludes"
CHANGES_OUT="$WORK_DIR/changes.txt"
FILES_OUT="$WORK_DIR/diff-files.txt"
FILES_TSV_OUT="$WORK_DIR/diff-files.tsv"
HUNKS_OUT="$WORK_DIR/diff-hunks.tsv"
PATCH_OUT="$WORK_DIR/diff.patch"

# ---------------------------------------------------------------------------
# The change set. Tracked: `git diff <base>` compares the base commit with the
# working tree, so it covers branch commits, staged and unstaged changes in
# one pass. Untracked: every non-ignored file git does not track. Since a
# snapshot, `git diff <snapshot> <current tree>` covers both, and there is no
# separate untracked list. Both read NUL-separated, so no path is ever quoted
# or split.
# ---------------------------------------------------------------------------
if ! repo_git diff --name-status -z -M --no-relative --no-ext-diff "$DIFF_BASE" ${DIFF_TARGET:+"$DIFF_TARGET"} >"$TRACKED_Z"; then
	error "git diff --name-status failed in $TOP"
	exit 1
fi
if [ -n "$DIFF_TARGET" ]; then
	: >"$UNTRACKED_Z"
elif ! repo_git ls-files -z --others --exclude-standard >"$UNTRACKED_Z"; then
	error "git ls-files --others failed in $TOP"
	exit 1
fi
fail_on_unlistable_paths "$TRACKED_Z" "a changed"
fail_on_unlistable_paths "$UNTRACKED_Z" "an untracked"

tr '\000' '\n' <"$TRACKED_Z" >"$STATUS_RECORDS"
: >"$CHANGE_LINES"
: >"$RENAMES"
: >"$SYMLINK_EXCLUDES"

# One "<status><TAB><path>" line per tracked change. git's record is a status
# token then one path, or two (old, new) for a rename or copy. A copy is an
# addition of its new path; a type change or an unmerged path is a
# modification. RENAMES holds new/old line pairs, so a selected rename can be
# diffed as a rename.
while IFS= read -r git_status; do
	case "$git_status" in
		R*)
			IFS= read -r old_path; IFS= read -r new_path
			printf 'R\t%s\n' "$new_path" >>"$CHANGE_LINES"
			printf '%s\n%s\n' "$new_path" "$old_path" >>"$RENAMES"
			;;
		C*)
			IFS= read -r old_path; IFS= read -r new_path
			printf 'A\t%s\n' "$new_path" >>"$CHANGE_LINES"
			;;
		A) IFS= read -r path; printf 'A\t%s\n' "$path" >>"$CHANGE_LINES" ;;
		D) IFS= read -r path; printf 'D\t%s\n' "$path" >>"$CHANGE_LINES" ;;
		M|T|U) IFS= read -r path; printf 'M\t%s\n' "$path" >>"$CHANGE_LINES" ;;
		*)
			error "unexpected git diff status '$git_status' in $TOP"
			exit 1
			;;
	esac
done <"$STATUS_RECORDS"

# An untracked entry ending in "/" is a nested repository, not a file of this
# one: it has no diff of its own here.
tr '\000' '\n' <"$UNTRACKED_Z" | while IFS= read -r path; do
	case "$path" in
		*/) printf '%s\n' "$path" >>"$WORK_DIR/nested-repos" ;;
		*)  printf '%s\n' "$path" ;;
	esac
done >"$UNTRACKED"
if [ -s "$WORK_DIR/nested-repos" ]; then
	warn "skipping untracked nested repositories (not files of this repo):"
	show_paths <"$WORK_DIR/nested-repos"
fi
sed "s/^/U$TAB/" "$UNTRACKED" >>"$CHANGE_LINES"

# sort_change_lines — CHANGE_LINES as one line per path, sorted. A path both
# deleted from the index and present untracked (git rm --cached) is one
# modified file.
sort_change_lines() {
	sort -t "$TAB" -k2 "$CHANGE_LINES" | awk '
		{ path = substr($0, 3) }
		path == previous_path { status = "M"; next }
		NR > 1 { print status "\t" previous_path }
		{ status = substr($0, 1, 1); previous_path = path }
		END { if (NR > 0) print status "\t" previous_path }
	' >"$CHANGE_LINES.sorted"
	mv "$CHANGE_LINES.sorted" "$CHANGE_LINES"
}
sort_change_lines

# The framework's own artifacts: every path at or under .crucible/ becomes an
# X line, unless --include-crucible. A rename across the .crucible/ boundary
# loses its pairing: a rename out of .crucible/ stays listed as R but the
# patch shows its new path as added, and the old path of a rename into
# .crucible/ is listed as deleted, as the patch shows it.
CRUCIBLE_EXCLUDED=0
if [ "$OPT_INCLUDE_CRUCIBLE" -eq 0 ]; then
	awk -v count_file="$WORK_DIR/crucible-count" '
		{ path = substr($0, 3) }
		path == ".crucible" || substr(path, 1, 10) == ".crucible/" { excluded++; print "X\t" path; next }
		{ print }
		END { print excluded + 0 > count_file }
	' "$CHANGE_LINES" >"$CHANGE_LINES.kept"
	CRUCIBLE_EXCLUDED=$(cat "$WORK_DIR/crucible-count")
	: >"$RENAMES.kept"
	awk -v kept_file="$RENAMES.kept" '
		function is_crucible(path) { return path == ".crucible" || substr(path, 1, 10) == ".crucible/" }
		NR % 2 == 1 { new_path = $0; next }
		is_crucible($0) { next }
		is_crucible(new_path) { print "D\t" $0; next }
		{ print new_path > kept_file; print > kept_file }
	' "$RENAMES" >>"$CHANGE_LINES.kept"
	mv "$RENAMES.kept" "$RENAMES"
	mv "$CHANGE_LINES.kept" "$CHANGE_LINES"
	sort_change_lines
	if [ "$CRUCIBLE_EXCLUDED" -gt 0 ]; then
		note "left out $CRUCIBLE_EXCLUDED changed path(s) under .crucible/ (framework artifacts), listed as X in changes.txt; pass --include-crucible to keep them"
	fi
fi

# Unless the base is the fork point (--whole-branch), a .crucible/ path
# changed in a branch commit before the base is not in the change set, so it
# is added as an X line (see the header's WHY on .crucible/), unless the
# change set already lists it.
if [ "$OPT_WHOLE_BRANCH" -eq 0 ]; then
	list_branch_crucible_paths "$WORK_DIR/branch-crucible.z"
	fail_on_unlistable_paths "$WORK_DIR/branch-crucible.z" "a .crucible/"
	tr '\000' '\n' <"$WORK_DIR/branch-crucible.z" | awk '
		FILENAME == ARGV[1] { listed[substr($0, 3)] = 1; next }
		!($0 in listed) { print "X\t" $0 }
	' "$CHANGE_LINES" - >"$WORK_DIR/branch-crucible-lines" || {
		error "failed to list the branch's .crucible/ paths in $TOP"
		exit 1
	}
	if [ -s "$WORK_DIR/branch-crucible-lines" ]; then
		cat "$WORK_DIR/branch-crucible-lines" >>"$CHANGE_LINES"
		sort_change_lines
		branch_crucible_count=$(wc -l <"$WORK_DIR/branch-crucible-lines")
		note "listed $((branch_crucible_count)) more path(s) under .crucible/ as X in changes.txt (changed on the branch, or every one when no parent is found), so none is trusted as unchanged"
	fi
fi

# Changed symlinks (see the header's WHY): every non-deleted, non-X path that
# is a symlink becomes an S line, kept out of the selection and the patch.
# SYMLINK_EXCLUDES holds each S path plus the old path of an S rename, which
# the all-mode diff leaves out so the rename does not surface as a deletion.
SYMLINKS_LISTED=0
while IFS= read -r change_line; do
	path=${change_line#??}
	case "$change_line" in
		D*|X*) printf '%s\n' "$change_line" ;;
		*)
			if [ -L "$TOP/$path" ]; then
				printf 'S\t%s\n' "$path"
				printf '%s\n' "$path" >>"$SYMLINK_EXCLUDES"
				SYMLINKS_LISTED=$((SYMLINKS_LISTED + 1))
			else
				printf '%s\n' "$change_line"
			fi
			;;
	esac
done <"$CHANGE_LINES" >"$CHANGE_LINES.marked"
mv "$CHANGE_LINES.marked" "$CHANGE_LINES"
if [ "$SYMLINKS_LISTED" -gt 0 ]; then
	awk 'NR == FNR { symlink[$0] = 1; next }
	     FNR % 2 == 1 { new_path = $0; next }
	     new_path in symlink { print }' "$SYMLINK_EXCLUDES" "$RENAMES" >"$WORK_DIR/symlink-rename-sources"
	cat "$WORK_DIR/symlink-rename-sources" >>"$SYMLINK_EXCLUDES"
	note "left out $SYMLINKS_LISTED changed symlink(s), listed as S in changes.txt; a symlink is never reviewed or tested"
fi

if ! grep -qv '^[XS]' "$CHANGE_LINES"; then
	if [ "$CRUCIBLE_EXCLUDED" -gt 0 ] || [ "$SYMLINKS_LISTED" -gt 0 ]; then
		error "nothing in the diff to review or test: only paths under .crucible/ (X) or symlinks (S) differ from $BASE_DESCRIPTION"
	elif [ -n "$DIFF_TARGET" ]; then
		error "nothing in the diff to review or test: the working tree matches $BASE_DESCRIPTION"
	else
		error "nothing in the diff to review or test: the working tree matches $BASE_DESCRIPTION and there are no untracked files"
	fi
	[ "$DIFF_BASE_FROM" != head ] || note "by default only uncommitted work is diffed; pass --whole-branch to include the branch's commits"
	exit 3
fi

# ---------------------------------------------------------------------------
# The selection: every changed path, or exactly the --paths-file paths, each
# of which must be in the change set.
# ---------------------------------------------------------------------------
if [ -n "$OPT_PATHS_FILE" ]; then
	DIFF_SCOPE=effort
	if ! sed '/^$/d' "$OPT_PATHS_FILE" | sort -u >"$SELECTED"; then
		error "failed to read --paths-file: $OPT_PATHS_FILE"
		exit 1
	fi
	if [ ! -s "$SELECTED" ]; then
		usage >&2
		error "--paths-file lists no paths: $OPT_PATHS_FILE"
		exit 2
	fi
	awk -v excluded_file="$WORK_DIR/excluded-selected" -v symlink_file="$WORK_DIR/symlinks-selected" '
		NR == FNR { status_of[substr($0, 3)] = substr($0, 1, 1); next }
		!($0 in status_of) { print; next }
		status_of[$0] == "X" { print > excluded_file }
		status_of[$0] == "S" { print > symlink_file }
	' "$CHANGE_LINES" "$SELECTED" >"$WORK_DIR/outside"
	if [ -s "$WORK_DIR/outside" ]; then
		usage >&2
		error "--paths-file names paths that are not in the change set (run without --paths-file to list the full change set in changes.txt):"
		show_paths <"$WORK_DIR/outside"
		exit 2
	fi
	if [ -s "$WORK_DIR/excluded-selected" ]; then
		usage >&2
		error "--paths-file names excluded paths (X in changes.txt: the framework's own artifacts under .crucible/), which are never reviewed or tested:"
		show_paths <"$WORK_DIR/excluded-selected"
		exit 2
	fi
	if [ -s "$WORK_DIR/symlinks-selected" ]; then
		usage >&2
		error "--paths-file names symlinks (S in changes.txt), which are never reviewed or tested (a tool that opens one reads its target):"
		show_paths <"$WORK_DIR/symlinks-selected"
		exit 2
	fi
else
	DIFF_SCOPE=all
	awk '!/^[XS]/ { print substr($0, 3) }' "$CHANGE_LINES" >"$SELECTED"
fi

# ---------------------------------------------------------------------------
# changes.txt: every changed path with its working-tree blob sha. Each path's
# kind is decided ONCE, in the first pass, and the second pass follows it:
# a regular file is hashed in ONE git call for all of them; a symlink on an
# X line hashes its target text, as git stores it; a deleted path, an S line
# or a directory (a submodule) has no blob. A path whose kind changes between the passes fails
# its read rather than taking another path's hash.
# ---------------------------------------------------------------------------
: >"$HASH_PATHS"
while IFS= read -r change_line; do
	path=${change_line#??}
	path_kind=-
	case "$change_line" in
		D*|S*) : ;;
		*)
			if [ -L "$TOP/$path" ]; then
				path_kind=L
			elif [ -f "$TOP/$path" ]; then
				path_kind=F
				printf '%s\n' "$path" >>"$HASH_PATHS"
			fi
			;;
	esac
	printf '%s\n' "$path_kind"
done <"$CHANGE_LINES" >"$PATH_KINDS"

# A selected path that became a symlink after the S lines were marked fails
# the run rather than reaching the patch.
awk -v kinds_file="$PATH_KINDS" '
	NR == FNR { selected[$0] = 1; next }
	{ getline path_kind < kinds_file }
	path_kind == "L" && (substr($0, 3) in selected) { print substr($0, 3) }
' "$SELECTED" "$CHANGE_LINES" >"$WORK_DIR/selected-symlinks"
if [ -s "$WORK_DIR/selected-symlinks" ]; then
	error "selected paths became symlinks while the change set was read; re-run:"
	show_paths <"$WORK_DIR/selected-symlinks"
	exit 1
fi

if ! repo_git hash-object --no-filters --stdin-paths <"$HASH_PATHS" >"$HASHES"; then
	error "git hash-object failed in $TOP"
	exit 1
fi

exec 3<"$HASHES" 4<"$PATH_KINDS"
while IFS= read -r change_line; do
	IFS= read -r path_kind <&4 || {
		error "lost track of a changed path's kind"
		exit 1
	}
	path=${change_line#??}
	blob_sha=-
	case "$path_kind" in
		L)
			link_target=$(readlink "$TOP/$path") || {
				error "failed to read a changed symlink in $TOP"
				exit 1
			}
			blob_sha=$(printf '%s' "$link_target" | repo_git hash-object --stdin) || {
				error "failed to hash a changed symlink's target in $TOP"
				exit 1
			}
			;;
		F)
			IFS= read -r blob_sha <&3 || {
				error "git hash-object returned fewer hashes than paths"
				exit 1
			}
			;;
		*) : ;;
	esac
	printf '%s\t%s\n' "$change_line" "$blob_sha"
done <"$CHANGE_LINES" >"$CHANGES_OUT"
if IFS= read -r unread_hash <&3 || [ -n "${unread_hash:-}" ]; then
	error "git hash-object returned more hashes than paths"
	exit 1
fi
exec 3<&- 4<&-

# ---------------------------------------------------------------------------
# diff-files.txt and diff-files.tsv: the selected paths, and each with its
# blob sha from changes.txt (the path is everything between the first and
# the last tab there).
# ---------------------------------------------------------------------------
cp "$SELECTED" "$FILES_OUT"

if ! awk '
	NR == FNR {
		rest = substr($0, index($0, "\t") + 1)
		match(rest, /\t[^\t]*$/)
		sha_of[substr(rest, 1, RSTART - 1)] = substr(rest, RSTART + 1)
		next
	}
	!($0 in sha_of) { exit 1 }
	{ print $0 "\t" sha_of[$0] }
' "$CHANGES_OUT" "$SELECTED" >"$FILES_TSV_OUT"; then
	error "failed to pair the selected paths with their blob shas"
	exit 1
fi

# ---------------------------------------------------------------------------
# diff.patch: the tracked diff, then each selected untracked file as a
# new-file diff against /dev/null. In effort mode the tracked diff runs once
# over the selected paths plus the old path of each selected rename (so it
# still diffs as a rename), passed literally as arguments; the selection is
# never empty here, so the pathspec always limits the diff. In all mode it
# runs over the whole tree with a pathspec that leaves out .crucible/
# (unless --include-crucible) and each SYMLINK_EXCLUDES path, so its
# argument list grows only with the changed symlinks. The coverage check
# below reuses the same pathspec.
# ---------------------------------------------------------------------------
if [ "$DIFF_SCOPE" = effort ]; then
	PATHSPEC_GIT=repo_git
	awk 'NR == FNR { selected[$0] = 1; next }
	     FNR % 2 == 1 { new_path = $0; next }
	     new_path in selected { print }' "$SELECTED" "$RENAMES" >"$WORK_DIR/rename-sources"
	set --
	while IFS= read -r path; do
		set -- "$@" "$path"
	done <"$WORK_DIR/rename-sources"
	while IFS= read -r path; do
		set -- "$@" "$path"
	done <"$SELECTED"
	if [ $# -eq 0 ]; then
		error "no selected path reached the tracked diff"
		exit 1
	fi
else
	PATHSPEC_GIT=git_at_top
	set -- ':(top)'
	[ "$OPT_INCLUDE_CRUCIBLE" -eq 1 ] || set -- "$@" ':(top,exclude).crucible'
	while IFS= read -r path; do
		set -- "$@" ":(top,exclude,literal)$path"
	done <"$SYMLINK_EXCLUDES"
fi

# shellcheck disable=SC2086  # DIFF_OPTS is a fixed list of option words, split on purpose
"$PATHSPEC_GIT" diff $DIFF_OPTS -M --no-relative "$DIFF_BASE" ${DIFF_TARGET:+"$DIFF_TARGET"} -- "$@" >"$PATCH_OUT" || {
	error "git diff failed in $TOP"
	exit 1
}

# The files that same tracked diff covers (see the header's WHY on checking
# the patch), each printed when it is outside the selection: a non-rename
# path not selected, a rename whose new path is not selected, or a rename
# whose old path is not the one changes.txt pairs with the selected new path.
if ! "$PATHSPEC_GIT" diff --name-status -z -M --no-relative --no-ext-diff "$DIFF_BASE" ${DIFF_TARGET:+"$DIFF_TARGET"} -- "$@" >"$PATCH_COVERAGE_Z"; then
	error "git diff --name-status failed in $TOP"
	exit 1
fi
fail_on_unlistable_paths "$PATCH_COVERAGE_Z" "a changed"
tr '\000' '\n' <"$PATCH_COVERAGE_Z" | awk -v selected_file="$SELECTED" -v renames_file="$RENAMES" '
	BEGIN {
		while ((getline line < selected_file) > 0) selected[line] = 1
		while ((getline new_path < renames_file) > 0) {
			getline old_path < renames_file
			rename_source[new_path] = old_path
		}
	}
	paths_left == 0 { record_status = $0; paths_left = (record_status ~ /^[RC]/) ? 2 : 1; path_count = 0; next }
	{
		record_path[++path_count] = $0
		if (--paths_left > 0) next
		if (path_count == 1) {
			if (!(record_path[1] in selected)) print record_path[1]
		} else if (!(record_path[2] in selected)) {
			print record_path[2]
		} else if (record_status ~ /^R/ && rename_source[record_path[2]] != record_path[1]) {
			print record_path[1]
		}
	}
' >"$WORK_DIR/patch-outside"
if [ -s "$WORK_DIR/patch-outside" ]; then
	error "the diff of the selected paths also covers changed files outside the selection (a selected path that is now a directory, or a rename whose old path changed too):"
	show_paths <"$WORK_DIR/patch-outside"
	if [ "$DIFF_SCOPE" = effort ]; then
		printf '%s: hint: add them to --paths-file if they belong to this effort\n' "$PROG" >&2
		exit 2
	fi
	exit 1
fi

awk 'NR == FNR { untracked[$0] = 1; next } $0 in untracked' "$UNTRACKED" "$SELECTED" >"$WORK_DIR/selected-untracked"
while IFS= read -r path; do
	# --no-index exits 1 when the files differ, which a new file always does.
	diff_status=0
	# shellcheck disable=SC2086  # DIFF_OPTS is a fixed list of option words, split on purpose
	repo_git diff --no-index $DIFF_OPTS -- /dev/null "$path" >>"$PATCH_OUT" || diff_status=$?
	if [ "$diff_status" -ne 1 ]; then
		error "git diff --no-index failed for an untracked file in $TOP (exit $diff_status)"
		exit 1
	fi
done <"$WORK_DIR/selected-untracked"

# ---------------------------------------------------------------------------
# diff-hunks.tsv: the lines each selected file changed (see the header's WHY
# on hunks), from one zero-context diff per file, so each new-side hunk is
# read off a header whose path is known rather than parsed out of the patch.
# A selected rename is diffed with its old path, as in the patch.
# ---------------------------------------------------------------------------
awk 'FILENAME == ARGV[1] { status_of[substr($0, 3)] = substr($0, 1, 1); next }
     FILENAME == ARGV[2] { if (FNR % 2 == 1) new_path = $0; else old_path_of[new_path] = $0; next }
     { print status_of[$0] "\t" $0 "\t" old_path_of[$0] }' "$CHANGE_LINES" "$RENAMES" "$SELECTED" >"$WORK_DIR/hunk-paths"

: >"$HUNKS_OUT.unsorted"
while IFS="$TAB" read -r hunk_status path old_path; do
	if [ "$hunk_status" = D ]; then
		printf '%s\t0\t0\n' "$path" >>"$HUNKS_OUT.unsorted"
		continue
	fi
	if [ "$hunk_status" = U ]; then
		diff_status=0
		# shellcheck disable=SC2086  # DIFF_OPTS is a fixed list of option words, split on purpose
		repo_git diff --no-index -U0 $DIFF_OPTS -- /dev/null "$path" >"$WORK_DIR/file-hunks" || diff_status=$?
		if [ "$diff_status" -gt 1 ]; then
			error "git diff --no-index failed for an untracked file in $TOP (exit $diff_status)"
			exit 1
		fi
	else
		# shellcheck disable=SC2086  # DIFF_OPTS is a fixed list of option words, split on purpose
		repo_git diff -U0 $DIFF_OPTS -M --no-relative "$DIFF_BASE" ${DIFF_TARGET:+"$DIFF_TARGET"} -- \
			${old_path:+"$old_path"} "$path" >"$WORK_DIR/file-hunks" || {
			error "git diff -U0 failed in $TOP"
			exit 1
		}
	fi
	# "@@ -a,b +start,count @@": count 0 is a pure deletion, anchored at the
	# line before it (at least line 1); a binary change has no lines.
	HUNK_PATH=$path awk '
		/^Binary files / { binary = 1 }
		/^@@ / {
			split(substr($3, 2), range, ",")
			start = range[1] + 0
			count = (2 in range) ? range[2] + 0 : 1
			if (count == 0) { if (start < 1) start = 1; end = start } else end = start + count - 1
			printf "%s\t%d\t%d\n", ENVIRON["HUNK_PATH"], start, end
		}
		END { if (binary) printf "%s\t0\t0\n", ENVIRON["HUNK_PATH"] }
	' "$WORK_DIR/file-hunks" >>"$HUNKS_OUT.unsorted"
done <"$WORK_DIR/hunk-paths"
sort -t "$TAB" -k1,1 -k2,2n -k3,3n "$HUNKS_OUT.unsorted" >"$HUNKS_OUT"

FILE_COUNT=$(wc -l <"$FILES_OUT" | tr -d ' ')

# ---------------------------------------------------------------------------
# Publish: each output renamed into place, so a reader never sees a partial
# file.
# ---------------------------------------------------------------------------
for output_name in changes.txt diff-files.txt diff-files.tsv diff-hunks.tsv diff.patch; do
	if ! mv -f "$WORK_DIR/$output_name" "$ABS_OUT_DIR/$output_name"; then
		error "failed to publish $ABS_OUT_DIR/$output_name"
		exit 1
	fi
done

printf 'DIFF_PATCH=%s\n' "$ABS_OUT_DIR/diff.patch"
printf 'DIFF_FILES=%s\n' "$ABS_OUT_DIR/diff-files.txt"
printf 'DIFF_FILES_TSV=%s\n' "$ABS_OUT_DIR/diff-files.tsv"
printf 'DIFF_HUNKS=%s\n' "$ABS_OUT_DIR/diff-hunks.tsv"
printf 'DIFF_CHANGES=%s\n' "$ABS_OUT_DIR/changes.txt"
printf 'DIFF_BASE=%s\n' "$DIFF_BASE"
printf 'DIFF_BASE_REF=%s\n' "$DIFF_BASE_REF"
printf 'DIFF_BASE_FROM=%s\n' "$DIFF_BASE_FROM"
printf 'DIFF_FILE_COUNT=%s\n' "$FILE_COUNT"
printf 'DIFF_SCOPE=%s\n' "$DIFF_SCOPE"
exit 0
