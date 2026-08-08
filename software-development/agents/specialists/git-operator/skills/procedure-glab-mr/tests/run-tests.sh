#!/usr/bin/env sh
#
# run-tests.sh — self-contained, zero-dependency POSIX test harness for the
#                procedure-glab-mr script suite (find-mr.sh, create-mr.sh,
#                update-mr.sh).
#
# WHY a hand-rolled harness (not bats): the whole point of this suite is
# "runs on any machine with no dependencies". Requiring bats-core would
# contradict that. This harness needs only a POSIX sh plus the coreutils that
# already ship on macOS (BSD) and Linux (GNU). Mirrors the sibling
# procedure-gh-pr test harness exactly (same stub shape, same assertion
# helpers) — see that skill's tests/run-tests.sh for the original design notes.
#
# What it does:
#   * Builds an isolated PATH "toolbox" of symlinks to only the real tools the
#     scripts need (mktemp, grep, sed, awk, ...) PLUS a STUB `glab` so no test
#     ever touches a real project, a real account, or the network. The glab stub
#     lives in its OWN dir that tests opt into, so "glab absent" is exercised
#     for real (by leaving that dir off PATH).
#   * The glab stub is fully env-driven: tests set GLAB_STUB_* variables to
#     script `glab auth status`, `mr list`/`create`/`update`, and their return
#     codes — so every deterministic branch is covered without a real `glab`.
#   * The stub logs argv ONE TOKEN PER LINE (between ARGV_BEGIN/ARGV_END
#     markers), never space-joined — a joined "--title a b" string cannot be
#     told apart from three separate tokens (a word-splitting regression), but a
#     token-per-line log can, and that distinction is exactly what several
#     assertions below rely on.
#   * The MR DESCRIPTION is captured TWICE, on purpose. This suite's scripts do
#     not pass a description PATH (glab has no --description-file), they pass the
#     file's bytes as the argv VALUE right after `--description` — so:
#       (a) a marker block in the argv log (DESCRIPTION_VALUE_START/END) mirrors
#           the gh-pr harness's BODY_FILE_CONTENTS_START/END and keeps failures
#           readable, and
#       (b) GLAB_STUB_DESC_FILE gets a raw, byte-exact copy of that same value,
#           because a marker block cannot be diffed byte-for-byte (the newline
#           that terminates the END marker is indistinguishable from a trailing
#           newline in the value itself — and preserving exactly that trailing
#           newline is one of the properties under test).
#   * Everything runs under `env -i` with an isolated HOME + TMPDIR and is
#     cleaned up on exit.
#
# STUB-ONLY CAVEAT (read this if a real `glab` release ever changes behavior):
#   These tests are entirely stub-driven — no real `glab` runs here, ever. The
#   `glab mr` flag spellings this suite relies on (list: --repo/--source-branch/
#   --output/--jq, open-by-default with NO --state flag; create: --source-branch/
#   --target-branch/--title/--description/--draft/--reviewer/--label/--assignee/
#   --yes and the ABSENCE of a --description-file; update: positional <id> +
#   --title/--description/--target-branch/--label/--unlabel/--assignee/
#   --reviewer/--yes, with '+'/'!' prefixes for add/remove) were all verified
#   against a real `glab mr … --help` at BUILD time (glab 1.112.0), not by this
#   harness — the stub simply echoes back whatever the scripts pass it, so it
#   cannot detect a real `glab` release drifting from that contract. Catching a
#   real-glab contract drift needs an occasional real-glab smoke check against a
#   scratch project — deliberately out of scope for this harness, which exists
#   to run anywhere with zero dependencies (see above).
#
# ONE PLATFORM-DEPENDENT CASE: the ~300KB description case characterizes the
#   argv/E2BIG boundary, which differs between macOS (~1MB for the whole argv
#   block) and Linux (128KB for a SINGLE argument, MAX_ARG_STRLEN). It asserts
#   that the script either succeeds cleanly or fails through its OWN diagnostic —
#   never that one specific outcome happens — and both branches contribute the
#   same number of checks, so the suite total does not move with the platform.
#
# Usage:  sh run-tests.sh              # run all tests
#         VERBOSE=1 sh run-tests.sh
#         (also runs green under dash: dash run-tests.sh)
#
# Exit 0 = all passed, 1 = one or more failed.
#
set -eu

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPTS_DIR=$(cd "$TESTS_DIR/../scripts" && pwd)
FINDMR="$SCRIPTS_DIR/find-mr.sh"
CREATEMR="$SCRIPTS_DIR/create-mr.sh"
UPDATEMR="$SCRIPTS_DIR/update-mr.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/glab-mr-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"      # real tools (glab is NEVER here)
GLABDIR="$WORK/glabbin"      # glab stub (only when a test opts in)
mkdir -p "$TOOLBOX" "$GLABDIR" "$WORK/home"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Isolated PATH toolbox: symlink only the real tools we need. glab is NEVER here.
# ---------------------------------------------------------------------------
ORIG_PATH=$PATH
link_tool() {
	tp=$(PATH="$ORIG_PATH" command -v "$1" 2>/dev/null || true)
	[ -n "$tp" ] || { printf 'FATAL: required tool not found: %s\n' "$1" >&2; exit 1; }
	ln -s "$tp" "$TOOLBOX/$1"
}
#
# `git` is in the toolbox because create-mr.sh sanity-checks its --repo-dir with
# `git -C … rev-parse --is-inside-work-tree`. That is the ONLY git this suite
# exercises, and it is local-only: no remote is ever configured, contacted, or
# needed.
#
# `--is-inside-work-tree`, NOT `--git-dir`: the comment here used to name the
# latter, but that is precisely the probe create-mr.sh was CHANGED AWAY FROM —
# `rev-parse --git-dir` also succeeds in a BARE repository, which has no working
# tree, so it passed a directory the script's own diagnostic says it rejects. The
# "--repo-dir exists but is not a git working tree" case below pins the real probe;
# this comment now names it too.
for t in sh env mktemp grep sed cat diff awk rm head git; do
	link_tool "$t"
done

# ---------------------------------------------------------------------------
# --repo-dir fixtures for create-mr.sh.
#
# `glab mr create` has no host-selection flag — it resolves the GitLab host from
# the INVOKING directory's git remotes — so create-mr.sh takes a --repo-dir and
# runs glab from inside it (see that script's header). Every create-mr.sh test
# therefore needs a real git working tree to point at.
#
# A real `git init` is fine here and does NOT breach this suite's "no real glab,
# no network" rule: initializing a local repository touches nothing outside
# $WORK and never talks to GitLab. Deliberately NO remote is added — proving the
# remote points at the right host is glab's job, not this script's, so there is
# nothing about a remote for these tests to assert.
#
# GITREPO is created ONCE and reused by every create-mr.sh case (the scripts
# only read from it); NOTAREPO is a plain directory, for the "exists but is not
# a git working tree" case.
# ---------------------------------------------------------------------------
GITREPO="$WORK/source-checkout"
NOTAREPO="$WORK/not-a-git-repo"
NOSUCHDIR="$WORK/no-such-directory"
mkdir -p "$GITREPO" "$NOTAREPO"
PATH="$ORIG_PATH" git init -q "$GITREPO" >/dev/null 2>&1 \
	|| { printf 'FATAL: could not git init the --repo-dir fixture\n' >&2; exit 1; }

# ---------------------------------------------------------------------------
# glab stub — fully env-driven so tests script every deterministic branch.
#   GLAB_STUB_AUTHED=1          -> `glab auth status` succeeds (bare or --all)
#   GLAB_STUB_MR_LIST_RC=n      -> exit code for `glab mr list` (find-mr.sh AND
#                                  create-mr.sh's duplicate pre-check both call
#                                  this identical subcommand shape)
#   GLAB_STUB_MR_LIST=<nl-list> -> `glab mr list --output json --jq ...` result,
#                                  lines of "iid<TAB>web_url"
#   GLAB_STUB_MR_LIST_LOG=path  -> capture `glab mr list` argv (token-per-line)
#   GLAB_STUB_MR_LIST_CWD=path  -> record (`pwd -P`) the DIRECTORY the stub was
#                                  invoked FROM during `glab mr list`. The
#                                  duplicate pre-check must resolve the SAME
#                                  GitLab host as the create call, and glab
#                                  resolves the host from its own cwd, so "was
#                                  the pre-check run from --repo-dir too?" is a
#                                  behavioral property no argv assertion reaches.
#   GLAB_STUB_CREATE_RC=n       -> exit code for `glab mr create`
#   GLAB_STUB_CREATE_OUT=text   -> stdout for a successful `glab mr create`
#                                  (set-but-EMPTY is honored as empty output —
#                                  distinct from leaving it unset)
#   GLAB_STUB_CREATE_ERR_OUT=text -> emit text on STDERR for a successful `glab mr
#                                  create`. Exercises the scripts' "glab may print
#                                  the URL on stderr" scan, which no other stub
#                                  setting can reach (it was previously deletable
#                                  with every test still green). Combined with a
#                                  non-empty GLAB_STUB_CREATE_OUT it writes BOTH
#                                  streams, which is how the SEC-003 cases stage a
#                                  spoof on stdout against the genuine URL on
#                                  stderr; alone, stderr is the only stream.
#   GLAB_STUB_UPDATE_ERR_OUT=text -> the same, for `glab mr update`
#   GLAB_STUB_CREATE_LOG=path   -> capture argv (token-per-line) + the
#                                  --description VALUE between markers
#   GLAB_STUB_CREATE_CWD=path   -> record (`pwd -P`) the DIRECTORY the stub was
#                                  invoked FROM during `glab mr create`. This is
#                                  the only way to test create-mr.sh's --repo-dir
#                                  contract: the real `glab mr create` has no
#                                  host flag and resolves the GitLab host from
#                                  its own cwd's git remotes, so "was it run
#                                  from the right directory?" is a behavioral
#                                  property no argv assertion can reach.
#   GLAB_STUB_UPDATE_RC=n       -> exit code for `glab mr update`
#   GLAB_STUB_UPDATE_OUT=text   -> stdout for a successful `glab mr update`
#                                  (${VAR-default} semantics, as CREATE_OUT)
#   GLAB_STUB_UPDATE_LOG=path   -> capture argv + the --description VALUE
#   GLAB_STUB_DESC_FILE=path    -> byte-exact raw copy of the --description
#                                  VALUE (no markers, nothing appended)
#   GLAB_STUB_ENV_LOG=path      -> append "<subcommand> <sub> GITLAB_HOST=<value>"
#                                  for EVERY stub invocation, recording what the
#                                  script had set GITLAB_HOST to at the moment it
#                                  ran glab (literally '<unset>' when unset).
#                                  This is the ONLY way to test the
#                                  --confirmed-host contract: glab selects its
#                                  target INSTANCE from that environment variable,
#                                  so "did the write actually go to the confirmed
#                                  host?" is an ENVIRONMENT property no argv
#                                  assertion can reach — --confirmed-host must
#                                  NOT appear in the glab argv at all.
# ---------------------------------------------------------------------------
cat >"$GLABDIR/glab" <<'GLAB_STUB'
#!/usr/bin/env sh
set -eu

# Recorded FIRST, before any subcommand dispatch, so every code path below is
# covered — including the ones that exit early.
if [ -n "${GLAB_STUB_ENV_LOG:-}" ]; then
	printf '%s %s GITLAB_HOST=%s\n' "${1:-}" "${2:-}" "${GITLAB_HOST-<unset>}" >>"$GLAB_STUB_ENV_LOG"
fi

log_argv() {
	# log_argv LOGFILE "$@" — logs each argv token on its OWN line between
	# ARGV_BEGIN/ARGV_END markers. One-token-per-line (not a space-joined
	# string) so a caller can prove a value arrived as ONE argv token
	# (e.g. right after a flag) rather than being word-split into several.
	logtarget=$1
	shift
	[ -n "$logtarget" ] || return 0
	{
		printf 'ARGV_BEGIN\n'
		for a in "$@"; do
			printf '%s\n' "$a"
		done
		printf 'ARGV_END\n'
	} >>"$logtarget"
}

capture_description() {
	# capture_description LOGFILE "$@" — scans argv for the VALUE following
	# --description (glab has no --description-file, so the description arrives
	# as an argv value, not a path) and records it two ways: a marker block in
	# LOGFILE for readable assertions, and — when GLAB_STUB_DESC_FILE is set — a
	# raw byte-exact copy for a strict diff. See the harness header for why both.
	logtarget=$1
	shift
	prev=""
	for a in "$@"; do
		if [ "$prev" = "--description" ]; then
			if [ -n "$logtarget" ]; then
				{
					printf 'DESCRIPTION_VALUE_START\n'
					printf '%s' "$a"
					printf '\nDESCRIPTION_VALUE_END\n'
				} >>"$logtarget"
			fi
			if [ -n "${GLAB_STUB_DESC_FILE:-}" ]; then
				printf '%s' "$a" >"$GLAB_STUB_DESC_FILE"
			fi
		fi
		prev=$a
	done
}

case "${1:-}" in
	auth)
		case "${2:-}" in
			status)
				if [ "${GLAB_STUB_AUTHED:-0}" = "1" ]; then
					printf 'gitlab.com\n  %s Logged in to gitlab.com as Cordona (keyring)\n' '+'
					exit 0
				else
					printf 'You are not logged in to any GitLab hosts.\n' >&2
					exit 1
				fi ;;
			*) exit 0 ;;
		esac ;;
	mr)
		case "${2:-}" in
			list)
				shift 2
				log_argv "${GLAB_STUB_MR_LIST_LOG:-}" "$@"
				# `pwd -P` (physical) — see GLAB_STUB_CREATE_CWD below.
				if [ -n "${GLAB_STUB_MR_LIST_CWD:-}" ]; then
					pwd -P >"$GLAB_STUB_MR_LIST_CWD"
				fi
				if [ "${GLAB_STUB_MR_LIST_RC:-0}" != "0" ]; then
					printf 'stub: forced mr list failure\n' >&2
					exit "${GLAB_STUB_MR_LIST_RC:-1}"
				fi
				printf '%s\n' "${GLAB_STUB_MR_LIST:-}"
				exit 0 ;;
			create)
				shift 2
				log_argv "${GLAB_STUB_CREATE_LOG:-}" "$@"
				capture_description "${GLAB_STUB_CREATE_LOG:-}" "$@"
				# `pwd -P` (physical): the caller compares it against a
				# path resolved the same way, so a symlinked TMPDIR
				# (/var -> /private/var on macOS) cannot cause a
				# spurious mismatch.
				if [ -n "${GLAB_STUB_CREATE_CWD:-}" ]; then
					pwd -P >"$GLAB_STUB_CREATE_CWD"
				fi
				if [ "${GLAB_STUB_CREATE_RC:-0}" != "0" ]; then
					printf 'stub: forced create failure\n' >&2
					exit "${GLAB_STUB_CREATE_RC:-1}"
				fi
				# STDERR output: real glab decorates its create block and may put
				# part of it (including the URL) on stderr, which is why
				# create-mr.sh scans the captured stderr too. Nothing else in this
				# stub can produce that stream, so that scan is only reachable
				# through this branch.
				#
				# GLAB_STUB_CREATE_OUT may be set ALONGSIDE it, in which case BOTH
				# streams are written — the only way to stage the SEC-003 attack,
				# where a spoofed URL rides on stdout while the genuine one is on
				# stderr. Left unset (the common case), stderr is the only stream,
				# which is what the pre-existing url-on-stderr cases rely on.
				if [ -n "${GLAB_STUB_CREATE_ERR_OUT:-}" ]; then
					printf '%s\n' "$GLAB_STUB_CREATE_ERR_OUT" >&2
					if [ -n "${GLAB_STUB_CREATE_OUT:-}" ]; then
						printf '%s\n' "$GLAB_STUB_CREATE_OUT"
					fi
					exit 0
				fi
				# ${VAR-default}, NOT ${VAR:-default}: a test that sets
				# GLAB_STUB_CREATE_OUT to the EMPTY string must see empty
				# output, distinct from leaving the var unset entirely. The
				# default mimics glab's decorated create block (two lines, the
				# URL on the second) rather than gh's bare URL.
				printf '%s\n' "${GLAB_STUB_CREATE_OUT-!7 Add the export feature (feat/x)
 https://gitlab.com/group/sub/proj/-/merge_requests/7}"
				exit 0 ;;
			update)
				shift 2
				log_argv "${GLAB_STUB_UPDATE_LOG:-}" "$@"
				capture_description "${GLAB_STUB_UPDATE_LOG:-}" "$@"
				if [ "${GLAB_STUB_UPDATE_RC:-0}" != "0" ]; then
					printf 'stub: forced update failure\n' >&2
					exit "${GLAB_STUB_UPDATE_RC:-1}"
				fi
				# STDERR output (+ optional simultaneous stdout) — see
				# GLAB_STUB_CREATE_ERR_OUT above.
				if [ -n "${GLAB_STUB_UPDATE_ERR_OUT:-}" ]; then
					printf '%s\n' "$GLAB_STUB_UPDATE_ERR_OUT" >&2
					if [ -n "${GLAB_STUB_UPDATE_OUT:-}" ]; then
						printf '%s\n' "$GLAB_STUB_UPDATE_OUT"
					fi
					exit 0
				fi
				# ${VAR-default}, NOT ${VAR:-default} — see GLAB_STUB_CREATE_OUT.
				printf '%s\n' "${GLAB_STUB_UPDATE_OUT-https://gitlab.com/group/sub/proj/-/merge_requests/5}"
				exit 0 ;;
			*) exit 0 ;;
		esac ;;
	*) exit 0 ;;
esac
GLAB_STUB
chmod +x "$GLABDIR/glab"

# ---------------------------------------------------------------------------
# Runner primitives
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_FAIL=0
CUR_OUT=""
CUR_ERR=""
CUR_RC=0

# run <with_glab:0|1> [VAR=VALUE ...] <cmd> [args...]
#   Runs <cmd> under the isolated toolbox PATH (+ glab stub only when
#   with_glab=1), with an isolated HOME/TMPDIR. Leading VAR=VALUE arguments are
#   passed straight to `env` (values may contain spaces or newlines).
#   Captures stdout, stderr, exit code.
run() {
	r_glab=$1; shift
	r_path="$TOOLBOX"
	[ "$r_glab" = "1" ] && r_path="$GLABDIR:$TOOLBOX"
	set +e
	env -i \
		HOME="$WORK/home" \
		PATH="$r_path" \
		TMPDIR="$WORK" \
		"$@" >"$WORK/out" 2>"$WORK/err"
	CUR_RC=$?
	set -e
	CUR_OUT=$(cat "$WORK/out"); CUR_ERR=$(cat "$WORK/err")
	rm -f "$WORK/out" "$WORK/err"
	if [ "${VERBOSE:-0}" = "1" ]; then
		printf '    rc=%s\n' "$CUR_RC"
		printf '%s\n' "$CUR_OUT" | sed 's/^/    out| /'
		printf '%s\n' "$CUR_ERR" | sed 's/^/    err| /'
	fi
}

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; TESTS_FAIL=$((TESTS_FAIL + 1)); }

check() { TESTS_RUN=$((TESTS_RUN + 1)); if [ "$3" -eq 0 ]; then pass "$1"; else fail "$1" "$2"; fi; }

expect_rc() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$CUR_RC" -eq "$2" ]; then pass "$1"
	else fail "$1" "expected exit $2, got $CUR_RC; stderr: $CUR_ERR"; fi
}

stdout_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Fq -- "$2"; then pass "$1"
	else fail "$1" "stdout missing: $2"; fi
}

stdout_re() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Eq -- "$2"; then pass "$1"
	else fail "$1" "stdout not matching /$2/"; fi
}

stderr_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq -- "$2"; then pass "$1"
	else fail "$1" "stderr missing: $2"; fi
}

file_missing() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ ! -f "$2" ]; then pass "$1"
	else fail "$1" "file unexpectedly exists: $2"; fi
}

# argv_has_pair LOGFILE FLAG VALUE — true iff FLAG appears immediately
# followed by VALUE as two CONSECUTIVE lines inside the log's token-per-line
# ARGV_BEGIN/ARGV_END block. Proves VALUE reached glab as ONE argv token right
# after FLAG — a word-splitting regression would show as extra lines instead.
#
# SCOPED TO THE ARGV BLOCK, the same way argv_first_is is scoped via its
# ARGV_BEGIN-adjacency rule (here the scoping mechanism is an explicit in_argv
# open/close gate; there it is adjacency to the ARGV_BEGIN marker — different
# mechanisms, the same property). Scoping is what makes either sound: the SAME log
# file also holds the stub's DESCRIPTION_VALUE marker blocks, i.e. untrusted fixture
# payload bytes. An unscoped scan could be satisfied by two adjacent DESCRIPTION
# lines that merely LOOK like a flag+value pair, passing a positive assertion the
# script never actually earned (and, symmetrically, defeating a negative one).
#
# FLAG and VALUE travel through the ENVIRONMENT, not through `awk -v`, because
# `-v` assignment performs ESCAPE PROCESSING: a `\t` inside an expected value
# (this suite asserts the literal jq expression `.[] | "\(.iid)\t\(.web_url)"`)
# would silently become a real tab in awk and never match the literal backslash-t
# the script actually passed. ENVIRON does no such rewriting.
argv_has_pair() {
	ARGV_FLAG=$2 ARGV_VALUE=$3 awk '
		$0 == "ARGV_BEGIN" { in_argv = 1; want = 0; next }
		$0 == "ARGV_END"   { in_argv = 0; want = 0; next }
		in_argv != 1 { next }
		$0 == ENVIRON["ARGV_FLAG"] { want = 1; next }
		want == 1 { if ($0 == ENVIRON["ARGV_VALUE"]) { found = 1 }; want = 0 }
		END { exit(found ? 0 : 1) }
	' "$1"
}

# argv_has_token LOGFILE TOKEN — true iff TOKEN appears as a WHOLE LINE inside an
# ARGV_BEGIN/ARGV_END block. The scoped replacement for a bare
# `grep -Fxq -- 'TOKEN' logfile`, which scanned the DESCRIPTION_VALUE payload
# blocks too: an assertion that "no --draft token was passed" must not be
# defeated by a fixture whose description happens to contain a line reading
# exactly `--draft`. TOKEN travels via ENVIRON for the same no-escape-processing
# reason as argv_has_pair's.
argv_has_token() {
	ARGV_TOKEN=$2 awk '
		$0 == "ARGV_BEGIN" { in_argv = 1; next }
		$0 == "ARGV_END"   { in_argv = 0; next }
		in_argv == 1 && $0 == ENVIRON["ARGV_TOKEN"] { found = 1 }
		END { exit(found ? 0 : 1) }
	' "$1"
}

# NOTE — argv_has_pair deliberately has no multi-line variant. A description
# spans several lines in a token-per-line log, so line equality against the whole
# value is impossible there; that a description arrived BYTE-EXACT is proven
# instead by diff_description_file against the stub's raw copy, which is a
# stronger check than any argv-line comparison could be.

# argv_first_is LOGFILE VALUE — true iff VALUE is the FIRST token of the argv
# block, i.e. it was passed POSITIONALLY rather than behind a flag. This is what
# proves update-mr.sh forwards the MR iid the way `glab mr update` takes it
# ([<id>|<branch>] positional), not as an invented --mr flag.
argv_first_is() {
	awk -v value="$2" '
		$0 == "ARGV_BEGIN" { next_is_first = 1; next }
		next_is_first == 1 { if ($0 == value) { found = 1 }; next_is_first = 0 }
		END { exit(found ? 0 : 1) }
	' "$1"
}

# description_block LOGFILE — prints only the lines between the stub's
# DESCRIPTION_VALUE_START/END markers (exclusive), so an assertion can be scoped
# to the description value glab received, never to the ARGV lines.
description_block() {
	sed -n '/^DESCRIPTION_VALUE_START$/,/^DESCRIPTION_VALUE_END$/p' "$1" | sed '1d;$d'
}

# diff_description_file FIXTURE ACTUAL — strict byte-for-byte compare of the raw
# --description value glab received against the original fixture file. The
# authoritative proof that a description reached glab completely unaltered:
# evaluation, truncation, or a stripped trailing newline (which a plain
# $(cat file) WOULD cause) would all change the bytes. Writes the diff to
# $WORK/desc_diff.
diff_description_file() {
	diff -u "$1" "$2" >"$WORK/desc_diff" 2>&1
}

section() { printf '\n== %s ==\n' "$1"; }

# A real, three-segment GitLab project path (group/subgroup/project) — the shape
# that a GitHub-style OWNER/REPO validator would wrongly reject.
DEEP_PATH='cross-project-standards/git-services/test-client-application'

# ---------------------------------------------------------------------------
# Shared fixtures, created HERE rather than inside whichever section happens to
# need them first — they are consumed by SECTIONS FAR APART, so a section that
# creates one for its neighbours hundreds of lines below is a silent
# reorder/delete hazard.
#
#   dash-desc.md — a description of exactly '-', which glab reads as "open an
#                  interactive editor". Consumed by the create-mr.sh usage
#                  section AND, much later, by the update-mr.sh usage section.
# ---------------------------------------------------------------------------
printf -- '-\n' >"$WORK/dash-desc.md"

# ===========================================================================
# find-mr.sh
# ===========================================================================
section "find-mr.sh — usage / argument errors"
run 1 sh "$FINDMR" --confirmed-host gitlab.com -h
expect_rc "findmr(usage): -h -> exit 0" 0
stdout_has "findmr(usage): help text" "Usage:"

run 1 sh "$FINDMR" --confirmed-host gitlab.com --source-branch feat/x
expect_rc "findmr(missing --repo): -> exit 2" 2
stderr_has "findmr(missing --repo): diagnostic" "--repo is required"

run 1 sh "$FINDMR" --confirmed-host gitlab.com --repo g/p
expect_rc "findmr(missing --source-branch): -> exit 2" 2
stderr_has "findmr(missing --source-branch): diagnostic" "--source-branch is required"

run 1 sh "$FINDMR" --confirmed-host gitlab.com --bogus
expect_rc "findmr(unknown option): -> exit 2" 2
stderr_has "findmr(unknown option): diagnostic" "unknown option"

section "find-mr.sh — --confirmed-host is REQUIRED and pins glab's target host (SEC-001)"
# THE GAP THIS CLOSES: procedure-gitlab-auth's gate confirms an (account, HOST)
# pair with the user, but nothing used to BIND that confirmation to the actual
# glab call — glab resolved the instance from ambient state (cwd git remotes,
# config, its gitlab.com default). With two instances configured, the gate could
# confirm host A while the query ran against host B whenever the same --repo path
# resolves on both.
#
# The flag is REQUIRED, not optional, on purpose: an "optional but you really
# should pass it" middle state leaves exactly the silent-wrong-host path open.
FINDMR_ENV_LOG_MISSING="$WORK/mr-findmr-env-log-missing"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_ENV_LOG=$FINDMR_ENV_LOG_MISSING" \
	sh "$FINDMR" --repo g/p --source-branch feat/x
expect_rc "findmr(missing --confirmed-host): -> exit 2 (usage error, never a default host)" 2
stderr_has "findmr(missing --confirmed-host): diagnostic" "--confirmed-host is required"
stderr_has "findmr(missing --confirmed-host): names the gate that produces it" "procedure-gitlab-auth"
file_missing "findmr(missing --confirmed-host): glab was never invoked at all" "$FINDMR_ENV_LOG_MISSING"

run 1 "GLAB_STUB_AUTHED=1" sh "$FINDMR" --repo g/p --source-branch feat/x --confirmed-host 'https://gitlab.com'
expect_rc "findmr(scheme-qualified --confirmed-host): -> exit 2 (one spelling only)" 2
stderr_has "findmr(scheme-qualified --confirmed-host): diagnostic" "no scheme"

run 1 "GLAB_STUB_AUTHED=1" sh "$FINDMR" --repo g/p --source-branch feat/x --confirmed-host 'gitlab.com/evil'
expect_rc "findmr(path in --confirmed-host): -> exit 2" 2

# THE PINNING PROOF: a SELF-MANAGED host, deliberately NOT glab's gitlab.com
# default, so a script that ignored the flag would record something else. The host
# reaches glab through the ENVIRONMENT (GITLAB_HOST is glab's own documented
# per-invocation instance selector), which is why the stub records the environment
# rather than the argv — and why the argv must NOT carry the flag.
PINNED_HOST='gitlab.example.com:8443'
FINDMR_ENV_LOG="$WORK/mr-findmr-env-log"
FINDMR_LOG_PINNED="$WORK/mr-findmr-log-pinned"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_ENV_LOG=$FINDMR_ENV_LOG" \
	"GLAB_STUB_MR_LIST_LOG=$FINDMR_LOG_PINNED" \
	sh "$FINDMR" --repo g/p --source-branch feat/x --confirmed-host "$PINNED_HOST"
expect_rc "findmr(pinned host): -> exit 0" 0
check "findmr(pinned host): glab mr list saw GITLAB_HOST equal to --confirmed-host" \
	"expected 'mr list GITLAB_HOST=$PINNED_HOST' in the env log, got: $(cat "$FINDMR_ENV_LOG" 2>/dev/null | tr '\n' '|')" \
	"$( grep -Fxq -- "mr list GITLAB_HOST=$PINNED_HOST" "$FINDMR_ENV_LOG" && echo 0 || echo 1 )"
check "findmr(pinned host): NO glab invocation ran with GITLAB_HOST unset" \
	"at least one glab call resolved its host from ambient state instead of the confirmed one" \
	"$( grep -Fq -- 'GITLAB_HOST=<unset>' "$FINDMR_ENV_LOG" && echo 1 || echo 0 )"
check "findmr(pinned host): the auth precondition ALSO ran against the confirmed host" \
	"glab auth status resolved a different instance than the write would" \
	"$( grep -Fxq -- "auth status GITLAB_HOST=$PINNED_HOST" "$FINDMR_ENV_LOG" && echo 0 || echo 1 )"
check "findmr(pinned host): --confirmed-host is NOT forwarded into the glab argv (glab has no such flag)" \
	"--confirmed-host leaked into the glab argv" \
	"$( argv_has_token "$FINDMR_LOG_PINNED" '--confirmed-host' && echo 1 || echo 0 )"
check "findmr(pinned host): the host value is NOT forwarded as an argv token either" \
	"the confirmed host leaked into the glab argv" \
	"$( argv_has_token "$FINDMR_LOG_PINNED" "$PINNED_HOST" && echo 1 || echo 0 )"

section "find-mr.sh — the GitLab project-path validator (multi-segment aware)"
LIST_LOG_DEEP="$WORK/mr-list-log-deep"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_MR_LIST_LOG=$LIST_LOG_DEEP" \
	sh "$FINDMR" --confirmed-host gitlab.com --repo "$DEEP_PATH" --source-branch feat/x
expect_rc "findmr(3-segment path): ACCEPTED (subgroups are legal in GitLab) -> exit 0" 0
check "findmr(3-segment path): forwarded verbatim as one argv token" "deep path missing/mangled in argv" \
	"$( argv_has_pair "$LIST_LOG_DEEP" '--repo' "$DEEP_PATH" && echo 0 || echo 1 )"

run 1 sh "$FINDMR" --confirmed-host gitlab.com --repo lonelyproject --source-branch feat/x
expect_rc "findmr(single-segment path): REJECTED (a bare name is not a path) -> exit 2" 2
stderr_has "findmr(single-segment path): diagnostic" "at least one '/'"

run 1 sh "$FINDMR" --confirmed-host gitlab.com --repo 'g/..' --source-branch feat/x
expect_rc "findmr(traversal '..' segment): -> exit 2" 2
stderr_has "findmr(traversal): diagnostic" "GitLab project path"

run 1 sh "$FINDMR" --confirmed-host gitlab.com --repo 'g/../p' --source-branch feat/x
expect_rc "findmr(traversal mid-path): -> exit 2" 2

run 1 sh "$FINDMR" --confirmed-host gitlab.com --repo 'g//p' --source-branch feat/x
expect_rc "findmr(empty segment): -> exit 2" 2

run 1 sh "$FINDMR" --confirmed-host gitlab.com --repo 'g/p;id' --source-branch feat/x
expect_rc "findmr(metacharacter in path): -> exit 2" 2

section "find-mr.sh — glab absent / not authenticated"
run 0 sh "$FINDMR" --confirmed-host gitlab.com --repo g/p --source-branch feat/x
expect_rc "findmr(no-glab): -> exit 1" 1
stderr_has "findmr(no-glab): install hint" "gitlab-org/cli"

run 1 "GLAB_STUB_AUTHED=0" sh "$FINDMR" --confirmed-host gitlab.com --repo g/p --source-branch feat/x
expect_rc "findmr(unauth): -> exit 1" 1
stderr_has "findmr(unauth): diagnostic" "not authenticated"

section "find-mr.sh — hit (exactly one open MR)"
LIST_LOG1="$WORK/mr-list-log1"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=42	https://gitlab.com/group/sub/proj/-/merge_requests/42" "GLAB_STUB_MR_LIST_LOG=$LIST_LOG1" \
	sh "$FINDMR" --confirmed-host gitlab.com --repo group/sub/proj --source-branch feat/x
expect_rc "findmr(hit): -> exit 0" 0
stdout_has "findmr(hit): PM_MR_COUNT=1" "PM_MR_COUNT=1"
stdout_has "findmr(hit): PM_MR_NUMBER=42 (the iid)" "PM_MR_NUMBER=42"
stdout_has "findmr(hit): PM_MR_URL" "PM_MR_URL=https://gitlab.com/group/sub/proj/-/merge_requests/42"
check "findmr(hit): --repo passed as one token" "repo missing/misplaced in argv" \
	"$( argv_has_pair "$LIST_LOG1" '--repo' 'group/sub/proj' && echo 0 || echo 1 )"
check "findmr(hit): --source-branch passed as one token" "source-branch missing/misplaced in argv" \
	"$( argv_has_pair "$LIST_LOG1" '--source-branch' 'feat/x' && echo 0 || echo 1 )"
check "findmr(hit): --output json passed as one token" "output json missing/misplaced in argv" \
	"$( argv_has_pair "$LIST_LOG1" '--output' 'json' && echo 0 || echo 1 )"
check "findmr(hit): --jq selects .iid and .web_url" "the jq expression is missing or selects the wrong fields" \
	"$( argv_has_pair "$LIST_LOG1" '--jq' '.[] | "\(.iid)\t\(.web_url)"' && echo 0 || echo 1 )"
check "findmr(hit): NO --state flag (glab lists open MRs by default)" "a --state token was passed; glab has no such flag" \
	"$( argv_has_token "$LIST_LOG1" '--state' && echo 1 || echo 0 )"

section "find-mr.sh — glab's --jq output normalization (quoted / escaped form)"
# Defensive: if glab renders the interpolated jq string JSON-quoted with an
# escaped tab instead of gh's raw form, the row must still parse.
run 1 "GLAB_STUB_AUTHED=1" 'GLAB_STUB_MR_LIST="42\thttps://gitlab.com/group/sub/proj/-/merge_requests/42"' \
	sh "$FINDMR" --confirmed-host gitlab.com --repo group/sub/proj --source-branch feat/x
expect_rc "findmr(quoted-jq): -> exit 0" 0
stdout_has "findmr(quoted-jq): PM_MR_COUNT=1" "PM_MR_COUNT=1"
stdout_has "findmr(quoted-jq): iid recovered"  "PM_MR_NUMBER=42"
stdout_has "findmr(quoted-jq): url recovered"  "PM_MR_URL=https://gitlab.com/group/sub/proj/-/merge_requests/42"

section "find-mr.sh — miss (no open MR, count 0 is success)"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" sh "$FINDMR" --confirmed-host gitlab.com --repo g/p --source-branch feat/y
expect_rc "findmr(miss): -> exit 0 (zero is not a failure)" 0
stdout_has "findmr(miss): PM_MR_COUNT=0" "PM_MR_COUNT=0"
check "findmr(miss): no PM_MR_NUMBER line printed" "PM_MR_NUMBER was printed despite zero results" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_MR_NUMBER=' && echo 1 || echo 0 )"
check "findmr(miss): no PM_MR_URL line printed" "PM_MR_URL was printed despite zero results" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_MR_URL=' && echo 1 || echo 0 )"

section "find-mr.sh — ambiguous (2 open MRs): count reported, no number/URL fabricated"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=42	https://gitlab.com/g/p/-/merge_requests/42
43	https://gitlab.com/g/p/-/merge_requests/43" \
	sh "$FINDMR" --confirmed-host gitlab.com --repo g/p --source-branch feat/shared
expect_rc "findmr(count-2): -> exit 0 (still a clean query)" 0
stdout_has "findmr(count-2): PM_MR_COUNT=2" "PM_MR_COUNT=2"
check "findmr(count-2): no PM_MR_NUMBER line printed (only emitted when count==1)" "PM_MR_NUMBER was printed despite count=2" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_MR_NUMBER=' && echo 1 || echo 0 )"
check "findmr(count-2): no PM_MR_URL line printed (only emitted when count==1)" "PM_MR_URL was printed despite count=2" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_MR_URL=' && echo 1 || echo 0 )"
# OBS-003: a bare PM_MR_COUNT=2 left the caller nothing to act on — and this is not
# a corner case on GitLab, which allows several open MRs from ONE source branch to
# DIFFERENT targets (a backport fanning out to release branches), unlike GitHub's
# one-open-PR-per-head-branch rule. Every matching row must therefore be listed so
# the caller can pass an iid explicitly next time.
stderr_has "findmr(count-2): warns that the ambiguity is reachable and actionable" \
	"open MRs share source branch 'feat/shared'"
stderr_has "findmr(count-2): lists the FIRST matching row (iid + URL)" \
	"!42  https://gitlab.com/g/p/-/merge_requests/42"
stderr_has "findmr(count-2): lists the SECOND matching row too (not just the first)" \
	"!43  https://gitlab.com/g/p/-/merge_requests/43"

section "find-mr.sh — glab mr list itself fails"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST_RC=1" sh "$FINDMR" --confirmed-host gitlab.com --repo g/p --source-branch feat/x
expect_rc "findmr(glab-fail): -> exit 1" 1
stderr_has "findmr(glab-fail): reports failure" "glab mr list failed"

section "find-mr.sh — the READ-ONLY contract, asserted by mutation-log ABSENCE (TEST-006)"
# This script's header promises it "never writes anything". Every case above only
# ever asserted what it PRINTS, so a regression that added a `glab mr create`/
# `update` call would have left the whole suite green. Handing the stub the two
# MUTATION logs and requiring both to be ABSENT is what actually holds the promise:
# the stub only creates a log file when the matching subcommand is invoked.
FINDMR_NO_CREATE="$WORK/mr-findmr-must-not-create"
FINDMR_NO_UPDATE="$WORK/mr-findmr-must-not-update"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=42	https://gitlab.com/g/p/-/merge_requests/42" \
	"GLAB_STUB_CREATE_LOG=$FINDMR_NO_CREATE" "GLAB_STUB_UPDATE_LOG=$FINDMR_NO_UPDATE" \
	sh "$FINDMR" --confirmed-host gitlab.com --repo g/p --source-branch feat/x
expect_rc "findmr(read-only): -> exit 0" 0
stdout_has "findmr(read-only): the query really ran" "PM_MR_COUNT=1"
file_missing "findmr(read-only): glab mr create was NEVER invoked" "$FINDMR_NO_CREATE"
file_missing "findmr(read-only): glab mr update was NEVER invoked" "$FINDMR_NO_UPDATE"

# ===========================================================================
# create-mr.sh
# ===========================================================================
section "create-mr.sh — usage / argument errors"
run 1 sh "$CREATEMR" -h
expect_rc "createmr(usage): -h -> exit 0" 0
stdout_has "createmr(usage): help text" "Usage:"

MRDESC="$WORK/mr-description.md"
printf '## Summary\nDoes the thing.\n' >"$MRDESC"

run 1 sh "$CREATEMR" --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(missing --repo): -> exit 2" 2
stderr_has "createmr(missing --repo): diagnostic" "--repo is required"

run 1 sh "$CREATEMR" --repo g/p --repo-dir "$GITREPO" --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(missing --source-branch): -> exit 2" 2
stderr_has "createmr(missing --source-branch): diagnostic" "--source-branch is required"

run 1 sh "$CREATEMR" --repo g/p --repo-dir "$GITREPO" --source-branch feat/x --title t --description-file "$MRDESC"
expect_rc "createmr(missing --target-branch): -> exit 2" 2
stderr_has "createmr(missing --target-branch): diagnostic" "--target-branch is required"

run 1 sh "$CREATEMR" --repo g/p --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --description-file "$MRDESC"
expect_rc "createmr(missing --title): -> exit 2" 2
stderr_has "createmr(missing --title): diagnostic" "--title is required"

run 1 sh "$CREATEMR" --repo g/p --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t
expect_rc "createmr(missing --description-file): -> exit 2" 2
stderr_has "createmr(missing --description-file): diagnostic" "--description-file is required"

run 1 sh "$CREATEMR" --repo g/p --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$WORK/does-not-exist"
expect_rc "createmr(nonexistent description-file): -> exit 2" 2
stderr_has "createmr(nonexistent description-file): diagnostic" "does not exist or is not readable"

: >"$WORK/empty-desc.md"
run 1 sh "$CREATEMR" --repo g/p --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$WORK/empty-desc.md"
expect_rc "createmr(empty description-file): -> exit 2" 2
stderr_has "createmr(empty description-file): diagnostic" "is empty"

run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_CREATE_LOG=$WORK/never-created" \
	sh "$CREATEMR" --repo g/p --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$WORK/dash-desc.md"
expect_rc "createmr(description is literally '-'): -> exit 2 (glab would open an editor and hang)" 2
stderr_has "createmr('-' guard): explains the editor hazard" "interactive editor"
file_missing "createmr('-' guard): glab mr create never invoked" "$WORK/never-created"

run 1 sh "$CREATEMR" --repo lonelyproject --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(single-segment path): -> exit 2" 2
stderr_has "createmr(single-segment path): diagnostic" "at least one '/'"

run 1 sh "$CREATEMR" --repo 'g/..' --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(traversal path): -> exit 2" 2

run 1 sh "$CREATEMR" --bogus
expect_rc "createmr(unknown option): -> exit 2" 2
stderr_has "createmr(unknown option): diagnostic" "unknown option"

section "create-mr.sh — --repo-dir validation (glab resolves the host from the invoking dir)"
# --repo-dir is REQUIRED because `glab mr create` has no host-selection flag: it
# reads the GitLab host from the invoking directory's git remotes. A missing or
# bogus path must fail here, as a usage error, rather than surfacing later as a
# confusing failure from deep inside glab.
CREATE_LOG_NO_DIR="$WORK/mr-create-log-no-repo-dir"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_CREATE_LOG=$CREATE_LOG_NO_DIR" \
	sh "$CREATEMR" --repo g/p --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(missing --repo-dir): -> exit 2" 2
stderr_has "createmr(missing --repo-dir): diagnostic" "--repo-dir is required"
file_missing "createmr(missing --repo-dir): glab mr create never invoked" "$CREATE_LOG_NO_DIR"

CREATE_LOG_BAD_DIR="$WORK/mr-create-log-bad-repo-dir"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_CREATE_LOG=$CREATE_LOG_BAD_DIR" \
	sh "$CREATEMR" --repo g/p --repo-dir "$NOSUCHDIR" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(--repo-dir does not exist): -> exit 2" 2
stderr_has "createmr(--repo-dir does not exist): diagnostic" "does not exist or is not a directory"
file_missing "createmr(--repo-dir does not exist): glab mr create never invoked" "$CREATE_LOG_BAD_DIR"

CREATE_LOG_NOT_GIT="$WORK/mr-create-log-not-a-git-repo"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_CREATE_LOG=$CREATE_LOG_NOT_GIT" \
	sh "$CREATEMR" --repo g/p --repo-dir "$NOTAREPO" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(--repo-dir exists but is not a git working tree): -> exit 2" 2
stderr_has "createmr(--repo-dir not a git tree): diagnostic names the cause" "is not a git working tree"
stderr_has "createmr(--repo-dir not a git tree): diagnostic names the offending path" "$NOTAREPO"
file_missing "createmr(--repo-dir not a git tree): glab mr create never invoked" "$CREATE_LOG_NOT_GIT"

run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" \
	sh "$CREATEMR" --repo g/p --repo-dir "$MRDESC" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(--repo-dir is a FILE, not a directory): -> exit 2" 2
stderr_has "createmr(--repo-dir is a file): diagnostic" "does not exist or is not a directory"

# --repo-dir given LAST with nothing after it: need_arg's "requires an argument"
# path. (A following flag is NOT detectable as a missing value here — need_arg
# only rejects an absent/empty one, exactly as every other flag in this suite
# behaves; that shared limitation is not specific to --repo-dir.)
run 1 sh "$CREATEMR" --repo g/p --source-branch feat/x --target-branch main --title t --description-file "$MRDESC" --repo-dir
expect_rc "createmr(--repo-dir with no value): -> exit 2" 2
stderr_has "createmr(--repo-dir with no value): diagnostic" "option --repo-dir requires an argument"

section "create-mr.sh — glab absent / not authenticated (fail-closed)"
run 0 sh "$CREATEMR" --repo g/p --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(no-glab): -> exit 1" 1

run 1 "GLAB_STUB_AUTHED=0" sh "$CREATEMR" --repo g/p --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(unauth): -> exit 1" 1
stderr_has "createmr(unauth): diagnostic" "not authenticated"

section "create-mr.sh — duplicate-exists pre-check refuses to create (no create attempted)"
CREATE_LOG1="$WORK/mr-create-log1"
PRECHECK_LOG1="$WORK/mr-precheck-log1"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=42	https://gitlab.com/group/sub/proj/-/merge_requests/42" "GLAB_STUB_CREATE_LOG=$CREATE_LOG1" \
	"GLAB_STUB_MR_LIST_LOG=$PRECHECK_LOG1" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(duplicate): -> exit 1" 1
stderr_has "createmr(duplicate): names the existing MR URL" "https://gitlab.com/group/sub/proj/-/merge_requests/42"
stderr_has "createmr(duplicate): points at update-mr.sh" "update-mr.sh"
file_missing "createmr(duplicate): glab mr create never invoked" "$CREATE_LOG1"
# TEST-001: the pre-check's OWN argv, asserted here and not merely assumed to
# match find-mr.sh's. The two scripts run the identical `glab mr list` query but
# BUILD it independently (each is standalone by design), so find-mr.sh's
# assertions cover none of create-mr.sh's copy — a pre-check that silently
# queried the wrong branch, or dropped the machine-readable output flags, would
# clear the duplicate guard against nothing at all and still pass every case here.
check "createmr(duplicate): the pre-check queried THIS project" "pre-check --repo missing/mangled in argv" \
	"$( argv_has_pair "$PRECHECK_LOG1" '--repo' 'group/sub/proj' && echo 0 || echo 1 )"
check "createmr(duplicate): the pre-check queried THIS source branch" "pre-check --source-branch missing/mangled in argv" \
	"$( argv_has_pair "$PRECHECK_LOG1" '--source-branch' 'feat/x' && echo 0 || echo 1 )"
check "createmr(duplicate): the pre-check asked for --output json" "pre-check output format missing from argv" \
	"$( argv_has_pair "$PRECHECK_LOG1" '--output' 'json' && echo 0 || echo 1 )"
check "createmr(duplicate): the pre-check's --jq selects .iid and .web_url" "pre-check jq expression missing or selecting the wrong fields" \
	"$( argv_has_pair "$PRECHECK_LOG1" '--jq' '.[] | "\(.iid)\t\(.web_url)"' && echo 0 || echo 1 )"
check "createmr(duplicate): the pre-check passes NO --state flag (glab lists open MRs by default)" \
	"a --state token was passed; glab has no such flag" \
	"$( argv_has_token "$PRECHECK_LOG1" '--state' && echo 1 || echo 0 )"

section "create-mr.sh — the duplicate refusal lists EVERY matching MR, not just the first (OBS-003)"
# GitLab allows several open MRs from ONE source branch to DIFFERENT targets (a
# backport fanning out to release branches), unlike GitHub's one-open-PR-per-head
# rule — so naming only row 1 silently dropped real MRs the operator has to choose
# between before deciding what to update.
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=42	https://gitlab.com/group/sub/proj/-/merge_requests/42
43	https://gitlab.com/group/sub/proj/-/merge_requests/43" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/backport --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(two duplicates): -> exit 1" 1
stderr_has "createmr(two duplicates): reports HOW MANY were found" "2 open MR(s) already exist"
stderr_has "createmr(two duplicates): lists the first row" "!42  https://gitlab.com/group/sub/proj/-/merge_requests/42"
stderr_has "createmr(two duplicates): lists the second row too (previously dropped)" "!43  https://gitlab.com/group/sub/proj/-/merge_requests/43"

section "create-mr.sh — the duplicate pre-check query itself fails"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST_RC=1" \
	sh "$CREATEMR" --repo g/p --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(precheck-fail): -> exit 1" 1
stderr_has "createmr(precheck-fail): reports failure" "failed to check for an existing MR"

section "create-mr.sh — a PRE-CHECK exit of 3 is reported as ITS OWN --repo-dir cd failure"
# create-mr.sh has TWO independent `cd "$OPT_REPO_DIR" || exit 3` subshells — one
# for the duplicate-MR pre-check, one for the create — and each has its own rc=3
# branch. The case further down covers the CREATE one (GLAB_STUB_CREATE_RC=3); this
# one covers the PRE-CHECK's, which the "precheck-fail" case above cannot reach
# because it forces rc=1, taking the generic query-failed branch instead.
#
# The two diagnostics must be DISTINGUISHABLE — they name different points in the
# script, and telling the caller which one it was is the whole reason the rc=3
# branches exist — so this asserts the pre-check's own wording AND the absence of
# the create's.
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST_RC=3" \
	sh "$CREATEMR" --repo g/p --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(precheck rc-3): -> exit 1" 1
stderr_has "createmr(precheck rc-3): the diagnostic names the PRE-CHECK, not the create" "before the duplicate-MR pre-check could run"
stderr_has "createmr(precheck rc-3): states plainly that nothing was created" "no MR was created"
check "createmr(precheck rc-3): does NOT report the create's rc=3 wording" "the pre-check's rc=3 is indistinguishable from the create's" \
	"$( printf '%s\n' "$CUR_ERR" | grep -Fq -- 'before glab mr create could run' && echo 1 || echo 0 )"
check "createmr(precheck rc-3): does NOT fall through to the generic query-failed diagnostic" "the rc=3 branch was bypassed" \
	"$( printf '%s\n' "$CUR_ERR" | grep -Fq -- 'failed to check for an existing MR' && echo 1 || echo 0 )"

section "create-mr.sh — successful create (draft, reviewers, labels, assignees)"
CREATE_LOG2="$WORK/mr-create-log2"
CREATE2_DESC_SEEN="$WORK/mr-create2-description-seen"
CREATE2_CWD_SEEN="$WORK/mr-create2-cwd-seen"
CREATE2_LIST_CWD_SEEN="$WORK/mr-create2-list-cwd-seen"
# GLAB_STUB_CREATE_OUT is spelled out (rather than left on the stub default)
# because the URL must live under the project this run actually names: the URL
# extractor requires the matched token's path to contain the confirmed --repo
# value, so a URL for some OTHER project is — correctly — not accepted as this
# MR's URL. See the "URL-shaped title" section further down for why.
DEEP_MR_URL="https://gitlab.com/$DEEP_PATH/-/merge_requests/7"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_CREATE_LOG=$CREATE_LOG2" "GLAB_STUB_DESC_FILE=$CREATE2_DESC_SEEN" \
	"GLAB_STUB_CREATE_CWD=$CREATE2_CWD_SEEN" "GLAB_STUB_MR_LIST_CWD=$CREATE2_LIST_CWD_SEEN" \
	"GLAB_STUB_CREATE_OUT=!7 Add the export feature (feat/x)
 $DEEP_MR_URL" \
	sh "$CREATEMR" --repo "$DEEP_PATH" --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title "Add the export feature" \
		--description-file "$MRDESC" --draft --reviewer "alice,bob" --label "type:feature,needs-review" --assignee carol
expect_rc "createmr(success): -> exit 0" 0
stdout_has "createmr(success): PM_MR_NUMBER parsed from the URL tail" "PM_MR_NUMBER=7"
stdout_has "createmr(success): PM_MR_URL" "PM_MR_URL=$DEEP_MR_URL"
# THE DUPLICATE-GUARD HOST CONTRACT: the pre-check must run from the SAME
# directory as the create, because glab resolves WHICH GitLab instance to talk to
# from its own cwd's git remotes. A pre-check left in the invoking cwd could clear
# against instance A while the create opened the MR on instance B — with two
# instances hosting the same project path, the guard would be silently useless.
EXPECTED_LIST_CWD=$(cd "$GITREPO" && pwd -P)
ACTUAL_LIST_CWD=$(cat "$CREATE2_LIST_CWD_SEEN" 2>/dev/null || printf '<not recorded>')
check "createmr(success): the duplicate pre-check ALSO ran from INSIDE --repo-dir (same host as the create)" \
	"expected cwd $EXPECTED_LIST_CWD, the pre-check's glab saw $ACTUAL_LIST_CWD" \
	"$( [ "$ACTUAL_LIST_CWD" = "$EXPECTED_LIST_CWD" ] && echo 0 || echo 1 )"
# THE --repo-dir CONTRACT: glab mr create must have run from INSIDE --repo-dir,
# because that is the only place it can resolve the GitLab host from (no
# host-selection flag exists). Both sides are resolved with `pwd -P` so a
# symlinked TMPDIR can't produce a false failure.
EXPECTED_CREATE_CWD=$(cd "$GITREPO" && pwd -P)
ACTUAL_CREATE_CWD=$(cat "$CREATE2_CWD_SEEN" 2>/dev/null || printf '<not recorded>')
check "createmr(success): glab mr create ran from INSIDE --repo-dir (its only host-resolution input)" \
	"expected cwd $EXPECTED_CREATE_CWD, glab saw $ACTUAL_CREATE_CWD" \
	"$( [ "$ACTUAL_CREATE_CWD" = "$EXPECTED_CREATE_CWD" ] && echo 0 || echo 1 )"
check "createmr(success): argv carries NO --hostname (glab mr create has no such flag)" "a --hostname token was passed; real glab rejects it outright" \
	"$( argv_has_token "$CREATE_LOG2" '--hostname' && echo 1 || echo 0 )"
check "createmr(success): argv carries NO --repo-dir (it is this script's flag, not glab's)" "--repo-dir leaked into the glab argv" \
	"$( argv_has_token "$CREATE_LOG2" '--repo-dir' && echo 1 || echo 0 )"
check "createmr(success): --repo (3-segment) passed as one token" "deep repo path missing/mangled in argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--repo' "$DEEP_PATH" && echo 0 || echo 1 )"
check "createmr(success): --source-branch passed as one token" "source-branch missing/misplaced in argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--source-branch' 'feat/x' && echo 0 || echo 1 )"
check "createmr(success): --target-branch passed as one token" "target-branch missing/misplaced in argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--target-branch' 'main' && echo 0 || echo 1 )"
check "createmr(success): --title passed as one token (even multi-word)" "title missing/misplaced in argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--title' 'Add the export feature' && echo 0 || echo 1 )"
check "createmr(success): --yes present (without it glab would prompt and hang)" "no --yes token in argv" \
	"$( argv_has_token "$CREATE_LOG2" '--yes' && echo 0 || echo 1 )"
check "createmr(success): --draft flag present" "no --draft token in argv" \
	"$( argv_has_token "$CREATE_LOG2" '--draft' && echo 0 || echo 1 )"
check "createmr(success): --reviewer alice passed" "reviewer alice missing from argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--reviewer' 'alice' && echo 0 || echo 1 )"
check "createmr(success): --reviewer bob passed" "reviewer bob missing from argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--reviewer' 'bob' && echo 0 || echo 1 )"
check "createmr(success): --label type:feature (from a comma-list) passed" "label missing from argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--label' 'type:feature' && echo 0 || echo 1 )"
check "createmr(success): --label needs-review (from the SAME comma-list) also passed" "second comma-split label missing from argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--label' 'needs-review' && echo 0 || echo 1 )"
check "createmr(success): --assignee carol passed" "assignee missing from argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--assignee' 'carol' && echo 0 || echo 1 )"
check "createmr(success): argv carries a --description token (glab's only description mechanism)" "no --description token in argv" \
	"$( argv_has_token "$CREATE_LOG2" '--description' && echo 0 || echo 1 )"
if diff_description_file "$MRDESC" "$CREATE2_DESC_SEEN"; then CREATE2_DIFF_RC=0; else CREATE2_DIFF_RC=1; fi
check "createmr(success): the description value glab received is byte-identical to the file" \
	"$(cat "$WORK/desc_diff" 2>/dev/null)" \
	"$CREATE2_DIFF_RC"
check "createmr(success): argv has NO --description-file token (glab has no such flag)" "a --description-file token was passed to glab" \
	"$( argv_has_token "$CREATE_LOG2" '--description-file' && echo 1 || echo 0 )"

section "create-mr.sh — RELATIVE paths survive the cd into --repo-dir (the subshell-cd contract)"
# THE REGRESSION THIS CASE EXISTS FOR: create-mr.sh confines its `cd
# "$OPT_REPO_DIR"` to a SUBSHELL at the create call. Hoisting that cd to the top
# of the script would still create MRs correctly for every OTHER case in this
# suite, because they all pass ABSOLUTE --description-file/--repo-dir paths — an
# early cd cannot misresolve a path that has no cwd dependency. So none of them
# can detect the revert.
#
# This case removes that blind spot by making BOTH paths cwd-dependent and
# invoking the script from a THIRD, unrelated directory ($WORK/elsewhere) that is
# neither the git fixture nor the description file's parent:
#   * --description-file is a BARE relative name resolvable ONLY from
#     $WORK/elsewhere. A top-level cd would look for it inside the git fixture,
#     where it does not exist -> exit 2, not 0.
#   * --repo-dir is relative to that same third cwd.
# The byte-exact description compare is the second half of the trap: it proves
# the file that was read is THIS fixture, not some same-named file that happened
# to resolve elsewhere.
ELSEWHERE="$WORK/elsewhere"
mkdir -p "$ELSEWHERE"
REL_DESC_NAME='mr-relative-description.md'
printf '## Summary\nResolved relative to the INVOKING cwd, not to --repo-dir.\n' >"$ELSEWHERE/$REL_DESC_NAME"

CREATE_LOG_REL="$WORK/mr-create-log-relative"
REL_DESC_SEEN="$WORK/mr-create-relative-description-seen"
REL_CWD_SEEN="$WORK/mr-create-relative-cwd-seen"
# `sh -c 'cd … ; exec …'` is how the third cwd is established: the runner's
# `env -i` has no portable --chdir (GNU env's -C does not exist on BSD/macOS).
# shellcheck disable=SC2016  # $1/$@ are positional params of the INNER sh -c (fed by the trailing args); expanding them here would defeat the purpose
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_CREATE_LOG=$CREATE_LOG_REL" \
	"GLAB_STUB_DESC_FILE=$REL_DESC_SEEN" "GLAB_STUB_CREATE_CWD=$REL_CWD_SEEN" \
	sh -c 'cd "$1" || exit 97; shift; exec sh "$@"' sh "$ELSEWHERE" \
		"$CREATEMR" --repo group/sub/proj --repo-dir ../source-checkout --source-branch feat/relative \
			--target-branch main --title "relative paths" --description-file "$REL_DESC_NAME"
expect_rc "createmr(relative paths): -> exit 0" 0
stdout_has "createmr(relative paths): PM_MR_URL" "PM_MR_URL=https://gitlab.com/group/sub/proj/-/merge_requests/7"
if diff_description_file "$ELSEWHERE/$REL_DESC_NAME" "$REL_DESC_SEEN"; then REL_DIFF_RC=0; else REL_DIFF_RC=1; fi
check "createmr(relative paths): the description glab received is byte-identical to the cwd-relative fixture" \
	"$(cat "$WORK/desc_diff" 2>/dev/null)" \
	"$REL_DIFF_RC"
# The other half of the contract: the cd still had to HAPPEN, just later.
EXPECTED_REL_CWD=$(cd "$GITREPO" && pwd -P)
ACTUAL_REL_CWD=$(cat "$REL_CWD_SEEN" 2>/dev/null || printf '<not recorded>')
check "createmr(relative paths): glab mr create still ran from INSIDE the relative --repo-dir" \
	"expected cwd $EXPECTED_REL_CWD, glab saw $ACTUAL_REL_CWD" \
	"$( [ "$ACTUAL_REL_CWD" = "$EXPECTED_REL_CWD" ] && echo 0 || echo 1 )"

section "create-mr.sh — a REPEATED flag accumulates as well as a comma-list does (TEST-002)"
# The documented contract is "repeatable AND/OR comma-separated", but every case
# above exercised only the comma-list half, so the repeated-occurrence half was
# untested for all three list flags. An accumulator that OVERWROTE instead of
# appending (the obvious regression in a value-returning `accumulate`) would have
# kept the whole suite green.
CREATE_LOG_REPEAT="$WORK/mr-create-log-repeated-flags"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_CREATE_LOG=$CREATE_LOG_REPEAT" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t \
		--description-file "$MRDESC" \
		--reviewer alice --reviewer bob --label first --label second --assignee carol --assignee dave
expect_rc "createmr(repeated flags): -> exit 0" 0
check "createmr(repeated flags): the FIRST --reviewer survived" "an earlier --reviewer was overwritten by the later one" \
	"$( argv_has_pair "$CREATE_LOG_REPEAT" '--reviewer' 'alice' && echo 0 || echo 1 )"
check "createmr(repeated flags): the SECOND --reviewer arrived too" "the repeated --reviewer never reached argv" \
	"$( argv_has_pair "$CREATE_LOG_REPEAT" '--reviewer' 'bob' && echo 0 || echo 1 )"
check "createmr(repeated flags): both repeated --label values arrived" "a repeated --label was lost" \
	"$( argv_has_pair "$CREATE_LOG_REPEAT" '--label' 'first' && argv_has_pair "$CREATE_LOG_REPEAT" '--label' 'second' && echo 0 || echo 1 )"
check "createmr(repeated flags): both repeated --assignee values arrived" "a repeated --assignee was lost" \
	"$( argv_has_pair "$CREATE_LOG_REPEAT" '--assignee' 'carol' && argv_has_pair "$CREATE_LOG_REPEAT" '--assignee' 'dave' && echo 0 || echo 1 )"

section "create-mr.sh — a comma-list with SPACES and EMPTY elements is trimmed and skipped (TEST-003)"
# split_csv_list trims each token and drops empty ones, but no fixture anywhere
# contained a space or an empty element, so both behaviors were unexercised: a
# dropped trim would have sent glab the label " urgent" (a different label), and a
# dropped empty-skip would have sent it an empty argv value.
CREATE_LOG_TRIM="$WORK/mr-create-log-trim"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_CREATE_LOG=$CREATE_LOG_TRIM" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t \
		--description-file "$MRDESC" --label "bug, urgent ,,"
expect_rc "createmr(csv trim): -> exit 0" 0
check "createmr(csv trim): 'bug' arrived clean" "the first token was mangled" \
	"$( argv_has_pair "$CREATE_LOG_TRIM" '--label' 'bug' && echo 0 || echo 1 )"
check "createmr(csv trim): ' urgent ' arrived TRIMMED to 'urgent'" "surrounding whitespace was not trimmed" \
	"$( argv_has_pair "$CREATE_LOG_TRIM" '--label' 'urgent' && echo 0 || echo 1 )"
check "createmr(csv trim): the UNTRIMMED ' urgent ' never reached argv" "an untrimmed token was passed to glab" \
	"$( argv_has_pair "$CREATE_LOG_TRIM" '--label' ' urgent ' && echo 1 || echo 0 )"
check "createmr(csv trim): the empty elements produced NO empty --label value" "an empty label value was passed to glab" \
	"$( argv_has_pair "$CREATE_LOG_TRIM" '--label' '' && echo 1 || echo 0 )"

section "create-mr.sh — a GLOB metacharacter in a comma-list stays literal (TEST-004)"
# split_csv_list wraps its `set -- \$value` in `set -f` precisely so the unquoted
# split cannot ALSO filename-expand. No fixture contained a glob character, so
# deleting that guard broke nothing visible — while in real use a label of '*'
# would have been replaced by the cwd's file names.
CREATE_LOG_GLOB="$WORK/mr-create-log-glob"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_CREATE_LOG=$CREATE_LOG_GLOB" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t \
		--description-file "$MRDESC" --label '*'
expect_rc "createmr(glob label): -> exit 0" 0
check "createmr(glob label): the literal '*' reached argv (it was NOT filename-expanded)" \
	"the '*' was glob-expanded against the cwd instead of staying literal" \
	"$( argv_has_pair "$CREATE_LOG_GLOB" '--label' '*' && echo 0 || echo 1 )"

section "create-mr.sh — non-draft create: --draft is ABSENT from argv"
CREATE_LOG3="$WORK/mr-create-log3"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_CREATE_LOG=$CREATE_LOG3" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/y --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(non-draft): -> exit 0" 0
check "createmr(non-draft): argv has NO --draft token (an always-draft regression would fail this)" "a --draft token was found even though --draft was never requested" \
	"$( argv_has_token "$CREATE_LOG3" '--draft' && echo 1 || echo 0 )"

section "create-mr.sh — glab mr create itself fails"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_CREATE_RC=1" \
	sh "$CREATEMR" --repo g/p --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(glab-fail): -> exit 1" 1
stderr_has "createmr(glab-fail): reports failure" "glab mr create failed"

section "create-mr.sh — glab mr create succeeds but prints NO URL"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_CREATE_OUT=" \
	sh "$CREATEMR" --repo g/p --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(no-url): -> exit 1" 1
stderr_has "createmr(no-url): diagnostic" "printed no merge-request URL"
stderr_has "createmr(no-url): warns the MR may exist anyway" "may nonetheless have been created"

section "create-mr.sh — the URL is found by SHAPE inside glab's decorated output"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_CREATE_OUT=Creating merge request for feat/x into main in group/sub/proj

!123 A title (feat/x)
 https://gitlab.example.com/deep/group/nest/proj/-/merge_requests/123" \
	sh "$CREATEMR" --repo deep/group/nest/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(decorated-output): -> exit 0" 0
stdout_has "createmr(decorated-output): iid taken from the URL tail, not the '!123' banner" "PM_MR_NUMBER=123"
stdout_has "createmr(decorated-output): self-managed URL relayed intact" "PM_MR_URL=https://gitlab.example.com/deep/group/nest/proj/-/merge_requests/123"

section "create-mr.sh — adversarial description reaches glab verbatim and inert"
ADVERSARIAL="$WORK/mr-adversarial-description.md"
cat >"$ADVERSARIAL" <<'DESC_EOF'
## Summary
Adds the CSV export.

PM_ARTIFACT_BODY
EOF
this line runs $(whoami) and `id` if the description were ever evaluated as shell
'; rm -rf /; echo '
## Test plan
- [x] unit tests

DESC_EOF
CREATE_LOG4="$WORK/mr-create-log4"
DESC_SEEN="$WORK/mr-description-seen"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_CREATE_LOG=$CREATE_LOG4" "GLAB_STUB_DESC_FILE=$DESC_SEEN" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title "adversarial description test" \
		--description-file "$ADVERSARIAL"
expect_rc "createmr(adversarial): -> exit 0 (the bytes are argv data, not shell)" 0
stdout_has "createmr(adversarial): still succeeds normally" "PM_MR_URL=https://gitlab.com/group/sub/proj/-/merge_requests/7"
if diff_description_file "$ADVERSARIAL" "$DESC_SEEN"; then DESC_DIFF_RC=0; else DESC_DIFF_RC=1; fi
check "createmr(adversarial): description reached glab BYTE-IDENTICAL, trailing newlines included" \
	"$(cat "$WORK/desc_diff" 2>/dev/null)" \
	"$DESC_DIFF_RC"
# shellcheck disable=SC2016  # the $(...) and backticks are the payload under test: they MUST stay literal here, never be expanded by this harness
check "createmr(adversarial): the metacharacter lines survived unexpanded" "shell metacharacters were expanded or dropped" \
	"$( description_block "$CREATE_LOG4" | grep -Fq -- 'runs $(whoami) and `id`' && echo 0 || echo 1 )"
check "createmr(adversarial): argv has NO --description-file token" "a --description-file token was passed to glab" \
	"$( argv_has_token "$CREATE_LOG4" '--description-file' && echo 1 || echo 0 )"

section "create-mr.sh — a URL-shaped TITLE cannot hijack the extracted URL (SEC-001)"
# THE LIVE-OBSERVED BUG THIS PINS: `glab mr create` prints the MR TITLE on the
# line BEFORE the URL, and the extractor used to take the FIRST shape-matching
# token anywhere in the captured output — so a title containing something
# URL-shaped won, and PM_MR_URL/PM_MR_NUMBER came back pointing at whatever the
# title said. Anything keyed off PM_MR_NUMBER afterwards (an update, a comment)
# would then target the wrong MR entirely.
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" \
	"GLAB_STUB_CREATE_OUT=!7 See also https://evil.example/attacker/project/-/merge_requests/1 (feat/x)
 https://gitlab.com/group/sub/proj/-/merge_requests/7" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main \
		--title "See also https://evil.example/attacker/project/-/merge_requests/1" --description-file "$MRDESC"
expect_rc "createmr(url-shaped title): -> exit 0" 0
stdout_has "createmr(url-shaped title): PM_MR_URL is the REAL URL, not the title's" "PM_MR_URL=https://gitlab.com/group/sub/proj/-/merge_requests/7"
stdout_has "createmr(url-shaped title): PM_MR_NUMBER is the REAL iid, not the title's '1'" "PM_MR_NUMBER=7"
check "createmr(url-shaped title): the attacker URL never reaches stdout" "the title's URL was relayed to the caller" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'evil.example' && echo 1 || echo 0 )"

# A title on ANOTHER PROJECT of the same host is rejected by the same rule — the
# match requires the confirmed --repo path, not merely a GitLab-looking URL.
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" \
	"GLAB_STUB_CREATE_OUT=!7 Ports https://gitlab.com/other/team/proj/-/merge_requests/999 (feat/x)
 https://gitlab.com/group/sub/proj/-/merge_requests/7" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main \
		--title "Ports https://gitlab.com/other/team/proj/-/merge_requests/999" --description-file "$MRDESC"
expect_rc "createmr(other-project URL in title): -> exit 0" 0
stdout_has "createmr(other-project URL in title): PM_MR_NUMBER is this project's iid" "PM_MR_NUMBER=7"
check "createmr(other-project URL in title): the other project's iid is never relayed" "an unrelated project's MR number was relayed" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- '999' && echo 1 || echo 0 )"

# A title that quotes the REAL URL verbatim is NOT ambiguity: identical tokens
# collapse to one candidate, so this must still succeed rather than fail closed.
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" \
	"GLAB_STUB_CREATE_OUT=!7 Supersedes https://gitlab.com/group/sub/proj/-/merge_requests/7 (feat/x)
 https://gitlab.com/group/sub/proj/-/merge_requests/7" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main \
		--title "Supersedes https://gitlab.com/group/sub/proj/-/merge_requests/7" --description-file "$MRDESC"
expect_rc "createmr(title repeats the real URL): -> exit 0 (identical tokens are one candidate)" 0
stdout_has "createmr(title repeats the real URL): PM_MR_URL still relayed" "PM_MR_URL=https://gitlab.com/group/sub/proj/-/merge_requests/7"

section "create-mr.sh — the project filter is ANCHORED to the host (SEC-002)"
# THE RESIDUAL GAP: the filter was `index($i, "/" repo "/")` — an UNANCHORED
# substring test. It accepted the project path at ANY depth under ANY host, so
# "https://attacker.example/x/group/sub/proj/-/merge_requests/5" qualified as a URL
# of THIS project. The ambiguity guard normally caught it (a genuine URL is present
# too, making 2+ candidates), but a filter must not lean on its own backstop: here
# the spoof is the ONLY shape-matching token in the output, so the guard has nothing
# to compare it against and the anchor is the only thing that can reject it.
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" \
	"GLAB_STUB_CREATE_OUT=!5 See https://attacker.example/x/group/sub/proj/-/merge_requests/5 (feat/x)" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main \
		--title "See https://attacker.example/x/group/sub/proj/-/merge_requests/5" --description-file "$MRDESC"
expect_rc "createmr(unanchored spoof, sole candidate): -> exit 1 (no URL found at all)" 1
stderr_has "createmr(unanchored spoof): reports NO URL rather than accepting the spoof" "printed no merge-request URL"
check "createmr(unanchored spoof): the attacker URL is never relayed" "an extra leading path segment let a foreign host masquerade as this project" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'attacker.example' && echo 1 || echo 0 )"

# The same rejection for a foreign host with NO extra segment: the repo path is
# right after the host, but the host itself is not this project's — which the
# anchor deliberately does NOT check, so this one is accepted as a candidate and
# the pre-existing ambiguity guard is what must fail it closed. Asserted so the
# anchor's scope stays honest: it removes the extra-segment/any-depth hole, not the
# host question.
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" \
	"GLAB_STUB_CREATE_OUT=!5 See https://evil.example/group/sub/proj/-/merge_requests/9 (feat/x)
 https://gitlab.com/group/sub/proj/-/merge_requests/5" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main \
		--title "See https://evil.example/group/sub/proj/-/merge_requests/9" --description-file "$MRDESC"
expect_rc "createmr(foreign host, no extra segment): -> exit 1 (the ambiguity guard fails it closed)" 1
stderr_has "createmr(foreign host, no extra segment): fails through the ambiguity guard" "MORE THAN ONE distinct merge-request URL"

section "create-mr.sh — TWO distinct project URLs fail CLOSED rather than guessing (SEC-001)"
# When the output really is ambiguous — two DIFFERENT MRs of THIS project — there
# is no safe way to pick one, so the script must refuse instead of relaying a
# coin flip.
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" \
	"GLAB_STUB_CREATE_OUT=!7 Replaces https://gitlab.com/group/sub/proj/-/merge_requests/4 (feat/x)
 https://gitlab.com/group/sub/proj/-/merge_requests/7" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main \
		--title "Replaces https://gitlab.com/group/sub/proj/-/merge_requests/4" --description-file "$MRDESC"
expect_rc "createmr(ambiguous URLs): -> exit 1 (fails closed, never guesses)" 1
stderr_has "createmr(ambiguous URLs): says why it refused" "MORE THAN ONE distinct merge-request URL"
stderr_has "createmr(ambiguous URLs): points at find-mr.sh to resolve it" "verify with find-mr.sh"
stderr_has "createmr(ambiguous URLs): still warns the MR may exist" "may nonetheless have been created"
check "createmr(ambiguous URLs): NO PM_MR_URL is printed" "a guessed URL was relayed despite the ambiguity" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_MR_URL=' && echo 1 || echo 0 )"
check "createmr(ambiguous URLs): NO PM_MR_NUMBER is printed" "a guessed iid was relayed despite the ambiguity" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_MR_NUMBER=' && echo 1 || echo 0 )"

section "create-mr.sh — the URL arriving ONLY on stderr still populates PM_MR_URL"
# glab decorates its create output and may write part of it (the URL included) to
# STDERR, which is why create-mr.sh scans the captured stderr as a fallback.
# Nothing else in this suite can produce that stream, so without this case the
# whole fallback could be deleted with every test still green.
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" \
	"GLAB_STUB_CREATE_ERR_OUT=!7 Add the export feature (feat/x)
 https://gitlab.com/group/sub/proj/-/merge_requests/7" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(url-on-stderr): -> exit 0" 0
stdout_has "createmr(url-on-stderr): PM_MR_URL recovered from stderr" "PM_MR_URL=https://gitlab.com/group/sub/proj/-/merge_requests/7"
stdout_has "createmr(url-on-stderr): PM_MR_NUMBER recovered from stderr" "PM_MR_NUMBER=7"

section "create-mr.sh — a spoof on stdout cannot outrank the genuine URL on stderr (SEC-003)"
# THE RESIDUAL GAP THIS PINS, and why SEC-001's fix did not already cover it: the
# extractor used to scan stdout FIRST and consult stderr only as a FALLBACK, when
# stdout had yielded nothing at all. The repo filter checks that a candidate's PATH
# contains "/<repo>/" — it does NOT check the HOST. So when glab put the real URL on
# stderr while echoing a URL-shaped TITLE on stdout, an attacker-crafted title
# carrying this project's path under a foreign host was the ONLY candidate the
# ambiguity guard ever saw (stderr was never read) and won by default — the exact
# class SEC-001 closed, reached through the one door left open.
#
# The fix pools BOTH streams before extracting, so the spoof and the genuine URL are
# seen together as 2 distinct candidates and the existing guard fails closed. Note
# the spoofed iid is 7 — the SAME as the real MR's — so nothing but the unified scan
# can tell them apart here.
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" \
	"GLAB_STUB_CREATE_OUT=!7 See also https://evil.example/group/sub/proj/-/merge_requests/7 (feat/x)" \
	"GLAB_STUB_CREATE_ERR_OUT= https://gitlab.com/group/sub/proj/-/merge_requests/7" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main \
		--title "See also https://evil.example/group/sub/proj/-/merge_requests/7" --description-file "$MRDESC"
expect_rc "createmr(stdout spoof vs stderr URL): -> exit 1 (fails closed, never guesses)" 1
stderr_has "createmr(stdout spoof vs stderr URL): both streams' candidates reached the ambiguity guard" "MORE THAN ONE distinct merge-request URL"
check "createmr(stdout spoof vs stderr URL): the attacker URL is never relayed as PM_MR_URL" "the spoofed stdout URL won because stderr was not consulted" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'evil.example' && echo 1 || echo 0 )"
check "createmr(stdout spoof vs stderr URL): NO PM_MR_URL is printed at all" "a URL was relayed despite the ambiguity" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_MR_URL=' && echo 1 || echo 0 )"
check "createmr(stdout spoof vs stderr URL): NO PM_MR_NUMBER is printed at all" "an iid was relayed despite the ambiguity" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_MR_NUMBER=' && echo 1 || echo 0 )"

# The mirror image — spoof on STDERR, genuine URL on stdout — must fail closed too:
# the pool is symmetric, so neither stream is privileged.
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" \
	"GLAB_STUB_CREATE_OUT= https://gitlab.com/group/sub/proj/-/merge_requests/7" \
	"GLAB_STUB_CREATE_ERR_OUT=note: see https://evil.example/group/sub/proj/-/merge_requests/7" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(stderr spoof vs stdout URL): -> exit 1 (the pool is symmetric)" 1
stderr_has "createmr(stderr spoof vs stdout URL): same fail-closed diagnostic" "MORE THAN ONE distinct merge-request URL"
check "createmr(stderr spoof vs stdout URL): the attacker URL is never relayed" "the spoof was accepted from stderr" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'evil.example' && echo 1 || echo 0 )"

section "create-mr.sh — a glab exit of 3 is reported as the --repo-dir cd failure"
# The rc=3 branch exists because create-mr.sh's subshell uses `cd … || exit 3` to
# tell "--repo-dir vanished, glab never ran" apart from "glab itself failed" —
# those two need different diagnostics, and the second would otherwise print an
# empty captured-stderr block. The script's own header documents the accepted
# ambiguity this case pins: a `glab mr create` that genuinely exits 3 is read as
# the cd failure (glab's documented failure code is 1).
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_CREATE_RC=3" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$MRDESC"
expect_rc "createmr(rc-3): -> exit 1" 1
stderr_has "createmr(rc-3): the distinct 'became unreachable' diagnostic, not 'glab mr create failed'" "became unreachable"
stderr_has "createmr(rc-3): states plainly that nothing was created" "no MR was created"

section "create-mr.sh — a ~300KB description (the argv/E2BIG boundary)"
# The whole description travels as ONE argv token, so it is bounded by a real OS
# limit, and that limit DIFFERS BY PLATFORM: macOS allows ~1MB for the whole argv
# block, while Linux caps a SINGLE argument at 128KB (MAX_ARG_STRLEN). This case
# is therefore a CHARACTERIZATION test, not a promise: whichever way the platform
# goes, the script must either succeed cleanly or fail with ITS OWN diagnostic —
# never crash, and never report success without a URL. Both branches assert two
# checks, so the suite's total is platform-independent.
BIG_DESC="$WORK/mr-big-description.md"
awk 'BEGIN { for (i = 0; i < 3000; i++) printf "%0100d\n", i }' >"$BIG_DESC"
BIG_DESC_SEEN="$WORK/mr-big-description-seen"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MR_LIST=" "GLAB_STUB_DESC_FILE=$BIG_DESC_SEEN" \
	sh "$CREATEMR" --repo group/sub/proj --repo-dir "$GITREPO" --source-branch feat/x --target-branch main --title t --description-file "$BIG_DESC"
if [ "$CUR_RC" -eq 0 ]; then
	stdout_has "createmr(300KB description): accepted by this platform's argv limit — URL still relayed" "PM_MR_URL=https://gitlab.com/group/sub/proj/-/merge_requests/7"
	if diff_description_file "$BIG_DESC" "$BIG_DESC_SEEN"; then BIG_DIFF_RC=0; else BIG_DIFF_RC=1; fi
	check "createmr(300KB description): all ~300KB reached glab byte-identical (no truncation)" \
		"a large description was altered or truncated on its way into argv" \
		"$BIG_DIFF_RC"
else
	expect_rc "createmr(300KB description): rejected by the OS -> exit 1, the script's own failure path" 1
	stderr_has "createmr(300KB description): reported through the script's diagnostic, not as a bare crash" "glab mr create failed"
fi

# ===========================================================================
# update-mr.sh
# ===========================================================================
section "update-mr.sh — usage / argument errors"
run 1 sh "$UPDATEMR" --confirmed-host gitlab.com -h
expect_rc "updatemr(usage): -h -> exit 0" 0
stdout_has "updatemr(usage): help text" "Usage:"

run 1 sh "$UPDATEMR" --confirmed-host gitlab.com --mr 1 --title x
expect_rc "updatemr(missing --repo): -> exit 2" 2
stderr_has "updatemr(missing --repo): diagnostic" "--repo is required"

run 1 sh "$UPDATEMR" --confirmed-host gitlab.com --repo g/p --title x
expect_rc "updatemr(missing --mr): -> exit 2" 2
stderr_has "updatemr(missing --mr): diagnostic" "--mr is required"

run 1 sh "$UPDATEMR" --confirmed-host gitlab.com --repo g/p --mr abc --title x
expect_rc "updatemr(non-numeric --mr): -> exit 2" 2
stderr_has "updatemr(non-numeric --mr): diagnostic" "positive integer"

run 1 sh "$UPDATEMR" --confirmed-host gitlab.com --repo g/p --mr 1
expect_rc "updatemr(no fields given): -> exit 2" 2
stderr_has "updatemr(no fields given): diagnostic" "at least one field to change is required"

run 1 sh "$UPDATEMR" --confirmed-host gitlab.com --repo g/p --mr 1 --description-file "$WORK/does-not-exist"
expect_rc "updatemr(nonexistent description-file): -> exit 2" 2
stderr_has "updatemr(nonexistent description-file): diagnostic" "does not exist or is not readable"

run 1 sh "$UPDATEMR" --confirmed-host gitlab.com --repo g/p --mr 1 --description-file "$WORK/dash-desc.md"
expect_rc "updatemr(description is literally '-'): -> exit 2" 2
stderr_has "updatemr('-' guard): explains the editor hazard" "interactive editor"

# TEST-007: the empty-description-file guard. create-mr.sh's IDENTICAL guard is
# tested; this one was not, so it could have been deleted here with the suite still
# green — and an empty --description would then have WIPED a real MR description.
UPDATEMR_EMPTY_LOG="$WORK/mr-update-log-empty-desc"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_LOG=$UPDATEMR_EMPTY_LOG" \
	sh "$UPDATEMR" --confirmed-host gitlab.com --repo g/p --mr 1 --description-file "$WORK/empty-desc.md"
expect_rc "updatemr(empty description-file): -> exit 2" 2
stderr_has "updatemr(empty description-file): diagnostic" "is empty"
file_missing "updatemr(empty description-file): glab mr update never invoked (the description was NOT wiped)" "$UPDATEMR_EMPTY_LOG"

section "update-mr.sh — --confirmed-host is REQUIRED and pins glab's target host (SEC-001)"
# Same gap and same mechanism as find-mr.sh's (see that section) — but here the
# consequence is an unretractable WRITE landing on the wrong instance.
UPDATEMR_ENV_LOG_MISSING="$WORK/mr-update-env-log-missing"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_ENV_LOG=$UPDATEMR_ENV_LOG_MISSING" \
	sh "$UPDATEMR" --repo g/p --mr 5 --title x
expect_rc "updatemr(missing --confirmed-host): -> exit 2 (usage error, never a default host)" 2
stderr_has "updatemr(missing --confirmed-host): diagnostic" "--confirmed-host is required"
file_missing "updatemr(missing --confirmed-host): glab was never invoked at all" "$UPDATEMR_ENV_LOG_MISSING"

run 1 "GLAB_STUB_AUTHED=1" sh "$UPDATEMR" --repo g/p --mr 5 --title x --confirmed-host 'https://gitlab.com'
expect_rc "updatemr(scheme-qualified --confirmed-host): -> exit 2" 2
stderr_has "updatemr(scheme-qualified --confirmed-host): diagnostic" "no scheme"

UPDATEMR_ENV_LOG="$WORK/mr-update-env-log"
UPDATEMR_LOG_PINNED="$WORK/mr-update-log-pinned"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_OUT=" "GLAB_STUB_ENV_LOG=$UPDATEMR_ENV_LOG" \
	"GLAB_STUB_UPDATE_LOG=$UPDATEMR_LOG_PINNED" \
	sh "$UPDATEMR" --repo g/p --mr 5 --title x --confirmed-host 'gitlab.example.com:8443'
expect_rc "updatemr(pinned host): -> exit 0" 0
check "updatemr(pinned host): glab mr update saw GITLAB_HOST equal to --confirmed-host" \
	"expected 'mr update GITLAB_HOST=gitlab.example.com:8443' in the env log, got: $(cat "$UPDATEMR_ENV_LOG" 2>/dev/null | tr '\n' '|')" \
	"$( grep -Fxq -- 'mr update GITLAB_HOST=gitlab.example.com:8443' "$UPDATEMR_ENV_LOG" && echo 0 || echo 1 )"
check "updatemr(pinned host): NO glab invocation ran with GITLAB_HOST unset" \
	"at least one glab call resolved its host from ambient state instead of the confirmed one" \
	"$( grep -Fq -- 'GITLAB_HOST=<unset>' "$UPDATEMR_ENV_LOG" && echo 1 || echo 0 )"
check "updatemr(pinned host): --confirmed-host is NOT forwarded into the glab argv" \
	"--confirmed-host leaked into the glab argv" \
	"$( argv_has_token "$UPDATEMR_LOG_PINNED" '--confirmed-host' && echo 1 || echo 0 )"

run 1 sh "$UPDATEMR" --confirmed-host gitlab.com --repo lonelyproject --mr 1 --title x
expect_rc "updatemr(single-segment path): -> exit 2" 2
stderr_has "updatemr(single-segment path): diagnostic" "at least one '/'"

run 1 sh "$UPDATEMR" --confirmed-host gitlab.com --repo 'g/..' --mr 1 --title x
expect_rc "updatemr(traversal path): -> exit 2" 2

run 1 sh "$UPDATEMR" --confirmed-host gitlab.com --bogus
expect_rc "updatemr(unknown option): -> exit 2" 2
stderr_has "updatemr(unknown option): diagnostic" "unknown option"

section "update-mr.sh — glab absent / not authenticated"
run 0 sh "$UPDATEMR" --confirmed-host gitlab.com --repo g/p --mr 1 --title x
expect_rc "updatemr(no-glab): -> exit 1" 1

run 1 "GLAB_STUB_AUTHED=0" sh "$UPDATEMR" --confirmed-host gitlab.com --repo g/p --mr 1 --title x
expect_rc "updatemr(unauth): -> exit 1" 1
stderr_has "updatemr(unauth): diagnostic" "not authenticated"

section "update-mr.sh — description NOT clobbered when --description-file omitted"
UPDATE_LOG1="$WORK/mr-update-log1"
# GLAB_STUB_UPDATE_OUT is spelled out (rather than left on the stub default)
# because the URL must live under the project this run names: the extractor
# requires the matched token's path to contain the confirmed --repo value.
DEEP_MR_URL_5="https://gitlab.com/$DEEP_PATH/-/merge_requests/5"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_LOG=$UPDATE_LOG1" "GLAB_STUB_UPDATE_OUT=$DEEP_MR_URL_5" \
	sh "$UPDATEMR" --confirmed-host gitlab.com --repo "$DEEP_PATH" --mr 5 --title "renamed" --target-branch develop \
		--add-label "bug,urgent" --remove-label stale \
		--add-assignee dave --remove-assignee erin \
		--add-reviewer alice --remove-reviewer bob
expect_rc "updatemr(no-desc-clobber): -> exit 0" 0
stdout_has "updatemr(no-desc-clobber): PM_MR_URL" "PM_MR_URL=$DEEP_MR_URL_5"
check "updatemr(no-desc-clobber): argv has NO --description token" "a --description token was found even though none was given — this would CLOBBER the description" \
	"$( argv_has_token "$UPDATE_LOG1" '--description' && echo 1 || echo 0 )"
check "updatemr(no-desc-clobber): argv has NO --description-file token either" "a --description-file token was found" \
	"$( argv_has_token "$UPDATE_LOG1" '--description-file' && echo 1 || echo 0 )"
check "updatemr(no-desc-clobber): the iid is passed POSITIONALLY (glab takes [<id>|<branch>])" "the MR iid was not the first argv token" \
	"$( argv_first_is "$UPDATE_LOG1" '5' && echo 0 || echo 1 )"
check "updatemr(no-desc-clobber): --yes present (without it glab would prompt and hang)" "no --yes token in argv" \
	"$( argv_has_token "$UPDATE_LOG1" '--yes' && echo 0 || echo 1 )"
check "updatemr(no-desc-clobber): --repo (3-segment) passed as one token" "deep repo path missing/mangled in argv" \
	"$( argv_has_pair "$UPDATE_LOG1" '--repo' "$DEEP_PATH" && echo 0 || echo 1 )"
check "updatemr(no-desc-clobber): --title passed as one token" "title missing/misplaced in argv" \
	"$( argv_has_pair "$UPDATE_LOG1" '--title' 'renamed' && echo 0 || echo 1 )"
check "updatemr(no-desc-clobber): --target-branch passed as one token" "target-branch missing/misplaced in argv" \
	"$( argv_has_pair "$UPDATE_LOG1" '--target-branch' 'develop' && echo 0 || echo 1 )"
check "updatemr(no-desc-clobber): --add-label bug -> glab --label bug" "add-label bug missing from argv" \
	"$( argv_has_pair "$UPDATE_LOG1" '--label' 'bug' && echo 0 || echo 1 )"
check "updatemr(no-desc-clobber): --add-label urgent -> glab --label urgent" "add-label urgent missing from argv" \
	"$( argv_has_pair "$UPDATE_LOG1" '--label' 'urgent' && echo 0 || echo 1 )"
check "updatemr(no-desc-clobber): --remove-label stale -> glab --unlabel stale (NOT --remove-label)" "remove-label was not translated to glab's --unlabel" \
	"$( argv_has_pair "$UPDATE_LOG1" '--unlabel' 'stale' && echo 0 || echo 1 )"
check "updatemr(no-desc-clobber): --add-assignee dave -> glab --assignee +dave" "add-assignee was not '+'-prefixed (glab would REPLACE the set)" \
	"$( argv_has_pair "$UPDATE_LOG1" '--assignee' '+dave' && echo 0 || echo 1 )"
check "updatemr(no-desc-clobber): --remove-assignee erin -> glab --assignee !erin" "remove-assignee was not '!'-prefixed" \
	"$( argv_has_pair "$UPDATE_LOG1" '--assignee' '!erin' && echo 0 || echo 1 )"
check "updatemr(no-desc-clobber): --add-reviewer alice -> glab --reviewer +alice" "add-reviewer was not '+'-prefixed (glab would REPLACE the set)" \
	"$( argv_has_pair "$UPDATE_LOG1" '--reviewer' '+alice' && echo 0 || echo 1 )"
check "updatemr(no-desc-clobber): --remove-reviewer bob -> glab --reviewer !bob" "remove-reviewer was not '!'-prefixed" \
	"$( argv_has_pair "$UPDATE_LOG1" '--reviewer' '!bob' && echo 0 || echo 1 )"
check "updatemr(no-desc-clobber): no removal value starts with '-' (glab would read it as a flag)" "a '-'-prefixed removal value was passed" \
	"$( argv_has_token "$UPDATE_LOG1" '-erin' && echo 1 || echo 0 )"

section "update-mr.sh — description IS replaced when --description-file is given"
UDESC="$WORK/mr-update-description.md"
printf '## Updated\nNew content.\n\n' >"$UDESC"
UPDATE_LOG2="$WORK/mr-update-log2"
UDESC_SEEN="$WORK/mr-update-description-seen"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_LOG=$UPDATE_LOG2" "GLAB_STUB_DESC_FILE=$UDESC_SEEN" \
	sh "$UPDATEMR" --confirmed-host gitlab.com --repo group/sub/proj --mr 5 --description-file "$UDESC"
expect_rc "updatemr(desc-replace): -> exit 0" 0
check "updatemr(desc-replace): argv HAS a --description token" "expected a --description token in argv" \
	"$( argv_has_token "$UPDATE_LOG2" '--description' && echo 0 || echo 1 )"
check "updatemr(desc-replace): the description value is relayed" "description content missing" \
	"$( description_block "$UPDATE_LOG2" | grep -Fq -- '## Updated' && echo 0 || echo 1 )"
if diff_description_file "$UDESC" "$UDESC_SEEN"; then UDESC_DIFF_RC=0; else UDESC_DIFF_RC=1; fi
check "updatemr(desc-replace): description byte-identical, trailing blank line preserved" \
	"$(cat "$WORK/desc_diff" 2>/dev/null)" \
	"$UDESC_DIFF_RC"

section "update-mr.sh — glab mr update itself fails"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_RC=1" sh "$UPDATEMR" --confirmed-host gitlab.com --repo g/p --mr 1 --title x
expect_rc "updatemr(glab-fail): -> exit 1" 1
stderr_has "updatemr(glab-fail): reports failure" "glab mr update failed"

section "update-mr.sh — successful update with NO URL returned (courtesy contract)"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_OUT=" sh "$UPDATEMR" --confirmed-host gitlab.com --repo g/p --mr 1 --title x
expect_rc "updatemr(empty-url): -> exit 0 (the URL is a courtesy, not proof of success)" 0
stdout_re "updatemr(empty-url): PM_MR_URL is empty" '^PM_MR_URL=$'

section "update-mr.sh — a URL-shaped TITLE cannot hijack PM_MR_URL (SEC-001)"
# Same live-observed defect as create-mr.sh's, same fix: the candidate must carry
# the confirmed --repo path, and the dedup leaves at most one line per distinct URL,
# so the single survivor is taken outright rather than picked from several
# occurrences.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_UPDATE_OUT=!5 See https://evil.example/attacker/project/-/merge_requests/1 (feat/x)
 https://gitlab.com/group/sub/proj/-/merge_requests/5" \
	sh "$UPDATEMR" --confirmed-host gitlab.com --repo group/sub/proj --mr 5 --title "See https://evil.example/attacker/project/-/merge_requests/1"
expect_rc "updatemr(url-shaped title): -> exit 0" 0
stdout_has "updatemr(url-shaped title): PM_MR_URL is the REAL URL" "PM_MR_URL=https://gitlab.com/group/sub/proj/-/merge_requests/5"
check "updatemr(url-shaped title): the attacker URL never reaches stdout" "the title's URL was relayed to the caller" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'evil.example' && echo 1 || echo 0 )"

section "update-mr.sh — TWO distinct project URLs leave PM_MR_URL EMPTY + warn (SEC-001)"
# The DELIBERATE difference from create-mr.sh: the edit itself already succeeded
# and PM_MR_URL is a documented courtesy field, so ambiguity must not invent a
# failure exit — it leaves the key empty (never a guess) and says so on stderr.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_UPDATE_OUT=!5 Replaces https://gitlab.com/group/sub/proj/-/merge_requests/4 (feat/x)
 https://gitlab.com/group/sub/proj/-/merge_requests/5" \
	sh "$UPDATEMR" --confirmed-host gitlab.com --repo group/sub/proj --mr 5 --title "Replaces https://gitlab.com/group/sub/proj/-/merge_requests/4"
expect_rc "updatemr(ambiguous URLs): -> exit 0 (the update DID happen)" 0
stdout_re "updatemr(ambiguous URLs): PM_MR_URL is empty, never guessed" '^PM_MR_URL=$'
stderr_has "updatemr(ambiguous URLs): warns why the field is empty" "MORE THAN ONE distinct merge-request URL"
stderr_has "updatemr(ambiguous URLs): points at find-mr.sh" "find-mr.sh"

section "update-mr.sh — the URL arriving ONLY on stderr still populates PM_MR_URL"
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_UPDATE_ERR_OUT=https://gitlab.com/group/sub/proj/-/merge_requests/5" \
	sh "$UPDATEMR" --confirmed-host gitlab.com --repo group/sub/proj --mr 5 --title x
expect_rc "updatemr(url-on-stderr): -> exit 0" 0
stdout_has "updatemr(url-on-stderr): PM_MR_URL recovered from stderr" "PM_MR_URL=https://gitlab.com/group/sub/proj/-/merge_requests/5"

section "update-mr.sh — a spoof on stdout cannot outrank the genuine URL on stderr (SEC-003)"
# Same residual gap as create-mr.sh's (see that section for the full mechanism):
# stdout was scanned FIRST and stderr only as a fallback, so a title-borne URL
# carrying THIS project's path under a foreign host won unopposed whenever glab put
# the real URL on stderr. Both streams now form ONE pool. The spoofed iid is 5 — the
# same MR this run is updating — so the iid cross-check below cannot be what saves
# this case; only the unified scan can.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_UPDATE_OUT=!5 See https://evil.example/group/sub/proj/-/merge_requests/5 (feat/x)" \
	"GLAB_STUB_UPDATE_ERR_OUT= https://gitlab.com/group/sub/proj/-/merge_requests/5" \
	sh "$UPDATEMR" --confirmed-host gitlab.com --repo group/sub/proj --mr 5 --title "See https://evil.example/group/sub/proj/-/merge_requests/5"
expect_rc "updatemr(stdout spoof vs stderr URL): -> exit 0 (the update DID happen)" 0
stdout_re "updatemr(stdout spoof vs stderr URL): PM_MR_URL is empty, never the spoof" '^PM_MR_URL=$'
stderr_has "updatemr(stdout spoof vs stderr URL): both streams' candidates reached the ambiguity guard" "MORE THAN ONE distinct merge-request URL"
check "updatemr(stdout spoof vs stderr URL): the attacker URL never reaches stdout" "the spoofed stdout URL won because stderr was not consulted" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'evil.example' && echo 1 || echo 0 )"

section "update-mr.sh — a URL naming a DIFFERENT iid than --mr is refused (SEC-003)"
# The second half of the SEC-003 fix, available ONLY to the scripts that were handed
# the iid: --mr was validated as a positive integer up front, so it is authoritative
# ground truth the extraction can be cross-checked against. Here the sole candidate
# is a perfectly well-formed URL — right host, right project path — for MR !4, while
# the MR actually updated is !5. Without the cross-check the pool holds exactly one
# candidate, so the ambiguity guard has nothing to catch and !4's URL is relayed as
# if it were this edit's. The mismatch is treated as "no URL found": empty key, warn,
# still exit 0 (the courtesy contract forbids failing a completed edit).
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_UPDATE_OUT=!5 Replaces https://gitlab.com/group/sub/proj/-/merge_requests/4 (feat/x)" \
	sh "$UPDATEMR" --confirmed-host gitlab.com --repo group/sub/proj --mr 5 --title "Replaces https://gitlab.com/group/sub/proj/-/merge_requests/4"
expect_rc "updatemr(iid mismatch): -> exit 0 (the update DID happen)" 0
stdout_re "updatemr(iid mismatch): PM_MR_URL is empty, never another MR's URL" '^PM_MR_URL=$'
stderr_has "updatemr(iid mismatch): the warning names the iid actually printed" "for iid !4"
stderr_has "updatemr(iid mismatch): the warning names the MR that was updated" "not the MR that was updated (!5)"
check "updatemr(iid mismatch): the other MR's URL is never relayed on stdout" "a URL for a different MR was relayed as this one's" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'merge_requests/4' && echo 1 || echo 0 )"

section "update-mr.sh — the project filter is ANCHORED to the host (SEC-002)"
# Same residual gap as create-mr.sh's (see that section for the mechanism). The
# spoof is the SOLE shape-matching token, so the ambiguity guard cannot save it and
# the anchor is the only thing that can. DELIBERATE difference from create-mr.sh:
# the edit already succeeded, so the courtesy contract leaves PM_MR_URL empty
# rather than failing.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_UPDATE_OUT=!5 See https://attacker.example/x/group/sub/proj/-/merge_requests/5 (feat/x)" \
	sh "$UPDATEMR" --confirmed-host gitlab.com --repo group/sub/proj --mr 5 \
		--title "See https://attacker.example/x/group/sub/proj/-/merge_requests/5"
expect_rc "updatemr(unanchored spoof, sole candidate): -> exit 0 (the update DID happen)" 0
stdout_re "updatemr(unanchored spoof): PM_MR_URL is empty, never the spoof" '^PM_MR_URL=$'
check "updatemr(unanchored spoof): the attacker URL never reaches stdout" \
	"an extra leading path segment let a foreign host masquerade as this project" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'attacker.example' && echo 1 || echo 0 )"

section "update-mr.sh — a REPEATED flag accumulates as well as a comma-list does (TEST-002)"
# All six accumulators share ONE value-returning `accumulate` helper, and every
# case above exercised only the comma-list half of the "repeatable AND/OR
# comma-separated" contract. An accumulator that OVERWROTE instead of appending
# would have kept the whole suite green.
UPDATE_LOG_REPEAT="$WORK/mr-update-log-repeated-flags"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_OUT=" "GLAB_STUB_UPDATE_LOG=$UPDATE_LOG_REPEAT" \
	sh "$UPDATEMR" --confirmed-host gitlab.com --repo g/p --mr 5 \
		--add-reviewer alice --add-reviewer bob \
		--add-label first --add-label second \
		--remove-label stale --remove-label old \
		--add-assignee carol --add-assignee dave \
		--remove-assignee erin --remove-assignee frank \
		--remove-reviewer grace --remove-reviewer heidi
expect_rc "updatemr(repeated flags): -> exit 0" 0
check "updatemr(repeated flags): both --add-reviewer values arrived '+'-prefixed" "a repeated --add-reviewer was lost" \
	"$( argv_has_pair "$UPDATE_LOG_REPEAT" '--reviewer' '+alice' && argv_has_pair "$UPDATE_LOG_REPEAT" '--reviewer' '+bob' && echo 0 || echo 1 )"
check "updatemr(repeated flags): both --add-label values arrived" "a repeated --add-label was lost" \
	"$( argv_has_pair "$UPDATE_LOG_REPEAT" '--label' 'first' && argv_has_pair "$UPDATE_LOG_REPEAT" '--label' 'second' && echo 0 || echo 1 )"
check "updatemr(repeated flags): both --remove-label values arrived as --unlabel" "a repeated --remove-label was lost" \
	"$( argv_has_pair "$UPDATE_LOG_REPEAT" '--unlabel' 'stale' && argv_has_pair "$UPDATE_LOG_REPEAT" '--unlabel' 'old' && echo 0 || echo 1 )"
check "updatemr(repeated flags): both --add-assignee values arrived '+'-prefixed" "a repeated --add-assignee was lost" \
	"$( argv_has_pair "$UPDATE_LOG_REPEAT" '--assignee' '+carol' && argv_has_pair "$UPDATE_LOG_REPEAT" '--assignee' '+dave' && echo 0 || echo 1 )"
check "updatemr(repeated flags): both --remove-assignee values arrived '!'-prefixed" "a repeated --remove-assignee was lost" \
	"$( argv_has_pair "$UPDATE_LOG_REPEAT" '--assignee' '!erin' && argv_has_pair "$UPDATE_LOG_REPEAT" '--assignee' '!frank' && echo 0 || echo 1 )"
check "updatemr(repeated flags): both --remove-reviewer values arrived '!'-prefixed" "a repeated --remove-reviewer was lost" \
	"$( argv_has_pair "$UPDATE_LOG_REPEAT" '--reviewer' '!grace' && argv_has_pair "$UPDATE_LOG_REPEAT" '--reviewer' '!heidi' && echo 0 || echo 1 )"

section "update-mr.sh — comma-list trimming, empty-skip and the glob guard (TEST-003 / TEST-004)"
UPDATE_LOG_TRIM="$WORK/mr-update-log-trim"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_OUT=" "GLAB_STUB_UPDATE_LOG=$UPDATE_LOG_TRIM" \
	sh "$UPDATEMR" --confirmed-host gitlab.com --repo g/p --mr 5 --add-label "bug, urgent ,," --remove-label '*'
expect_rc "updatemr(csv trim + glob): -> exit 0" 0
check "updatemr(csv trim): 'bug' arrived clean" "the first token was mangled" \
	"$( argv_has_pair "$UPDATE_LOG_TRIM" '--label' 'bug' && echo 0 || echo 1 )"
check "updatemr(csv trim): ' urgent ' arrived TRIMMED" "surrounding whitespace was not trimmed" \
	"$( argv_has_pair "$UPDATE_LOG_TRIM" '--label' 'urgent' && echo 0 || echo 1 )"
check "updatemr(csv trim): the UNTRIMMED ' urgent ' never reached argv" "an untrimmed token was passed to glab" \
	"$( argv_has_pair "$UPDATE_LOG_TRIM" '--label' ' urgent ' && echo 1 || echo 0 )"
check "updatemr(csv trim): the empty elements produced NO empty --label value" "an empty label value was passed to glab" \
	"$( argv_has_pair "$UPDATE_LOG_TRIM" '--label' '' && echo 1 || echo 0 )"
check "updatemr(glob guard): the literal '*' reached --unlabel (it was NOT filename-expanded)" \
	"the '*' was glob-expanded against the cwd instead of staying literal" \
	"$( argv_has_pair "$UPDATE_LOG_TRIM" '--unlabel' '*' && echo 0 || echo 1 )"

section "update-mr.sh — --mr rejects 0 and leading-zero forms (usage error, not a glab failure)"
run 1 sh "$UPDATEMR" --confirmed-host gitlab.com --repo g/p --mr 0 --title x
expect_rc "updatemr(--mr 0): -> exit 2" 2
stderr_has "updatemr(--mr 0): diagnostic" "positive integer"
run 1 sh "$UPDATEMR" --confirmed-host gitlab.com --repo g/p --mr 007 --title x
expect_rc "updatemr(--mr 007): -> exit 2 (007 is not the iid GitLab echoes back)" 2
stderr_has "updatemr(--mr 007): diagnostic" "positive integer"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n== summary ==\n'
printf 'ran %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ] || exit 1
printf 'ALL TESTS PASSED\n'
exit 0
