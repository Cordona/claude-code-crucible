#!/usr/bin/env sh
#
# run-tests.sh — self-contained, zero-dependency POSIX test harness for the
#                procedure-glab-issues script suite (create-issue.sh,
#                find-duplicate.sh, link-children.sh, ensure-labels.sh,
#                comment.sh, update-issue.sh, close-issue.sh).
#
# WHY a hand-rolled harness (not bats): the whole point of this suite is "runs
# on any machine with no dependencies". Requiring bats-core would contradict
# that. This harness needs only a POSIX sh plus the coreutils that already ship
# on macOS (BSD) and Linux (GNU). It mirrors the sibling procedure-gh-issues
# harness's shape AND procedure-glab-mr's stricter argv/value-capture rigor —
# see those two suites for the original design notes.
#
# What it does:
#   * Builds an isolated PATH "toolbox" of symlinks to only the real tools the
#     scripts need (mktemp, grep, sed, awk, ...) PLUS a STUB `glab` so no test
#     ever touches a real project, a real account, or the network. The glab stub
#     lives in its OWN dir that tests opt into, so "glab absent" is exercised
#     for real (by leaving that dir off PATH).
#   * The glab stub is fully env-driven: tests set GLAB_STUB_* variables to
#     script `glab auth status`, `issue create`/`list`/`view`/`update`/`note`/
#     `close`, `label list`/`create`, `milestone list`, and their return codes —
#     so every deterministic branch is covered without a real `glab`.
#   * The stub logs argv ONE TOKEN PER LINE (between ARGV_BEGIN/ARGV_END
#     markers), never space-joined — a joined "--title a b" string cannot be
#     told apart from three separate tokens (a word-splitting regression), but a
#     token-per-line log can, and that distinction is exactly what many
#     assertions below rely on.
#   * The issue DESCRIPTION / note MESSAGE is captured TWICE, on purpose. These
#     scripts do not pass a body PATH (glab has no --description-file /
#     --message-file), they pass the file's bytes as the argv VALUE right after
#     `--description` / `--message` — so:
#       (a) a marker block in the argv log (VALUE_START/VALUE_END) mirrors the
#           gh-issues harness's BODY_FILE_CONTENTS_START/END and keeps failures
#           readable, and
#       (b) GLAB_STUB_DESC_FILE / GLAB_STUB_MSG_FILE get a raw, byte-exact copy
#           of that same value, because a marker block cannot be diffed
#           byte-for-byte (the newline that terminates the END marker is
#           indistinguishable from a trailing newline in the value itself — and
#           preserving exactly that trailing newline is one of the properties
#           under test).
#   * `glab label list` is PAGE-AWARE in the stub (page 1 / page 2 / empty), so
#     the scripts' explicit page walk — glab has no `--paginate` and defaults to
#     only 30 labels per page — is exercised for real, not assumed.
#   * `glab milestone list --title` is FILTERED in the stub, so create-issue.sh's
#     server-side-exact milestone pre-check is exercised the way glab performs
#     it, not faked.
#   * Everything runs under `env -i` with an isolated HOME + TMPDIR and is
#     cleaned up on exit.
#
# STUB-ONLY CAVEAT (read this if a real `glab` release ever changes behavior):
#   These tests are entirely stub-driven — no real `glab` runs here, ever. The
#   `glab issue`/`label`/`milestone` flag spellings this suite relies on
#   (create: --repo/--title/--description/--label/--milestone/--assignee/--yes
#   and the ABSENCE of a --description-file; list: --search/--in/--all/--output/
#   --jq; view: --output/--jq; update: positional <id> + --title/--description/
#   --label/--unlabel/--assignee with '+'/'!' prefixes and NO --yes; note:
#   positional <id> + --message and NO --yes; close: positional <id> + --repo
#   only, with NO --reason and NO comment flag; label list: --output/--jq/
#   --per-page/--page and NO --paginate; label create: --name/--color/
#   --description; milestone list: --title/--output/--jq) were all verified
#   against a real `glab … --help` at BUILD time (glab 1.112.0), not by this
#   harness — the stub simply echoes back whatever the scripts pass it, so it
#   cannot detect a real `glab` release drifting from that contract. Catching a
#   real-glab contract drift needs an occasional real-glab smoke check against a
#   scratch project — deliberately out of scope for this harness, which exists
#   to run anywhere with zero dependencies (see above).
#
#   WHAT A STUB STILL CANNOT SETTLE: whether `glab`'s own `--jq` renders a STRING
#   result raw or JSON-quoted. Live testing has since answered it for the shapes
#   these scripts depend on (raw), so this is no longer an open question — but it
#   remains something a stub cannot PROVE, so both renderings are pinned as
#   CHARACTERIZATION tests instead of assumed: find-duplicate.sh is exercised
#   against both, and link-children.sh — the one script that writes a read-back
#   description BACK to a live issue — has its own JSON-quoted case below, so a
#   future `glab` rendering change shows up as a failing test rather than as a
#   silently corrupted epic description. Every script also normalizes defensively
#   (a SURROUNDING PAIR of quotes stripped from --jq rows, never every quote in
#   the value, which would corrupt a label or milestone that contains one).
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
CREATE="$SCRIPTS_DIR/create-issue.sh"
FINDDUP="$SCRIPTS_DIR/find-duplicate.sh"
LINKKIDS="$SCRIPTS_DIR/link-children.sh"
ENSURELABELS="$SCRIPTS_DIR/ensure-labels.sh"
COMMENT="$SCRIPTS_DIR/comment.sh"
UPDATE="$SCRIPTS_DIR/update-issue.sh"
CLOSE="$SCRIPTS_DIR/close-issue.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/glab-issues-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"      # real tools (glab is NEVER here)
GLABDIR="$WORK/glabbin"      # glab stub (only when a test opts in)
mkdir -p "$TOOLBOX" "$GLABDIR" "$WORK/home"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# Some fixtures (chmod 000 for an unreadable-body test) have no effect under
# uid 0 — root can read/write regardless of permission bits — so that one test
# is skipped rather than producing a false failure/pass under root.
IS_ROOT=0
[ "$(id -u 2>/dev/null || printf '1')" = "0" ] && IS_ROOT=1

# ---------------------------------------------------------------------------
# Isolated PATH toolbox: symlink only the real tools we need. glab is NEVER here.
# ---------------------------------------------------------------------------
ORIG_PATH=$PATH
link_tool() {
	tp=$(PATH="$ORIG_PATH" command -v "$1" 2>/dev/null || true)
	[ -n "$tp" ] || { printf 'FATAL: required tool not found: %s\n' "$1" >&2; exit 1; }
	ln -s "$tp" "$TOOLBOX/$1"
}
for t in sh env mktemp grep sed cat diff awk rm head cp mv; do
	link_tool "$t"
done

# ---------------------------------------------------------------------------
# glab stub — fully env-driven so tests script every deterministic branch.
#   GLAB_STUB_AUTHED=1              -> `glab auth status` succeeds (bare/--all)
#
#   GLAB_STUB_CREATE_RC=n           -> exit code for `glab issue create`
#   GLAB_STUB_CREATE_OUT=text       -> stdout for a successful create
#                                      (set-but-EMPTY honored as empty output —
#                                      distinct from leaving it unset)
#   GLAB_STUB_CREATE_LOG=path       -> argv (token-per-line) + the --description
#                                      VALUE between markers
#
#   GLAB_STUB_LIST_RC=n             -> exit code for `glab issue list`
#   GLAB_STUB_LIST_URLS=<nl-list>   -> its --jq result (web_url lines)
#   GLAB_STUB_LIST_LOG=path         -> argv for `glab issue list`
#
#   GLAB_STUB_VIEW_RC=n             -> exit code for `glab issue view`
#   GLAB_STUB_VIEW_BODY=text        -> its --jq '.description' result
#   GLAB_STUB_VIEW_LOG=path         -> argv for `glab issue view`
#
#   GLAB_STUB_UPDATE_RC=n           -> exit code for `glab issue update`
#   GLAB_STUB_UPDATE_OUT=text       -> stdout for a successful update
#   GLAB_STUB_UPDATE_LOG=path       -> argv + the --description VALUE
#
#   GLAB_STUB_NOTE_RC=n             -> exit code for `glab issue note`
#   GLAB_STUB_NOTE_OUT=text         -> stdout for a successful note
#   GLAB_STUB_NOTE_LOG=path         -> argv + the --message VALUE
#
#   GLAB_STUB_CLOSE_RC=n            -> exit code for `glab issue close`
#   GLAB_STUB_CLOSE_LOG=path        -> argv for `glab issue close`
#
#   GLAB_STUB_LABEL_LIST_RC=n       -> exit code for `glab label list`
#   GLAB_STUB_LABELS=<nl-list>      -> label names returned for --page 1
#   GLAB_STUB_LABELS_P2=<nl-list>   -> label names returned for --page 2
#                                      (any later page returns empty), so the
#                                      scripts' page walk is really exercised
#   GLAB_STUB_LABEL_LIST_LOG=path   -> argv for EACH `glab label list` call
#
#   GLAB_STUB_LABEL_CREATE_RC=n     -> exit code for EVERY `glab label create`
#   GLAB_STUB_LABEL_CREATE_FAIL_LIST=<nl-list> -> exit 1 ONLY for a create whose
#                                      label NAME (the --name value) is listed —
#                                      lets a test fail ONE label while others in
#                                      the same run still succeed
#   GLAB_STUB_LABEL_CREATE_LOG=path -> argv for EACH `glab label create` call
#                                      (one ARGV block per call)
#
#   GLAB_STUB_MILESTONE_LIST_RC=n   -> exit code for `glab milestone list`
#   GLAB_STUB_MILESTONES=<nl-list>  -> milestone titles; FILTERED by the --title
#                                      value when one is passed, the way glab
#                                      filters server-side
#   GLAB_STUB_MILESTONE_LIST_LOG=path -> argv for `glab milestone list`
#
#   GLAB_STUB_DESC_FILE=path        -> byte-exact raw copy of the --description
#                                      VALUE (no markers, nothing appended)
#   GLAB_STUB_MSG_FILE=path         -> byte-exact raw copy of the --message VALUE
#
#   GLAB_STUB_CREATE_ERR_OUT=text   -> emit text on STDERR for a successful `glab
#                                      issue create`. Exercises the scripts' "glab
#                                      may print the URL on stderr" scan, which no
#                                      other stub setting can reach (it was
#                                      previously deletable with every test still
#                                      green). Combined with a non-empty
#                                      GLAB_STUB_CREATE_OUT it writes BOTH streams,
#                                      which is how the SEC-003 cases stage a spoof
#                                      on stdout against the genuine URL on stderr;
#                                      alone, stderr is the only stream.
#   GLAB_STUB_UPDATE_ERR_OUT=text   -> the same, for `glab issue update`
#   GLAB_STUB_NOTE_ERR_OUT=text     -> the same, for `glab issue note`
#
#   GLAB_STUB_ENV_LOG=path          -> append "<command> <sub> GITLAB_HOST=<value>"
#                                      for EVERY stub invocation, recording what
#                                      the script had set GITLAB_HOST to at the
#                                      moment it ran glab (literally '<unset>'
#                                      when unset). This is the ONLY way to test
#                                      the --confirmed-host contract: glab selects
#                                      its target INSTANCE from that environment
#                                      variable, so "did the write actually go to
#                                      the confirmed host?" is an ENVIRONMENT
#                                      property no argv assertion can reach —
#                                      --confirmed-host must NOT appear in the
#                                      glab argv at all.
# ---------------------------------------------------------------------------
cat >"$GLABDIR/glab" <<'GLAB_STUB'
#!/usr/bin/env sh
set -eu

# Recorded FIRST, before any command dispatch, so every code path below is
# covered — including the ones that exit early.
if [ -n "${GLAB_STUB_ENV_LOG:-}" ]; then
	printf '%s %s GITLAB_HOST=%s\n' "${1:-}" "${2:-}" "${GITLAB_HOST-<unset>}" >>"$GLAB_STUB_ENV_LOG"
fi

log_argv() {
	# log_argv LOGFILE "$@" — logs each argv token on its OWN line between
	# ARGV_BEGIN/ARGV_END markers. One-token-per-line (not a space-joined
	# string) so a caller can prove a value arrived as ONE argv token (e.g.
	# right after a flag) rather than being word-split into several.
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

capture_flag_value() {
	# capture_flag_value LOGFILE RAWFILE FLAG MARKER "$@" — scans argv for the
	# VALUE following FLAG (glab has no --description-file/--message-file, so the
	# content arrives as an argv value, not a path) and records it two ways: a
	# marker block in LOGFILE for readable assertions, and — when RAWFILE is set
	# — a raw byte-exact copy for a strict diff. See the harness header for why
	# both are needed.
	cfv_log=$1
	cfv_raw=$2
	cfv_flag=$3
	cfv_marker=$4
	shift 4
	prev=""
	for a in "$@"; do
		if [ "$prev" = "$cfv_flag" ]; then
			if [ -n "$cfv_log" ]; then
				{
					printf '%s_START\n' "$cfv_marker"
					printf '%s' "$a"
					printf '\n%s_END\n' "$cfv_marker"
				} >>"$cfv_log"
			fi
			if [ -n "$cfv_raw" ]; then
				printf '%s' "$a" >"$cfv_raw"
			fi
		fi
		prev=$a
	done
}

flag_value() {
	# flag_value FLAG "$@" — print the LAST value following FLAG in argv, or
	# nothing. Used by the page-aware / title-filtered list stubs below.
	fv_flag=$1
	shift
	fv_found=""
	prev=""
	for a in "$@"; do
		if [ "$prev" = "$fv_flag" ]; then fv_found=$a; fi
		prev=$a
	done
	printf '%s' "$fv_found"
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
	issue)
		case "${2:-}" in
			create)
				shift 2
				log_argv "${GLAB_STUB_CREATE_LOG:-}" "$@"
				capture_flag_value "${GLAB_STUB_CREATE_LOG:-}" "${GLAB_STUB_DESC_FILE:-}" \
					'--description' 'DESCRIPTION_VALUE' "$@"
				if [ "${GLAB_STUB_CREATE_RC:-0}" != "0" ]; then
					printf 'stub: forced issue create failure\n' >&2
					exit "${GLAB_STUB_CREATE_RC:-1}"
				fi
				# STDERR-only output: real glab decorates its create block and
				# may put part of it (the URL included) on stderr, which is why
				# create-issue.sh scans the captured stderr as a fallback.
				# Nothing else in this stub produces that stream, so the fallback
				# is only reachable through this branch.
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
				# GLAB_STUB_CREATE_OUT to the EMPTY string must see empty output,
				# distinct from leaving the var unset entirely. The default mimics
				# glab's decorated create block (the URL on the second line).
				#
				# The default URL uses the '/-/work_items/<iid>' path because that
				# is what real glab prints today (live-verified) — GitLab migrated
				# issue URLs to the work-items path. Keeping the stub default on
				# the obsolete '/-/issues/' shape is what let the shape-matching
				# regression ship. The classic shape is still exercised, via
				# explicit GLAB_STUB_CREATE_OUT overrides below.
				printf '%s\n' "${GLAB_STUB_CREATE_OUT-#7 Add the export feature
 https://gitlab.com/group/sub/proj/-/work_items/7}"
				exit 0 ;;
			list)
				shift 2
				log_argv "${GLAB_STUB_LIST_LOG:-}" "$@"
				if [ "${GLAB_STUB_LIST_RC:-0}" != "0" ]; then
					printf 'stub: forced issue list failure\n' >&2
					exit "${GLAB_STUB_LIST_RC:-1}"
				fi
				printf '%s\n' "${GLAB_STUB_LIST_URLS:-}"
				exit 0 ;;
			view)
				shift 2
				log_argv "${GLAB_STUB_VIEW_LOG:-}" "$@"
				if [ "${GLAB_STUB_VIEW_RC:-0}" != "0" ]; then
					printf 'stub: forced issue view failure\n' >&2
					exit "${GLAB_STUB_VIEW_RC:-1}"
				fi
				printf '%s\n' "${GLAB_STUB_VIEW_BODY:-}"
				exit 0 ;;
			update)
				shift 2
				log_argv "${GLAB_STUB_UPDATE_LOG:-}" "$@"
				capture_flag_value "${GLAB_STUB_UPDATE_LOG:-}" "${GLAB_STUB_DESC_FILE:-}" \
					'--description' 'DESCRIPTION_VALUE' "$@"
				if [ "${GLAB_STUB_UPDATE_RC:-0}" != "0" ]; then
					printf 'stub: forced issue update failure\n' >&2
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
				# ${VAR-default}, NOT ${VAR:-default} — see GLAB_STUB_CREATE_OUT,
				# which also explains the '/-/work_items/' path in the default.
				printf '%s\n' "${GLAB_STUB_UPDATE_OUT-https://gitlab.com/group/sub/proj/-/work_items/5}"
				exit 0 ;;
			note)
				shift 2
				log_argv "${GLAB_STUB_NOTE_LOG:-}" "$@"
				capture_flag_value "${GLAB_STUB_NOTE_LOG:-}" "${GLAB_STUB_MSG_FILE:-}" \
					'--message' 'MESSAGE_VALUE' "$@"
				if [ "${GLAB_STUB_NOTE_RC:-0}" != "0" ]; then
					printf 'stub: forced issue note failure\n' >&2
					exit "${GLAB_STUB_NOTE_RC:-1}"
				fi
				# STDERR output (+ optional simultaneous stdout) — see
				# GLAB_STUB_CREATE_ERR_OUT above.
				if [ -n "${GLAB_STUB_NOTE_ERR_OUT:-}" ]; then
					printf '%s\n' "$GLAB_STUB_NOTE_ERR_OUT" >&2
					if [ -n "${GLAB_STUB_NOTE_OUT:-}" ]; then
						printf '%s\n' "$GLAB_STUB_NOTE_OUT"
					fi
					exit 0
				fi
				# ${VAR-default}, NOT ${VAR:-default} — see GLAB_STUB_CREATE_OUT,
				# which also explains the '/-/work_items/' path in the default.
				printf '%s\n' "${GLAB_STUB_NOTE_OUT-https://gitlab.com/group/sub/proj/-/work_items/5#note_42}"
				exit 0 ;;
			close)
				shift 2
				log_argv "${GLAB_STUB_CLOSE_LOG:-}" "$@"
				if [ "${GLAB_STUB_CLOSE_RC:-0}" != "0" ]; then
					printf 'stub: forced issue close failure\n' >&2
					exit "${GLAB_STUB_CLOSE_RC:-1}"
				fi
				exit 0 ;;
			*) exit 0 ;;
		esac ;;
	label)
		case "${2:-}" in
			list)
				shift 2
				log_argv "${GLAB_STUB_LABEL_LIST_LOG:-}" "$@"
				if [ "${GLAB_STUB_LABEL_LIST_RC:-0}" != "0" ]; then
					printf 'stub: forced label list failure\n' >&2
					exit "${GLAB_STUB_LABEL_LIST_RC:-1}"
				fi
				# Page-aware: the scripts walk pages because glab has no
				# --paginate and defaults to 30 per page. Page 1 and 2 are
				# scriptable; anything beyond is empty (end of results).
				stub_page=$(flag_value '--page' "$@")
				case "${stub_page:-1}" in
					1) printf '%s\n' "${GLAB_STUB_LABELS:-}" ;;
					2) printf '%s\n' "${GLAB_STUB_LABELS_P2:-}" ;;
					*) printf '\n' ;;
				esac
				exit 0 ;;
			create)
				shift 2
				log_argv "${GLAB_STUB_LABEL_CREATE_LOG:-}" "$@"
				stub_name=$(flag_value '--name' "$@")
				if [ -n "${GLAB_STUB_LABEL_CREATE_FAIL_LIST:-}" ] && \
					printf '%s\n' "$GLAB_STUB_LABEL_CREATE_FAIL_LIST" | grep -Fxq -- "$stub_name"; then
					printf 'stub: forced label create failure for %s\n' "$stub_name" >&2
					exit 1
				fi
				if [ "${GLAB_STUB_LABEL_CREATE_RC:-0}" != "0" ]; then
					printf 'stub: forced label create failure\n' >&2
					exit "${GLAB_STUB_LABEL_CREATE_RC:-1}"
				fi
				exit 0 ;;
			*) exit 0 ;;
		esac ;;
	milestone)
		case "${2:-}" in
			list)
				shift 2
				log_argv "${GLAB_STUB_MILESTONE_LIST_LOG:-}" "$@"
				if [ "${GLAB_STUB_MILESTONE_LIST_RC:-0}" != "0" ]; then
					printf 'stub: forced milestone list failure\n' >&2
					exit "${GLAB_STUB_MILESTONE_LIST_RC:-1}"
				fi
				# glab filters server-side on --title; mimic that so the
				# pre-check is exercised the way glab actually behaves.
				stub_title=$(flag_value '--title' "$@")
				if [ -n "$stub_title" ]; then
					printf '%s\n' "${GLAB_STUB_MILESTONES:-}" | grep -Fx -- "$stub_title" || true
				else
					printf '%s\n' "${GLAB_STUB_MILESTONES:-}"
				fi
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
skip() { printf '  skip %s\n' "$1"; }

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

# line_count_eq FILE EXACT_LINE N — true iff EXACT_LINE appears in FILE exactly
# N times (whole-line match). Used for idempotency: presence alone doesn't catch
# a double-append, an exact count does.
line_count_eq() {
	[ "$(grep -Fxc -- "$2" "$1" 2>/dev/null || true)" -eq "$3" ]
}

# argv_has_pair LOGFILE FLAG VALUE — true iff FLAG appears immediately followed
# by VALUE as two CONSECUTIVE lines inside the log's token-per-line
# ARGV_BEGIN/ARGV_END block. Proves VALUE reached glab as ONE argv token right
# after FLAG — a word-splitting regression would show as extra lines instead.
#
# SCOPED TO THE ARGV BLOCK, the same way argv_first_is is scoped via its
# ARGV_BEGIN-adjacency rule (here the scoping mechanism is an explicit in_argv
# open/close gate; there it is adjacency to the ARGV_BEGIN marker — different
# mechanisms, the same property). Scoping is what makes either sound: the SAME log
# file also holds the stub's DESCRIPTION_VALUE / MESSAGE_VALUE marker blocks, i.e.
# untrusted fixture payload bytes. An unscoped scan could be satisfied by two
# adjacent payload lines that merely LOOK like a flag+value pair, passing a positive
# assertion the script never actually earned (and, symmetrically, defeating a
# negative one).
#
# FLAG and VALUE travel through the ENVIRONMENT, not through `awk -v`, because
# `-v` assignment performs ESCAPE PROCESSING: a `\t` or `\\` inside an expected
# value would silently be rewritten and never match the literal bytes the script
# actually passed. ENVIRON does no such rewriting.
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
# `grep -Fxq -- 'TOKEN' logfile`, which scanned the DESCRIPTION_VALUE /
# MESSAGE_VALUE payload blocks too: an assertion that "no --description token was
# passed" (the non-clobber guard) must not be defeated — or satisfied — by a
# fixture whose body happens to contain a line reading exactly `--description`.
# TOKEN travels via ENVIRON for the same no-escape-processing reason as
# argv_has_pair's.
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
# instead by diff_value_file against the stub's raw copy, which is a stronger
# check than any argv-line comparison could be.

# argv_first_is LOGFILE VALUE — true iff VALUE is the FIRST token of an argv
# block, i.e. it was passed POSITIONALLY rather than behind a flag. This is what
# proves update-issue.sh / comment.sh / close-issue.sh forward the issue iid the
# way glab takes it (positional <id>), not as an invented --issue flag.
argv_first_is() {
	awk -v value="$2" '
		$0 == "ARGV_BEGIN" { next_is_first = 1; next }
		next_is_first == 1 { if ($0 == value) { found = 1 }; next_is_first = 0 }
		END { exit(found ? 0 : 1) }
	' "$1"
}

# value_block LOGFILE MARKER — prints only the lines between the stub's
# MARKER_START/MARKER_END markers (exclusive), so an assertion can be scoped to
# the value glab received, never to the ARGV lines.
value_block() {
	sed -n "/^$2_START\$/,/^$2_END\$/p" "$1" | sed '1d;$d'
}

# diff_value_file FIXTURE ACTUAL — strict byte-for-byte compare of the raw
# --description/--message value glab received against the original fixture file.
# The authoritative proof that content reached glab completely unaltered:
# evaluation, truncation, or a stripped trailing newline (which a plain
# $(cat file) WOULD cause) would all change the bytes. Writes the diff to
# $WORK/value_diff.
diff_value_file() {
	diff -u "$1" "$2" >"$WORK/value_diff" 2>&1
}

section() { printf '\n== %s ==\n' "$1"; }

# A real, three-segment GitLab project path (group/subgroup/project) — the shape
# a GitHub-style OWNER/REPO validator would wrongly reject.
DEEP_PATH='cross-project-standards/git-services/test-client-application'

# A full first page of labels (LABELS_PER_PAGE is 100 in the scripts), so page 1
# looks "full" and the page walk must fetch page 2 to find the wanted label.
FULL_LABEL_PAGE=$(awk 'BEGIN { for (i = 1; i <= 100; i++) printf "filler-%d\n", i }')

# ---------------------------------------------------------------------------
# Shared fixtures, created HERE rather than inside whichever section happens to
# need them first — they are consumed by SECTIONS FAR APART, so a section that
# creates one for its neighbours hundreds of lines below is a silent
# reorder/delete hazard.
#
#   empty-body.md — a zero-byte body. Consumed by the create-issue.sh, comment.sh,
#                   update-issue.sh AND close-issue.sh usage sections.
#   dash-body.md  — a body of exactly '-', which glab reads as "open an
#                   interactive editor". Consumed by the same four sections.
# ---------------------------------------------------------------------------
: >"$WORK/empty-body.md"
printf -- '-\n' >"$WORK/dash-body.md"

# ===========================================================================
# --confirmed-host: REQUIRED on every script, and it PINS glab's target host
# (SEC-001)
#
# THE GAP THIS CLOSES: procedure-gitlab-auth's gate confirms an (account, HOST)
# pair with the user before any write, but nothing used to BIND that confirmation
# to the actual glab call — glab resolved its target INSTANCE from ambient state
# (the cwd's git remotes, glab's config, its gitlab.com default). On a machine with
# two configured instances — the very case the gate exists to disambiguate — the
# gate could confirm host A while the write silently landed on host B, whenever the
# same --repo project path resolves on both. A live tracker write is
# unretractable, and there was no error to notice.
#
# The flag is REQUIRED, not optional, on purpose: an "optional but you really
# should pass it" middle state leaves exactly the silent-wrong-host path open.
#
# HOW THE PINNING IS OBSERVED: glab takes its target instance from the GITLAB_HOST
# ENVIRONMENT VARIABLE (its own documented per-invocation selector), so "did this
# operation actually target the confirmed host?" is an environment property NO argv
# assertion can reach — and, symmetrically, --confirmed-host must NOT appear in the
# glab argv at all, because glab has no such flag. GLAB_STUB_ENV_LOG records, per
# invocation, what GITLAB_HOST was set to (or literally '<unset>').
#
# PINNED_HOST is deliberately a SELF-MANAGED host with a port, never glab's
# gitlab.com default, so a script that ignored the flag would record something
# else. It is deliberately NOT the host in the fixture URLs either: the URL
# extractors filter on the PROJECT path, not on the host, so the two are
# independent — pinning where the write GOES is this section's subject, and which
# URL is relayed BACK is the SEC-002 sections' subject.
#
# These cases live together, before the per-script blocks, because the contract is
# one contract across all seven scripts — a per-script copy would drift.
# ===========================================================================
PINNED_HOST='gitlab.example.com:8443'
CH_BODY="$WORK/confirmed-host-body.md"
printf 'A body.\n' >"$CH_BODY"

section "--confirmed-host — create-issue.sh"
CH_ENV_CREATE_MISSING="$WORK/ch-env-create-missing"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_ENV_LOG=$CH_ENV_CREATE_MISSING" \
	sh "$CREATE" --repo g/p --title x --body-file "$CH_BODY"
expect_rc "create(missing --confirmed-host): -> exit 2 (never a default host)" 2
stderr_has "create(missing --confirmed-host): diagnostic" "--confirmed-host is required"
stderr_has "create(missing --confirmed-host): names the gate that produces it" "procedure-gitlab-auth"
file_missing "create(missing --confirmed-host): glab was never invoked at all" "$CH_ENV_CREATE_MISSING"
run 1 "GLAB_STUB_AUTHED=1" sh "$CREATE" --repo g/p --title x --body-file "$CH_BODY" --confirmed-host 'https://gitlab.com'
expect_rc "create(scheme-qualified --confirmed-host): -> exit 2 (one spelling only)" 2
stderr_has "create(scheme-qualified --confirmed-host): diagnostic" "no scheme"
CH_ENV_CREATE="$WORK/ch-env-create"
CH_ARGV_CREATE="$WORK/ch-argv-create"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_ENV_LOG=$CH_ENV_CREATE" "GLAB_STUB_CREATE_LOG=$CH_ARGV_CREATE" \
	sh "$CREATE" --repo group/sub/proj --title x --body-file "$CH_BODY" --confirmed-host "$PINNED_HOST"
expect_rc "create(pinned host): -> exit 0" 0
check "create(pinned host): glab issue create saw GITLAB_HOST equal to --confirmed-host" \
	"expected 'issue create GITLAB_HOST=$PINNED_HOST'; env log: $(cat "$CH_ENV_CREATE" 2>/dev/null | tr '\n' '|')" \
	"$( grep -Fxq -- "issue create GITLAB_HOST=$PINNED_HOST" "$CH_ENV_CREATE" && echo 0 || echo 1 )"
check "create(pinned host): NO glab invocation ran with GITLAB_HOST unset" \
	"a glab call resolved its host from ambient state instead of the confirmed one" \
	"$( grep -Fq -- 'GITLAB_HOST=<unset>' "$CH_ENV_CREATE" && echo 1 || echo 0 )"
check "create(pinned host): --confirmed-host is NOT forwarded into the glab argv" "--confirmed-host leaked into the glab argv" \
	"$( argv_has_token "$CH_ARGV_CREATE" '--confirmed-host' && echo 1 || echo 0 )"

section "--confirmed-host — find-duplicate.sh"
CH_ENV_FINDDUP_MISSING="$WORK/ch-env-finddup-missing"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_ENV_LOG=$CH_ENV_FINDDUP_MISSING" \
	sh "$FINDDUP" --repo g/p --title x
expect_rc "finddup(missing --confirmed-host): -> exit 2" 2
stderr_has "finddup(missing --confirmed-host): diagnostic" "--confirmed-host is required"
file_missing "finddup(missing --confirmed-host): glab was never invoked at all" "$CH_ENV_FINDDUP_MISSING"
run 1 "GLAB_STUB_AUTHED=1" sh "$FINDDUP" --repo g/p --title x --confirmed-host 'https://gitlab.com'
expect_rc "finddup(scheme-qualified --confirmed-host): -> exit 2" 2
CH_ENV_FINDDUP="$WORK/ch-env-finddup"
CH_ARGV_FINDDUP="$WORK/ch-argv-finddup"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LIST_URLS=" "GLAB_STUB_ENV_LOG=$CH_ENV_FINDDUP" "GLAB_STUB_LIST_LOG=$CH_ARGV_FINDDUP" \
	sh "$FINDDUP" --repo g/p --title x --confirmed-host "$PINNED_HOST"
expect_rc "finddup(pinned host): -> exit 0" 0
check "finddup(pinned host): glab issue list saw GITLAB_HOST equal to --confirmed-host" \
	"expected 'issue list GITLAB_HOST=$PINNED_HOST'; env log: $(cat "$CH_ENV_FINDDUP" 2>/dev/null | tr '\n' '|')" \
	"$( grep -Fxq -- "issue list GITLAB_HOST=$PINNED_HOST" "$CH_ENV_FINDDUP" && echo 0 || echo 1 )"
check "finddup(pinned host): NO glab invocation ran with GITLAB_HOST unset" \
	"a glab call resolved its host from ambient state instead of the confirmed one" \
	"$( grep -Fq -- 'GITLAB_HOST=<unset>' "$CH_ENV_FINDDUP" && echo 1 || echo 0 )"
check "finddup(pinned host): --confirmed-host is NOT forwarded into the glab argv" "--confirmed-host leaked into the glab argv" \
	"$( argv_has_token "$CH_ARGV_FINDDUP" '--confirmed-host' && echo 1 || echo 0 )"

section "--confirmed-host — link-children.sh"
CH_ENV_KIDS_MISSING="$WORK/ch-env-kids-missing"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_ENV_LOG=$CH_ENV_KIDS_MISSING" \
	sh "$LINKKIDS" --repo g/p --epic-issue 10 --child 11
expect_rc "linkkids(missing --confirmed-host): -> exit 2" 2
stderr_has "linkkids(missing --confirmed-host): diagnostic" "--confirmed-host is required"
file_missing "linkkids(missing --confirmed-host): glab was never invoked at all" "$CH_ENV_KIDS_MISSING"
run 1 "GLAB_STUB_AUTHED=1" sh "$LINKKIDS" --repo g/p --epic-issue 10 --child 11 --confirmed-host 'https://gitlab.com'
expect_rc "linkkids(scheme-qualified --confirmed-host): -> exit 2" 2
CH_ENV_KIDS="$WORK/ch-env-kids"
CH_ARGV_KIDS="$WORK/ch-argv-kids"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_VIEW_BODY=## Outcome" "GLAB_STUB_ENV_LOG=$CH_ENV_KIDS" \
	"GLAB_STUB_UPDATE_LOG=$CH_ARGV_KIDS" \
	sh "$LINKKIDS" --repo g/p --epic-issue 10 --child 11 --confirmed-host "$PINNED_HOST"
expect_rc "linkkids(pinned host): -> exit 0" 0
check "linkkids(pinned host): the READ (glab issue view) saw the confirmed host" \
	"expected 'issue view GITLAB_HOST=$PINNED_HOST'; env log: $(cat "$CH_ENV_KIDS" 2>/dev/null | tr '\n' '|')" \
	"$( grep -Fxq -- "issue view GITLAB_HOST=$PINNED_HOST" "$CH_ENV_KIDS" && echo 0 || echo 1 )"
# The read-then-write shape makes this script the one where a split host would do
# the most damage: it reads a description, splices it, and writes it back, so a read
# and a write on DIFFERENT instances would overwrite one epic with another's content.
check "linkkids(pinned host): the WRITE-BACK (glab issue update) saw the SAME confirmed host" \
	"the read and the write-back could resolve different instances" \
	"$( grep -Fxq -- "issue update GITLAB_HOST=$PINNED_HOST" "$CH_ENV_KIDS" && echo 0 || echo 1 )"
check "linkkids(pinned host): NO glab invocation ran with GITLAB_HOST unset" \
	"a glab call resolved its host from ambient state instead of the confirmed one" \
	"$( grep -Fq -- 'GITLAB_HOST=<unset>' "$CH_ENV_KIDS" && echo 1 || echo 0 )"
check "linkkids(pinned host): --confirmed-host is NOT forwarded into the glab argv" "--confirmed-host leaked into the glab argv" \
	"$( argv_has_token "$CH_ARGV_KIDS" '--confirmed-host' && echo 1 || echo 0 )"

section "--confirmed-host — ensure-labels.sh"
CH_ENV_LABELS_MISSING="$WORK/ch-env-labels-missing"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_ENV_LOG=$CH_ENV_LABELS_MISSING" \
	sh "$ENSURELABELS" --repo g/p --label foo
expect_rc "ensurelabels(missing --confirmed-host): -> exit 2" 2
stderr_has "ensurelabels(missing --confirmed-host): diagnostic" "--confirmed-host is required"
file_missing "ensurelabels(missing --confirmed-host): glab was never invoked at all" "$CH_ENV_LABELS_MISSING"
run 1 "GLAB_STUB_AUTHED=1" sh "$ENSURELABELS" --repo g/p --label foo --confirmed-host 'https://gitlab.com'
expect_rc "ensurelabels(scheme-qualified --confirmed-host): -> exit 2" 2
CH_ENV_LABELS="$WORK/ch-env-labels"
CH_ARGV_LABELS="$WORK/ch-argv-labels"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABELS=" "GLAB_STUB_ENV_LOG=$CH_ENV_LABELS" \
	"GLAB_STUB_LABEL_CREATE_LOG=$CH_ARGV_LABELS" \
	sh "$ENSURELABELS" --repo g/p --label foo --confirmed-host "$PINNED_HOST"
expect_rc "ensurelabels(pinned host): -> exit 0" 0
check "ensurelabels(pinned host): the existence LOOKUP saw the confirmed host" \
	"expected 'label list GITLAB_HOST=$PINNED_HOST'; env log: $(cat "$CH_ENV_LABELS" 2>/dev/null | tr '\n' '|')" \
	"$( grep -Fxq -- "label list GITLAB_HOST=$PINNED_HOST" "$CH_ENV_LABELS" && echo 0 || echo 1 )"
check "ensurelabels(pinned host): the CREATE saw the SAME confirmed host" \
	"a label reported missing on one instance could be created on another" \
	"$( grep -Fxq -- "label create GITLAB_HOST=$PINNED_HOST" "$CH_ENV_LABELS" && echo 0 || echo 1 )"
check "ensurelabels(pinned host): NO glab invocation ran with GITLAB_HOST unset" \
	"a glab call resolved its host from ambient state instead of the confirmed one" \
	"$( grep -Fq -- 'GITLAB_HOST=<unset>' "$CH_ENV_LABELS" && echo 1 || echo 0 )"
check "ensurelabels(pinned host): --confirmed-host is NOT forwarded into the glab argv" "--confirmed-host leaked into the glab argv" \
	"$( argv_has_token "$CH_ARGV_LABELS" '--confirmed-host' && echo 1 || echo 0 )"

section "--confirmed-host — comment.sh"
CH_ENV_COMMENT_MISSING="$WORK/ch-env-comment-missing"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_ENV_LOG=$CH_ENV_COMMENT_MISSING" \
	sh "$COMMENT" --repo g/p --issue 5 --body-file "$CH_BODY"
expect_rc "comment(missing --confirmed-host): -> exit 2" 2
stderr_has "comment(missing --confirmed-host): diagnostic" "--confirmed-host is required"
file_missing "comment(missing --confirmed-host): glab was never invoked at all" "$CH_ENV_COMMENT_MISSING"
run 1 "GLAB_STUB_AUTHED=1" sh "$COMMENT" --repo g/p --issue 5 --body-file "$CH_BODY" --confirmed-host 'https://gitlab.com'
expect_rc "comment(scheme-qualified --confirmed-host): -> exit 2" 2
CH_ENV_COMMENT="$WORK/ch-env-comment"
CH_ARGV_COMMENT="$WORK/ch-argv-comment"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_NOTE_OUT=" "GLAB_STUB_ENV_LOG=$CH_ENV_COMMENT" "GLAB_STUB_NOTE_LOG=$CH_ARGV_COMMENT" \
	sh "$COMMENT" --repo g/p --issue 5 --body-file "$CH_BODY" --confirmed-host "$PINNED_HOST"
expect_rc "comment(pinned host): -> exit 0" 0
check "comment(pinned host): glab issue note saw GITLAB_HOST equal to --confirmed-host" \
	"expected 'issue note GITLAB_HOST=$PINNED_HOST'; env log: $(cat "$CH_ENV_COMMENT" 2>/dev/null | tr '\n' '|')" \
	"$( grep -Fxq -- "issue note GITLAB_HOST=$PINNED_HOST" "$CH_ENV_COMMENT" && echo 0 || echo 1 )"
check "comment(pinned host): NO glab invocation ran with GITLAB_HOST unset" \
	"a glab call resolved its host from ambient state instead of the confirmed one" \
	"$( grep -Fq -- 'GITLAB_HOST=<unset>' "$CH_ENV_COMMENT" && echo 1 || echo 0 )"
check "comment(pinned host): --confirmed-host is NOT forwarded into the glab argv" "--confirmed-host leaked into the glab argv" \
	"$( argv_has_token "$CH_ARGV_COMMENT" '--confirmed-host' && echo 1 || echo 0 )"

section "--confirmed-host — update-issue.sh"
CH_ENV_UPDATE_MISSING="$WORK/ch-env-update-missing"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_ENV_LOG=$CH_ENV_UPDATE_MISSING" \
	sh "$UPDATE" --repo g/p --issue 5 --title x
expect_rc "update(missing --confirmed-host): -> exit 2" 2
stderr_has "update(missing --confirmed-host): diagnostic" "--confirmed-host is required"
file_missing "update(missing --confirmed-host): glab was never invoked at all" "$CH_ENV_UPDATE_MISSING"
run 1 "GLAB_STUB_AUTHED=1" sh "$UPDATE" --repo g/p --issue 5 --title x --confirmed-host 'https://gitlab.com'
expect_rc "update(scheme-qualified --confirmed-host): -> exit 2" 2
CH_ENV_UPDATE="$WORK/ch-env-update"
CH_ARGV_UPDATE="$WORK/ch-argv-update"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_OUT=" "GLAB_STUB_ENV_LOG=$CH_ENV_UPDATE" "GLAB_STUB_UPDATE_LOG=$CH_ARGV_UPDATE" \
	sh "$UPDATE" --repo g/p --issue 5 --title x --confirmed-host "$PINNED_HOST"
expect_rc "update(pinned host): -> exit 0" 0
check "update(pinned host): glab issue update saw GITLAB_HOST equal to --confirmed-host" \
	"expected 'issue update GITLAB_HOST=$PINNED_HOST'; env log: $(cat "$CH_ENV_UPDATE" 2>/dev/null | tr '\n' '|')" \
	"$( grep -Fxq -- "issue update GITLAB_HOST=$PINNED_HOST" "$CH_ENV_UPDATE" && echo 0 || echo 1 )"
check "update(pinned host): NO glab invocation ran with GITLAB_HOST unset" \
	"a glab call resolved its host from ambient state instead of the confirmed one" \
	"$( grep -Fq -- 'GITLAB_HOST=<unset>' "$CH_ENV_UPDATE" && echo 1 || echo 0 )"
check "update(pinned host): --confirmed-host is NOT forwarded into the glab argv" "--confirmed-host leaked into the glab argv" \
	"$( argv_has_token "$CH_ARGV_UPDATE" '--confirmed-host' && echo 1 || echo 0 )"

section "--confirmed-host — close-issue.sh"
CH_ENV_CLOSE_MISSING="$WORK/ch-env-close-missing"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_ENV_LOG=$CH_ENV_CLOSE_MISSING" \
	sh "$CLOSE" --repo g/p --issue 5
expect_rc "close(missing --confirmed-host): -> exit 2" 2
stderr_has "close(missing --confirmed-host): diagnostic" "--confirmed-host is required"
file_missing "close(missing --confirmed-host): glab was never invoked at all" "$CH_ENV_CLOSE_MISSING"
run 1 "GLAB_STUB_AUTHED=1" sh "$CLOSE" --repo g/p --issue 5 --confirmed-host 'https://gitlab.com'
expect_rc "close(scheme-qualified --confirmed-host): -> exit 2" 2
CH_ENV_CLOSE="$WORK/ch-env-close"
CH_ARGV_CLOSE="$WORK/ch-argv-close"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_ENV_LOG=$CH_ENV_CLOSE" "GLAB_STUB_CLOSE_LOG=$CH_ARGV_CLOSE" \
	sh "$CLOSE" --repo g/p --issue 5 --comment-file "$CH_BODY" --confirmed-host "$PINNED_HOST"
expect_rc "close(pinned host): -> exit 0" 0
check "close(pinned host): the preceding NOTE saw the confirmed host" \
	"expected 'issue note GITLAB_HOST=$PINNED_HOST'; env log: $(cat "$CH_ENV_CLOSE" 2>/dev/null | tr '\n' '|')" \
	"$( grep -Fxq -- "issue note GITLAB_HOST=$PINNED_HOST" "$CH_ENV_CLOSE" && echo 0 || echo 1 )"
check "close(pinned host): the CLOSE saw the SAME confirmed host" \
	"the two halves of this two-step operation could land on different instances" \
	"$( grep -Fxq -- "issue close GITLAB_HOST=$PINNED_HOST" "$CH_ENV_CLOSE" && echo 0 || echo 1 )"
check "close(pinned host): NO glab invocation ran with GITLAB_HOST unset" \
	"a glab call resolved its host from ambient state instead of the confirmed one" \
	"$( grep -Fq -- 'GITLAB_HOST=<unset>' "$CH_ENV_CLOSE" && echo 1 || echo 0 )"
check "close(pinned host): --confirmed-host is NOT forwarded into the glab argv" "--confirmed-host leaked into the glab argv" \
	"$( argv_has_token "$CH_ARGV_CLOSE" '--confirmed-host' && echo 1 || echo 0 )"

# ===========================================================================
# create-issue.sh
# ===========================================================================
section "create-issue.sh — usage / argument errors"
run 1 sh "$CREATE" --confirmed-host gitlab.com -h
expect_rc "create(usage): -h -> exit 0" 0
stdout_has "create(usage): help text" "Usage:"

BODY1="$WORK/body1.md"
printf '## Story\nAs a user...\n' >"$BODY1"

run 1 sh "$CREATE" --confirmed-host gitlab.com --title x --body-file "$BODY1"
expect_rc "create(missing --repo): -> exit 2" 2
stderr_has "create(missing --repo): diagnostic" "--repo is required"

run 1 sh "$CREATE" --confirmed-host gitlab.com --repo g/p --body-file "$BODY1"
expect_rc "create(missing --title): -> exit 2" 2
stderr_has "create(missing --title): diagnostic" "--title is required"

run 1 sh "$CREATE" --confirmed-host gitlab.com --repo g/p --title x
expect_rc "create(missing --body-file): -> exit 2" 2
stderr_has "create(missing --body-file): diagnostic" "--body-file is required"

run 1 sh "$CREATE" --confirmed-host gitlab.com --repo g/p --title x --body-file "$WORK/does-not-exist"
expect_rc "create(nonexistent body-file): -> exit 2" 2
stderr_has "create(nonexistent body-file): diagnostic" "does not exist or is not readable"

if [ "$IS_ROOT" -eq 1 ]; then
	skip "create(unreadable body-file): running as root — chmod 000 has no effect"
else
	UNREADABLE="$WORK/unreadable-body.md"
	printf 'body\n' >"$UNREADABLE"
	chmod 000 "$UNREADABLE"
	run 1 sh "$CREATE" --confirmed-host gitlab.com --repo g/p --title x --body-file "$UNREADABLE"
	expect_rc "create(unreadable body-file): -> exit 2" 2
	stderr_has "create(unreadable body-file): diagnostic" "does not exist or is not readable"
	chmod 644 "$UNREADABLE"
fi

run 1 sh "$CREATE" --confirmed-host gitlab.com --repo g/p --title x --body-file "$WORK/empty-body.md"
expect_rc "create(empty body-file): -> exit 2" 2
stderr_has "create(empty body-file): diagnostic" "is empty"

CREATE_LOG_DASH="$WORK/create-log-dash"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_CREATE_LOG=$CREATE_LOG_DASH" \
	sh "$CREATE" --confirmed-host gitlab.com --repo g/p --title x --body-file "$WORK/dash-body.md"
expect_rc "create(body is literally '-'): -> exit 2 (glab would open an editor and hang)" 2
stderr_has "create('-' guard): explains the editor hazard" "interactive editor"
file_missing "create('-' guard): glab issue create never invoked" "$CREATE_LOG_DASH"

run 1 sh "$CREATE" --confirmed-host gitlab.com --repo lonelyproject --title x --body-file "$BODY1"
expect_rc "create(single-segment path): REJECTED (a bare name is not a path) -> exit 2" 2
stderr_has "create(single-segment path): diagnostic" "at least one '/'"

run 1 sh "$CREATE" --confirmed-host gitlab.com --repo 'g/..' --title x --body-file "$BODY1"
expect_rc "create(traversal '..' segment): -> exit 2" 2
stderr_has "create(traversal): diagnostic" "GitLab project path"

run 1 sh "$CREATE" --confirmed-host gitlab.com --repo 'g/../p' --title x --body-file "$BODY1"
expect_rc "create(traversal mid-path): -> exit 2" 2

run 1 sh "$CREATE" --confirmed-host gitlab.com --repo 'g//p' --title x --body-file "$BODY1"
expect_rc "create(empty segment): -> exit 2" 2

run 1 sh "$CREATE" --confirmed-host gitlab.com --repo 'g/p; rm -rf /' --title x --body-file "$BODY1"
expect_rc "create(metacharacters in path): -> exit 2" 2

run 1 sh "$CREATE" --confirmed-host gitlab.com --bogus
expect_rc "create(unknown option): -> exit 2" 2
stderr_has "create(unknown option): diagnostic" "unknown option"

run 1 sh "$CREATE" --confirmed-host gitlab.com --repo g/p --title x --body-file "$BODY1" --epic 3
expect_rc "create(--epic rejected): native GitLab epics are deliberately not exposed -> exit 2" 2
stderr_has "create(--epic rejected): diagnostic" "unknown option: --epic"

section "create-issue.sh — glab absent / not authenticated"
run 0 sh "$CREATE" --confirmed-host gitlab.com --repo g/p --title x --body-file "$BODY1"
expect_rc "create(no-glab): -> exit 1" 1
stderr_has "create(no-glab): install hint" "gitlab-org/cli"

run 1 "GLAB_STUB_AUTHED=0" sh "$CREATE" --confirmed-host gitlab.com --repo g/p --title x --body-file "$BODY1"
expect_rc "create(unauth): -> exit 1" 1
stderr_has "create(unauth): diagnostic" "not authenticated"

section "create-issue.sh — missing label detected (no create attempted)"
CREATE_LOG1="$WORK/create-log1"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABELS=type:story
area:billing" "GLAB_STUB_CREATE_LOG=$CREATE_LOG1" \
	sh "$CREATE" --confirmed-host gitlab.com --repo g/p --title x --body-file "$BODY1" --label "type:story,area:reporting"
expect_rc "create(missing-label): -> exit 1" 1
stderr_has "create(missing-label): names the missing label" "area:reporting"
# Named for what it actually verifies: that 'type:story' appears NOWHERE on stderr.
# It used to be spelled as a compound grep reading like "the same line names the
# missing label but not the existing one" — but the leading
# `grep -Fq 'not found in project'` is unconditionally true in this scenario
# (stderr_has above already required that line), so it constrained nothing and
# only obscured the real assertion.
check "create(missing-label): stderr never mentions the label that DOES exist" "an existing label was named in the missing-label diagnostic" \
	"$( printf '%s\n' "$CUR_ERR" | grep -Fq -- 'type:story' && echo 1 || echo 0 )"
file_missing "create(missing-label): glab issue create never invoked" "$CREATE_LOG1"

section "create-issue.sh — label lookup itself fails (no create attempted)"
CREATE_LOG2="$WORK/create-log2"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABEL_LIST_RC=1" "GLAB_STUB_CREATE_LOG=$CREATE_LOG2" \
	sh "$CREATE" --confirmed-host gitlab.com --repo g/p --title x --body-file "$BODY1" --label "type:story"
expect_rc "create(label-lookup-fail): -> exit 1" 1
stderr_has "create(label-lookup-fail): reports failure" "failed to look up labels"
file_missing "create(label-lookup-fail): glab issue create never invoked" "$CREATE_LOG2"

section "create-issue.sh — the label PAGE WALK finds a label on page 2 (glab has no --paginate)"
LABEL_LIST_LOG_PAGED="$WORK/label-list-log-paged"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABELS=$FULL_LABEL_PAGE" "GLAB_STUB_LABELS_P2=on-page-two" \
	"GLAB_STUB_LABEL_LIST_LOG=$LABEL_LIST_LOG_PAGED" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title x --body-file "$BODY1" --label "on-page-two"
expect_rc "create(paged-label): a label only on page 2 is FOUND, create proceeds -> exit 0" 0
stdout_has "create(paged-label): the create really happened" "PM_ISSUE_URL="
check "create(paged-label): --per-page 100 requested (glab defaults to only 30)" "no '--per-page 100' pair in the label list argv" \
	"$( argv_has_pair "$LABEL_LIST_LOG_PAGED" '--per-page' '100' && echo 0 || echo 1 )"
check "create(paged-label): page 2 was actually requested" "the page walk stopped at page 1" \
	"$( argv_has_pair "$LABEL_LIST_LOG_PAGED" '--page' '2' && echo 0 || echo 1 )"
check "create(paged-label): exactly TWO label list calls (a short page ends the walk)" "expected 2 ARGV_BEGIN blocks in the label list log" \
	"$( [ "$(grep -Fxc -- 'ARGV_BEGIN' "$LABEL_LIST_LOG_PAGED")" -eq 2 ] && echo 0 || echo 1 )"

section "create-issue.sh — missing milestone detected (no create attempted)"
CREATE_LOG3="$WORK/create-log3"
MILESTONE_LOG1="$WORK/milestone-log1"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MILESTONES=Q1
Q2" "GLAB_STUB_CREATE_LOG=$CREATE_LOG3" "GLAB_STUB_MILESTONE_LIST_LOG=$MILESTONE_LOG1" \
	sh "$CREATE" --confirmed-host gitlab.com --repo g/p --title x --body-file "$BODY1" --milestone "Q3"
expect_rc "create(missing-milestone): -> exit 1" 1
stderr_has "create(missing-milestone): names it" "Q3"
file_missing "create(missing-milestone): glab issue create never invoked" "$CREATE_LOG3"
check "create(missing-milestone): the lookup was scoped server-side with --title" "no '--title Q3' pair in the milestone list argv" \
	"$( argv_has_pair "$MILESTONE_LOG1" '--title' 'Q3' && echo 0 || echo 1 )"

section "create-issue.sh — existing milestone passes the pre-check"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MILESTONES=Q1
Q3" sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title x --body-file "$BODY1" --milestone "Q3"
expect_rc "create(existing-milestone): -> exit 0" 0

section "create-issue.sh — milestone lookup itself fails (no create attempted)"
CREATE_LOG4="$WORK/create-log4"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_MILESTONE_LIST_RC=1" "GLAB_STUB_CREATE_LOG=$CREATE_LOG4" \
	sh "$CREATE" --confirmed-host gitlab.com --repo g/p --title x --body-file "$BODY1" --milestone "Q3"
expect_rc "create(milestone-lookup-fail): -> exit 1" 1
stderr_has "create(milestone-lookup-fail): reports failure" "failed to look up milestones"
file_missing "create(milestone-lookup-fail): glab issue create never invoked" "$CREATE_LOG4"

section "create-issue.sh — successful create (deep path, labels, milestone, assignees)"
CREATE_LOG5="$WORK/create-log5"
CREATE5_DESC_SEEN="$WORK/create5-description-seen"
# GLAB_STUB_CREATE_OUT is spelled out (rather than left on the stub default)
# because the URL must live under the project this run actually names: the URL
# extractor requires the matched token's path to contain the confirmed --repo
# value, so a URL for some OTHER project is — correctly — not accepted as this
# issue's URL. See the "URL-shaped title" section further down for why.
DEEP_ISSUE_URL="https://gitlab.com/$DEEP_PATH/-/work_items/7"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABELS=type:story
area:billing" "GLAB_STUB_MILESTONES=Q3" \
	"GLAB_STUB_CREATE_LOG=$CREATE_LOG5" "GLAB_STUB_DESC_FILE=$CREATE5_DESC_SEEN" \
	"GLAB_STUB_CREATE_OUT=#7 As a user, I can export
 $DEEP_ISSUE_URL" \
	sh "$CREATE" --confirmed-host gitlab.com --repo "$DEEP_PATH" --title "As a user, I can export" --body-file "$BODY1" \
		--label "type:story,area:billing" --milestone "Q3" --assignee "alice,bob"
expect_rc "create(success): -> exit 0" 0
stdout_has "create(success): PM_ISSUE_NUMBER parsed from the URL tail (the iid)" "PM_ISSUE_NUMBER=7"
stdout_has "create(success): PM_ISSUE_URL (the real '/-/work_items/<iid>' shape)" "PM_ISSUE_URL=$DEEP_ISSUE_URL"
check "create(success): --repo (3-segment) passed as one token" "deep repo path missing/mangled in argv" \
	"$( argv_has_pair "$CREATE_LOG5" '--repo' "$DEEP_PATH" && echo 0 || echo 1 )"
check "create(success): --title passed as one token (even multi-word)" "title missing/misplaced in argv" \
	"$( argv_has_pair "$CREATE_LOG5" '--title' 'As a user, I can export' && echo 0 || echo 1 )"
check "create(success): --yes present (without it glab would prompt and hang)" "no --yes token in argv" \
	"$( argv_has_token "$CREATE_LOG5" '--yes' && echo 0 || echo 1 )"
check "create(success): --label type:feature-style value from a comma-list passed" "label type:story missing from argv" \
	"$( argv_has_pair "$CREATE_LOG5" '--label' 'type:story' && echo 0 || echo 1 )"
check "create(success): --label area:billing (from the SAME comma-list) also passed" "second comma-split label missing from argv" \
	"$( argv_has_pair "$CREATE_LOG5" '--label' 'area:billing' && echo 0 || echo 1 )"
check "create(success): --milestone Q3 passed as one token" "milestone missing/misplaced in argv" \
	"$( argv_has_pair "$CREATE_LOG5" '--milestone' 'Q3' && echo 0 || echo 1 )"
check "create(success): --assignee alice passed" "assignee alice missing from argv" \
	"$( argv_has_pair "$CREATE_LOG5" '--assignee' 'alice' && echo 0 || echo 1 )"
check "create(success): --assignee bob (from the same comma-list) passed" "assignee bob missing from argv" \
	"$( argv_has_pair "$CREATE_LOG5" '--assignee' 'bob' && echo 0 || echo 1 )"
check "create(success): argv carries a --description token (glab's only body mechanism)" "no --description token in argv" \
	"$( argv_has_token "$CREATE_LOG5" '--description' && echo 0 || echo 1 )"
check "create(success): argv has NO --description-file token (glab has no such flag)" "a --description-file token was passed to glab" \
	"$( argv_has_token "$CREATE_LOG5" '--description-file' && echo 1 || echo 0 )"
check "create(success): argv has NO --body-file token (that is the GitHub sibling's flag)" "a --body-file token leaked into the glab argv" \
	"$( argv_has_token "$CREATE_LOG5" '--body-file' && echo 1 || echo 0 )"
check "create(success): argv has NO --epic token" "an --epic token was passed; native epics are deliberately not used" \
	"$( argv_has_token "$CREATE_LOG5" '--epic' && echo 1 || echo 0 )"
if diff_value_file "$BODY1" "$CREATE5_DESC_SEEN"; then CREATE5_DIFF_RC=0; else CREATE5_DIFF_RC=1; fi
check "create(success): the description value glab received is byte-identical to the file" \
	"$(cat "$WORK/value_diff" 2>/dev/null)" \
	"$CREATE5_DIFF_RC"

section "create-issue.sh — a REPEATED flag accumulates as well as a comma-list does (TEST-002)"
# The documented contract is "repeatable AND/OR comma-separated", but every case
# above exercised only the comma-list half, so the repeated-occurrence half was
# untested for both list flags. An accumulator that OVERWROTE instead of appending
# (the obvious regression in a value-returning `accumulate`) would have kept the
# whole suite green.
CREATE_LOG_REPEAT="$WORK/create-log-repeated-flags"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABELS=first
second" "GLAB_STUB_CREATE_LOG=$CREATE_LOG_REPEAT" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title x --body-file "$BODY1" \
		--label first --label second --assignee alice --assignee bob
expect_rc "create(repeated flags): -> exit 0" 0
check "create(repeated flags): the FIRST --label survived" "an earlier --label was overwritten by the later one" \
	"$( argv_has_pair "$CREATE_LOG_REPEAT" '--label' 'first' && echo 0 || echo 1 )"
check "create(repeated flags): the SECOND --label arrived too" "the repeated --label never reached argv" \
	"$( argv_has_pair "$CREATE_LOG_REPEAT" '--label' 'second' && echo 0 || echo 1 )"
check "create(repeated flags): both repeated --assignee values arrived" "a repeated --assignee was lost" \
	"$( argv_has_pair "$CREATE_LOG_REPEAT" '--assignee' 'alice' && argv_has_pair "$CREATE_LOG_REPEAT" '--assignee' 'bob' && echo 0 || echo 1 )"

section "create-issue.sh — a comma-list with SPACES and EMPTY elements (TEST-003)"
# split_csv_list trims each token and drops empty ones, but no fixture anywhere
# contained a space or an empty element, so both behaviors were unexercised: a
# dropped trim would have sent glab the label " urgent" (a DIFFERENT label, which
# the existence pre-check would then reject), and a dropped empty-skip would have
# sent an empty argv value.
CREATE_LOG_TRIM="$WORK/create-log-trim"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABELS=bug
urgent" "GLAB_STUB_CREATE_LOG=$CREATE_LOG_TRIM" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title x --body-file "$BODY1" \
		--label "bug, urgent ,,"
expect_rc "create(csv trim): -> exit 0 (the trimmed names passed the existence pre-check)" 0
check "create(csv trim): 'bug' arrived clean" "the first token was mangled" \
	"$( argv_has_pair "$CREATE_LOG_TRIM" '--label' 'bug' && echo 0 || echo 1 )"
check "create(csv trim): ' urgent ' arrived TRIMMED to 'urgent'" "surrounding whitespace was not trimmed" \
	"$( argv_has_pair "$CREATE_LOG_TRIM" '--label' 'urgent' && echo 0 || echo 1 )"
check "create(csv trim): the UNTRIMMED ' urgent ' never reached argv" "an untrimmed token was passed to glab" \
	"$( argv_has_pair "$CREATE_LOG_TRIM" '--label' ' urgent ' && echo 1 || echo 0 )"
check "create(csv trim): the empty elements produced NO empty --label value" "an empty label value was passed to glab" \
	"$( argv_has_pair "$CREATE_LOG_TRIM" '--label' '' && echo 1 || echo 0 )"

section "create-issue.sh — a GLOB metacharacter in a comma-list stays literal (TEST-004)"
# split_csv_list wraps its `set -- \$value` in `set -f` precisely so the unquoted
# split cannot ALSO filename-expand. No fixture contained a glob character, so
# deleting that guard broke nothing visible — while in real use a label of '*' would
# have been replaced by the cwd's file names.
CREATE_LOG_GLOB="$WORK/create-log-glob"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABELS=*" "GLAB_STUB_CREATE_LOG=$CREATE_LOG_GLOB" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title x --body-file "$BODY1" --label '*'
expect_rc "create(glob label): -> exit 0" 0
check "create(glob label): the literal '*' reached argv (it was NOT filename-expanded)" \
	"the '*' was glob-expanded against the cwd instead of staying literal" \
	"$( argv_has_pair "$CREATE_LOG_GLOB" '--label' '*' && echo 0 || echo 1 )"

section "create-issue.sh — glab issue create itself fails"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_CREATE_RC=1" sh "$CREATE" --confirmed-host gitlab.com --repo g/p --title x --body-file "$BODY1"
expect_rc "create(glab-fail): -> exit 1" 1
stderr_has "create(glab-fail): reports failure" "glab issue create failed"

section "create-issue.sh — glab issue create succeeds but prints NO URL"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_CREATE_OUT=" sh "$CREATE" --confirmed-host gitlab.com --repo g/p --title x --body-file "$BODY1"
expect_rc "create(no-url): -> exit 1" 1
stderr_has "create(no-url): diagnostic" "printed no issue URL"
stderr_has "create(no-url): warns the issue may exist anyway" "may nonetheless have been created"

section "create-issue.sh — the URL is found by SHAPE inside glab's decorated output"
# This case ALSO carries the backward-shape proof for create: the classic
# '/-/issues/<iid>' path must keep working, because an older self-managed
# instance may still emit it even though gitlab.com has migrated to
# '/-/work_items/<iid>' (which the stub default covers, above).
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_CREATE_OUT=Creating issue in deep/group/nest/proj

#123 A title
 https://gitlab.example.com/deep/group/nest/proj/-/issues/123" \
	sh "$CREATE" --confirmed-host gitlab.com --repo deep/group/nest/proj --title t --body-file "$BODY1"
expect_rc "create(decorated-output): -> exit 0" 0
stdout_has "create(decorated-output): iid taken from the URL tail, not the '#123' banner" "PM_ISSUE_NUMBER=123"
stdout_has "create(decorated-output): self-managed CLASSIC '/-/issues/' URL relayed intact" "PM_ISSUE_URL=https://gitlab.example.com/deep/group/nest/proj/-/issues/123"

section "create-issue.sh — the work-items URL shape survives glab's decoration too"
# The regression that made this fix necessary: glab prints '/-/work_items/<iid>'
# and the shape matcher accepted only '/-/issues/', so this script aborted with
# "reported success but printed no issue URL" on an issue it HAD created. A
# decorated multi-line block is asserted separately from the stub default because
# the matcher scans token-by-token across every line, not just line 1.
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_CREATE_OUT=Creating issue in deep/group/nest/proj

#456 A title
 https://gitlab.example.com/deep/group/nest/proj/-/work_items/456" \
	sh "$CREATE" --confirmed-host gitlab.com --repo deep/group/nest/proj --title t --body-file "$BODY1"
expect_rc "create(work-items-decorated): -> exit 0, NOT the 'printed no issue URL' abort" 0
stdout_has "create(work-items-decorated): iid taken from the work-items URL tail" "PM_ISSUE_NUMBER=456"
stdout_has "create(work-items-decorated): self-managed work-items URL relayed intact" "PM_ISSUE_URL=https://gitlab.example.com/deep/group/nest/proj/-/work_items/456"

section "create-issue.sh — a URL whose path segment is NEITHER issues NOR work_items is not accepted"
# Guards the broadening from going too far: only the two known issue paths count,
# so an unrelated merge-request or epic URL in the same output can never be
# mistaken for the created issue's URL.
#
# --repo MUST MATCH THE FIXTURE URL'S OWN PROJECT PATH. This case used to pass
# --repo g/p while the fixture URL named group/sub/proj, so the PROJECT filter
# rejected the token before the path-SHAPE restriction was ever consulted — the
# case was green for the wrong reason and would have stayed green if the
# issues/work_items restriction were deleted outright. With the paths matched, the
# only thing that can reject this token is the shape restriction under test.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_CREATE_OUT=https://gitlab.com/group/sub/proj/-/merge_requests/9" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title x --body-file "$BODY1"
expect_rc "create(wrong-path-segment): -> exit 1" 1
stderr_has "create(wrong-path-segment): a merge_requests URL of THIS project is still not an issue URL" "printed no issue URL"

section "create-issue.sh — adversarial body reaches glab verbatim and inert (flagship proof)"
ADVERSARIAL="$WORK/adversarial-body.md"
cat >"$ADVERSARIAL" <<'BODY_EOF'
## Story
As a user, I want the export so that I stop re-keying data.

PM_ARTIFACT_BODY
EOF
this line runs $(whoami) and `id` if the body were ever evaluated as shell
'; rm -rf /; echo '
## Out of scope
- nothing else

BODY_EOF
CREATE_LOG6="$WORK/create-log6"
DESC_SEEN="$WORK/description-seen"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_CREATE_LOG=$CREATE_LOG6" "GLAB_STUB_DESC_FILE=$DESC_SEEN" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title "adversarial body test" --body-file "$ADVERSARIAL"
expect_rc "create(adversarial): -> exit 0 (the bytes are argv data, not shell)" 0
stdout_has "create(adversarial): still succeeds normally" "PM_ISSUE_URL=https://gitlab.com/group/sub/proj/-/work_items/7"
# The authoritative proof: what glab received is BYTE-IDENTICAL to the source
# fixture. This subsumes "the delimiter lines survived", "the $(...)/backtick
# line is inert", and "trailing content wasn't truncated" — any evaluation,
# truncation, or a stripped trailing newline would show up as a diff line.
if diff_value_file "$ADVERSARIAL" "$DESC_SEEN"; then DESC_DIFF_RC=0; else DESC_DIFF_RC=1; fi
check "create(adversarial): description reached glab BYTE-IDENTICAL, trailing newlines included" \
	"$(cat "$WORK/value_diff" 2>/dev/null)" \
	"$DESC_DIFF_RC"
# shellcheck disable=SC2016  # the $(...) and backticks are the payload under test: they MUST stay literal here, never be expanded by this harness
check "create(adversarial): the metacharacter lines survived unexpanded" "shell metacharacters were expanded or dropped" \
	"$( value_block "$CREATE_LOG6" 'DESCRIPTION_VALUE' | grep -Fq -- 'runs $(whoami) and `id`' && echo 0 || echo 1 )"
check "create(adversarial): argv has NO --description-file token" "a --description-file token was passed to glab" \
	"$( argv_has_token "$CREATE_LOG6" '--description-file' && echo 1 || echo 0 )"

section "create-issue.sh — a URL-shaped TITLE cannot hijack the extracted URL (SEC-001)"
# THE LIVE-OBSERVED BUG THIS PINS: `glab issue create` prints the issue TITLE on
# the line BEFORE the URL, and the extractor used to take the FIRST shape-matching
# token anywhere in the captured output — so a title containing something
# URL-shaped won, and PM_ISSUE_URL/PM_ISSUE_NUMBER came back pointing at whatever
# the title said. A follow-up comment.sh or link-children.sh keyed off
# PM_ISSUE_NUMBER would then write to the WRONG issue.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_CREATE_OUT=#7 See also https://evil.example/attacker/project/-/issues/1
 https://gitlab.com/group/sub/proj/-/work_items/7" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title "See also https://evil.example/attacker/project/-/issues/1" --body-file "$BODY1"
expect_rc "create(url-shaped title): -> exit 0" 0
stdout_has "create(url-shaped title): PM_ISSUE_URL is the REAL URL, not the title's" "PM_ISSUE_URL=https://gitlab.com/group/sub/proj/-/work_items/7"
stdout_has "create(url-shaped title): PM_ISSUE_NUMBER is the REAL iid, not the title's '1'" "PM_ISSUE_NUMBER=7"
check "create(url-shaped title): the attacker URL never reaches stdout" "the title's URL was relayed to the caller" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'evil.example' && echo 1 || echo 0 )"

# A title on ANOTHER PROJECT of the same host is rejected by the same rule — the
# match requires the confirmed --repo path, not merely a GitLab-looking URL.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_CREATE_OUT=#7 Follows https://gitlab.com/other/team/proj/-/issues/999
 https://gitlab.com/group/sub/proj/-/work_items/7" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title "Follows https://gitlab.com/other/team/proj/-/issues/999" --body-file "$BODY1"
expect_rc "create(other-project URL in title): -> exit 0" 0
stdout_has "create(other-project URL in title): PM_ISSUE_NUMBER is this project's iid" "PM_ISSUE_NUMBER=7"
check "create(other-project URL in title): the other project's iid is never relayed" "an unrelated project's issue number was relayed" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- '999' && echo 1 || echo 0 )"

# A title that quotes the REAL URL verbatim is NOT ambiguity: identical tokens
# collapse to one candidate, so this must still succeed rather than fail closed.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_CREATE_OUT=#7 Supersedes https://gitlab.com/group/sub/proj/-/work_items/7
 https://gitlab.com/group/sub/proj/-/work_items/7" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title "Supersedes https://gitlab.com/group/sub/proj/-/work_items/7" --body-file "$BODY1"
expect_rc "create(title repeats the real URL): -> exit 0 (identical tokens are one candidate)" 0
stdout_has "create(title repeats the real URL): PM_ISSUE_URL still relayed" "PM_ISSUE_URL=https://gitlab.com/group/sub/proj/-/work_items/7"

section "create-issue.sh — the project filter is ANCHORED to the host (SEC-002)"
# THE RESIDUAL GAP: the filter was `index($i, "/" repo "/")` — an UNANCHORED
# substring test. It accepted the project path at ANY depth under ANY host, so
# "https://attacker.example/x/group/sub/proj/-/issues/5" qualified as a URL of THIS
# project. The ambiguity guard normally caught it (a genuine URL is present too,
# making 2+ candidates), but a filter must not lean on its own backstop: here the
# spoof is the ONLY shape-matching token in the output, so the guard has nothing to
# compare it against and the anchor is the only thing that can reject it.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_CREATE_OUT=#5 See https://attacker.example/x/group/sub/proj/-/issues/5" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj \
		--title "See https://attacker.example/x/group/sub/proj/-/issues/5" --body-file "$BODY1"
expect_rc "create(unanchored spoof, sole candidate): -> exit 1 (no URL found at all)" 1
stderr_has "create(unanchored spoof): reports NO URL rather than accepting the spoof" "printed no issue URL"
check "create(unanchored spoof): the attacker URL is never relayed" \
	"an extra leading path segment let a foreign host masquerade as this project" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'attacker.example' && echo 1 || echo 0 )"

# A DEEPER burial must fail too — the anchor requires the repo path immediately
# after the host, at any depth, not just one extra segment.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_CREATE_OUT=#5 See https://gitlab.com/mirror/of/group/sub/proj/-/work_items/5" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj \
		--title "See https://gitlab.com/mirror/of/group/sub/proj/-/work_items/5" --body-file "$BODY1"
expect_rc "create(project path buried deeper, sole candidate): -> exit 1" 1
stderr_has "create(buried project path): reports NO URL" "printed no issue URL"

# The anchor deliberately does NOT check the host itself, so a FOREIGN host that
# carries the repo path directly IS still a candidate — and the pre-existing
# ambiguity guard is what must fail it closed. Asserted so the anchor's scope stays
# honest: it removes the extra-segment/any-depth hole, not the host question.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_CREATE_OUT=#7 See https://evil.example/group/sub/proj/-/issues/9
 https://gitlab.com/group/sub/proj/-/work_items/7" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj \
		--title "See https://evil.example/group/sub/proj/-/issues/9" --body-file "$BODY1"
expect_rc "create(foreign host, no extra segment): -> exit 1 (the ambiguity guard fails it closed)" 1
stderr_has "create(foreign host, no extra segment): fails through the ambiguity guard" "MORE THAN ONE distinct issue URL"

section "create-issue.sh — TWO distinct project URLs fail CLOSED rather than guessing (SEC-001)"
# When the output really is ambiguous — two DIFFERENT issues of THIS project —
# there is no safe way to pick one, so the script must refuse instead of relaying
# a coin flip that later writes land on.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_CREATE_OUT=#7 Duplicate of https://gitlab.com/group/sub/proj/-/issues/4
 https://gitlab.com/group/sub/proj/-/work_items/7" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title "Duplicate of https://gitlab.com/group/sub/proj/-/issues/4" --body-file "$BODY1"
expect_rc "create(ambiguous URLs): -> exit 1 (fails closed, never guesses)" 1
stderr_has "create(ambiguous URLs): says why it refused" "MORE THAN ONE distinct issue URL"
stderr_has "create(ambiguous URLs): points at find-duplicate.sh to resolve it" "verify with find-duplicate.sh"
stderr_has "create(ambiguous URLs): still warns the issue may exist" "may nonetheless have been created"
check "create(ambiguous URLs): NO PM_ISSUE_URL is printed" "a guessed URL was relayed despite the ambiguity" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_ISSUE_URL=' && echo 1 || echo 0 )"
check "create(ambiguous URLs): NO PM_ISSUE_NUMBER is printed" "a guessed iid was relayed despite the ambiguity" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_ISSUE_NUMBER=' && echo 1 || echo 0 )"

section "create-issue.sh — the URL arriving ONLY on stderr still populates PM_ISSUE_URL"
# glab decorates its create output and may write part of it (the URL included) to
# STDERR, which is why create-issue.sh scans the captured stderr as a fallback.
# Nothing else in this suite can produce that stream, so without this case the
# whole fallback could be deleted with every test still green.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_CREATE_ERR_OUT=#7 As a user, I can export
 https://gitlab.com/group/sub/proj/-/work_items/7" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title x --body-file "$BODY1"
expect_rc "create(url-on-stderr): -> exit 0" 0
stdout_has "create(url-on-stderr): PM_ISSUE_URL recovered from stderr" "PM_ISSUE_URL=https://gitlab.com/group/sub/proj/-/work_items/7"
stdout_has "create(url-on-stderr): PM_ISSUE_NUMBER recovered from stderr" "PM_ISSUE_NUMBER=7"

section "create-issue.sh — a spoof on stdout cannot outrank the genuine URL on stderr (SEC-003)"
# THE RESIDUAL GAP THIS PINS, and why SEC-001's fix did not already cover it: the
# extractor used to scan stdout FIRST and consult stderr only as a FALLBACK, when
# stdout had yielded nothing at all. The repo filter checks that a candidate's PATH
# contains "/<repo>/" — it does NOT check the HOST. So when glab put the real URL on
# stderr while echoing a URL-shaped TITLE on stdout, an attacker-crafted title
# carrying this project's path under a foreign host was the ONLY candidate the
# ambiguity guard ever saw (stderr was never read) and won by default — the exact
# class SEC-001 closed, reached through the one door left open. Anything keyed off
# PM_ISSUE_NUMBER afterwards (comment.sh, link-children.sh) would then write to
# whatever the title said.
#
# The fix pools BOTH streams before extracting, so the spoof and the genuine URL are
# seen together as 2 distinct candidates and the existing guard fails closed. Note
# the spoofed iid is 7 — the SAME as the real issue's — so nothing but the unified
# scan can tell them apart here.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_CREATE_OUT=#7 See also https://evil.example/group/sub/proj/-/issues/7" \
	"GLAB_STUB_CREATE_ERR_OUT= https://gitlab.com/group/sub/proj/-/work_items/7" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title "See also https://evil.example/group/sub/proj/-/issues/7" --body-file "$BODY1"
expect_rc "create(stdout spoof vs stderr URL): -> exit 1 (fails closed, never guesses)" 1
stderr_has "create(stdout spoof vs stderr URL): both streams' candidates reached the ambiguity guard" "MORE THAN ONE distinct issue URL"
check "create(stdout spoof vs stderr URL): the attacker URL is never relayed as PM_ISSUE_URL" "the spoofed stdout URL won because stderr was not consulted" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'evil.example' && echo 1 || echo 0 )"
check "create(stdout spoof vs stderr URL): NO PM_ISSUE_URL is printed at all" "a URL was relayed despite the ambiguity" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_ISSUE_URL=' && echo 1 || echo 0 )"
check "create(stdout spoof vs stderr URL): NO PM_ISSUE_NUMBER is printed at all" "an iid was relayed despite the ambiguity" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_ISSUE_NUMBER=' && echo 1 || echo 0 )"

# The mirror image — spoof on STDERR, genuine URL on stdout — must fail closed too:
# the pool is symmetric, so neither stream is privileged.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_CREATE_OUT= https://gitlab.com/group/sub/proj/-/work_items/7" \
	"GLAB_STUB_CREATE_ERR_OUT=note: see https://evil.example/group/sub/proj/-/issues/7" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title x --body-file "$BODY1"
expect_rc "create(stderr spoof vs stdout URL): -> exit 1 (the pool is symmetric)" 1
stderr_has "create(stderr spoof vs stdout URL): same fail-closed diagnostic" "MORE THAN ONE distinct issue URL"
check "create(stderr spoof vs stdout URL): the attacker URL is never relayed" "the spoof was accepted from stderr" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'evil.example' && echo 1 || echo 0 )"

section "create-issue.sh — a label whose NAME contains a double quote is matched exactly"
# The label lookup strips only a SURROUNDING PAIR of quotes from glab's --jq rows.
# A global strip (the old `gsub(/"/, "")`) turned a label literally named
# `say "hi"` into `say hi`, which then failed the exact-match lookup and produced
# a "label not found" refusal for a label that exists.
run 1 "GLAB_STUB_AUTHED=1" 'GLAB_STUB_LABELS=say "hi"' \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title x --body-file "$BODY1" --label 'say "hi"'
expect_rc "create(quoted label name): the pre-check FINDS it, create proceeds -> exit 0" 0
stdout_has "create(quoted label name): the create really happened" "PM_ISSUE_NUMBER=7"

# The same row JSON-quoted by glab: the surrounding pair is removed, the INNER
# quotes are kept — which is the only way the exact match can still succeed.
run 1 "GLAB_STUB_AUTHED=1" 'GLAB_STUB_LABELS="say "hi""' \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title x --body-file "$BODY1" --label 'say "hi"'
expect_rc "create(quoted label name, JSON-quoted row): still found -> exit 0" 0

section "create-issue.sh — a ~300KB body (the argv/E2BIG boundary)"
# The whole body travels as ONE argv token, so it is bounded by a real OS limit,
# and that limit DIFFERS BY PLATFORM: macOS allows ~1MB for the whole argv block,
# while Linux caps a SINGLE argument at 128KB (MAX_ARG_STRLEN). This is therefore
# a CHARACTERIZATION test, not a promise: whichever way the platform goes, the
# script must either succeed cleanly or fail with ITS OWN diagnostic — never
# crash, and never report success without a URL. Both branches assert two checks,
# so the suite's total is platform-independent.
BIG_BODY="$WORK/big-body.md"
awk 'BEGIN { for (i = 0; i < 3000; i++) printf "%0100d\n", i }' >"$BIG_BODY"
BIG_BODY_SEEN="$WORK/big-body-seen"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_DESC_FILE=$BIG_BODY_SEEN" \
	sh "$CREATE" --confirmed-host gitlab.com --repo group/sub/proj --title x --body-file "$BIG_BODY"
if [ "$CUR_RC" -eq 0 ]; then
	stdout_has "create(300KB body): accepted by this platform's argv limit — URL still relayed" "PM_ISSUE_URL=https://gitlab.com/group/sub/proj/-/work_items/7"
	if diff_value_file "$BIG_BODY" "$BIG_BODY_SEEN"; then BIG_BODY_DIFF_RC=0; else BIG_BODY_DIFF_RC=1; fi
	check "create(300KB body): all ~300KB reached glab byte-identical (no truncation)" \
		"a large body was altered or truncated on its way into argv" \
		"$BIG_BODY_DIFF_RC"
else
	expect_rc "create(300KB body): rejected by the OS -> exit 1, the script's own failure path" 1
	stderr_has "create(300KB body): reported through the script's diagnostic, not as a bare crash" "glab issue create failed"
fi

# ===========================================================================
# find-duplicate.sh
# ===========================================================================
section "find-duplicate.sh — usage / argument errors"
run 1 sh "$FINDDUP" --confirmed-host gitlab.com -h
expect_rc "finddup(usage): -h -> exit 0" 0
stdout_has "finddup(usage): help text" "Usage:"

run 1 sh "$FINDDUP" --confirmed-host gitlab.com --title x
expect_rc "finddup(missing --repo): -> exit 2" 2
stderr_has "finddup(missing --repo): diagnostic" "--repo is required"

run 1 sh "$FINDDUP" --confirmed-host gitlab.com --repo g/p
expect_rc "finddup(missing --title/--search): -> exit 2" 2
stderr_has "finddup(missing --title/--search): diagnostic" "--title or --search is required"

run 1 sh "$FINDDUP" --confirmed-host gitlab.com --repo g/p --title x --search y
expect_rc "finddup(both --title and --search): -> exit 2" 2
stderr_has "finddup(both): diagnostic" "mutually exclusive"

run 1 sh "$FINDDUP" --confirmed-host gitlab.com --repo lonelyproject --title x
expect_rc "finddup(single-segment path): -> exit 2" 2
stderr_has "finddup(single-segment path): diagnostic" "at least one '/'"

run 1 sh "$FINDDUP" --confirmed-host gitlab.com --repo 'g/..' --title x
expect_rc "finddup(traversal path): -> exit 2" 2

run 1 sh "$FINDDUP" --confirmed-host gitlab.com --bogus
expect_rc "finddup(unknown option): -> exit 2" 2
stderr_has "finddup(unknown option): diagnostic" "unknown option"

section "find-duplicate.sh — glab absent / not authenticated"
run 0 sh "$FINDDUP" --confirmed-host gitlab.com --repo g/p --title x
expect_rc "finddup(no-glab): -> exit 1" 1
stderr_has "finddup(no-glab): install hint" "gitlab-org/cli"

run 1 "GLAB_STUB_AUTHED=0" sh "$FINDDUP" --confirmed-host gitlab.com --repo g/p --title x
expect_rc "finddup(unauth): -> exit 1" 1
stderr_has "finddup(unauth): diagnostic" "not authenticated"

section "find-duplicate.sh — hit (duplicates found)"
# Deliberately a MIXED-shape fixture. This script reads web_url straight out of
# --output json and relays it verbatim, so it never shape-matches and was never
# touched by the work-items URL migration; asserting both shapes pass through
# unaltered is what proves that independence rather than assuming it.
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LIST_URLS=https://gitlab.com/g/p/-/work_items/1
https://gitlab.com/g/p/-/issues/2" \
	sh "$FINDDUP" --confirmed-host gitlab.com --repo g/p --title "export to csv"
expect_rc "finddup(hit): -> exit 0" 0
stdout_has "finddup(hit): count 2" "PM_DUPLICATE_COUNT=2"
stdout_has "finddup(hit): both URL shapes relayed verbatim, comma-joined, in order" \
	"PM_DUPLICATE_URLS=https://gitlab.com/g/p/-/work_items/1,https://gitlab.com/g/p/-/issues/2"

section "find-duplicate.sh — miss (count 0 is success, not failure)"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LIST_URLS=" sh "$FINDDUP" --confirmed-host gitlab.com --repo g/p --search "csv export"
expect_rc "finddup(miss): -> exit 0 (zero is not a failure)" 0
stdout_has "finddup(miss): count 0" "PM_DUPLICATE_COUNT=0"
stdout_re "finddup(miss): urls empty" '^PM_DUPLICATE_URLS=$'

section "find-duplicate.sh — glab's --jq output normalization (quoted form)"
# Defensive: if glab renders a string --jq result JSON-quoted instead of raw,
# the URL must still be recovered.
run 1 "GLAB_STUB_AUTHED=1" 'GLAB_STUB_LIST_URLS="https://gitlab.com/g/p/-/issues/9"' \
	sh "$FINDDUP" --confirmed-host gitlab.com --repo g/p --title "quoted"
expect_rc "finddup(quoted-jq): -> exit 0" 0
stdout_has "finddup(quoted-jq): count 1" "PM_DUPLICATE_COUNT=1"
stdout_has "finddup(quoted-jq): url recovered unquoted" "PM_DUPLICATE_URLS=https://gitlab.com/g/p/-/issues/9"

section "find-duplicate.sh — the query reaches glab verbatim, scoped by FLAGS not query syntax"
LIST_LOG1="$WORK/issue-list-log1"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LIST_URLS=" "GLAB_STUB_LIST_LOG=$LIST_LOG1" \
	sh "$FINDDUP" --confirmed-host gitlab.com --repo "$DEEP_PATH" --title "export to csv"
expect_rc "finddup(query-title): -> exit 0" 0
check "finddup(query-title): --repo (3-segment) passed as one token" "deep repo path missing/mangled in argv" \
	"$( argv_has_pair "$LIST_LOG1" '--repo' "$DEEP_PATH" && echo 0 || echo 1 )"
check "finddup(query-title): --search is the caller's text as ONE token, nothing appended" \
	"the search value was word-split, or ' in:title' was appended GitHub-style" \
	"$( argv_has_pair "$LIST_LOG1" '--search' 'export to csv' && echo 0 || echo 1 )"
check "finddup(query-title): NO GitHub 'in:title' query syntax anywhere in argv" "GitHub search syntax leaked into a glab query" \
	"$( grep -Fq -- 'in:title' "$LIST_LOG1" && echo 1 || echo 0 )"
check "finddup(query-title): scoped with glab's --in title flag" "no '--in title' pair in argv" \
	"$( argv_has_pair "$LIST_LOG1" '--in' 'title' && echo 0 || echo 1 )"
check "finddup(query-title): --all present (glab lists only OPEN issues by default)" "no --all token in argv" \
	"$( argv_has_token "$LIST_LOG1" '--all' && echo 0 || echo 1 )"
check "finddup(query-title): NO --state flag (glab has no such flag)" "a --state token was passed; glab has no such flag" \
	"$( argv_has_token "$LIST_LOG1" '--state' && echo 1 || echo 0 )"
check "finddup(query-title): --output json passed as one token" "output json missing/misplaced in argv" \
	"$( argv_has_pair "$LIST_LOG1" '--output' 'json' && echo 0 || echo 1 )"
check "finddup(query-title): --jq selects .web_url" "the jq expression is missing or selects the wrong field" \
	"$( argv_has_pair "$LIST_LOG1" '--jq' '.[].web_url' && echo 0 || echo 1 )"
# glab's own default page size is 30 and it has no --paginate: without a larger
# page, a real duplicate past the 30th match is simply never seen and the caller
# is told "no duplicate" about an issue that exists.
check "finddup(query-title): --per-page 100 requested (glab defaults to only 30 results)" "no '--per-page 100' pair in argv — duplicates past the first page would be missed" \
	"$( argv_has_pair "$LIST_LOG1" '--per-page' '100' && echo 0 || echo 1 )"

section "find-duplicate.sh — --search mode passes its query verbatim too"
LIST_LOG2="$WORK/issue-list-log2"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LIST_URLS=" "GLAB_STUB_LIST_LOG=$LIST_LOG2" \
	sh "$FINDDUP" --confirmed-host gitlab.com --repo g/p --search "csv export tool"
expect_rc "finddup(query-search): -> exit 0" 0
check "finddup(query-search): --search composed as ONE token 'csv export tool'" \
	"a word-split --search value would show as separate argv lines, not one token" \
	"$( argv_has_pair "$LIST_LOG2" '--search' 'csv export tool' && echo 0 || echo 1 )"

section "find-duplicate.sh — glab issue list itself fails"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LIST_RC=1" sh "$FINDDUP" --confirmed-host gitlab.com --repo g/p --title x
expect_rc "finddup(glab-fail): -> exit 1" 1
stderr_has "finddup(glab-fail): reports failure" "glab issue list failed"

section "find-duplicate.sh — a SURROUNDING quote pair is stripped, an INNER one is not (CLEAN-004)"
# The normalization used to be a GLOBAL gsub(/"/, "") while its own siblings
# (create-issue.sh's list_all_labels, ensure-labels.sh) had been deliberately
# changed AWAY from exactly that form — and the comment here claimed parity with
# them. A web_url cannot contain a quote, so there was no live defect; the defect
# was the claim, and the trap it set for anyone copying the line into a value that
# CAN hold one. This pins the sibling behavior: the surrounding pair goes, anything
# inside the value stays.
run 1 "GLAB_STUB_AUTHED=1" 'GLAB_STUB_LIST_URLS="https://gitlab.com/g/p/-/issues/9?q=%22x%22"' \
	sh "$FINDDUP" --confirmed-host gitlab.com --repo g/p --title "quoted"
expect_rc "finddup(surrounding-pair strip): -> exit 0" 0
stdout_has "finddup(surrounding-pair strip): the outer pair is gone and the INNER quotes survive" \
	'PM_DUPLICATE_URLS=https://gitlab.com/g/p/-/issues/9?q=%22x%22'

section "find-duplicate.sh — a full page of results warns that the count is a FLOOR (OBS-004)"
# This script reads ONE page of SEARCH_PER_PAGE(=100) results, so a count that
# lands exactly on the page size may be truncated — the label lookups elsewhere in
# this skill warn on their own page cap, and this one did not. A caller that treats
# a truncated set as complete can decide "not a duplicate" on incomplete evidence.
FULL_SEARCH_PAGE=$(awk 'BEGIN { for (i = 1; i <= 100; i++) printf "https://gitlab.com/g/p/-/issues/%d\n", i }')
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LIST_URLS=$FULL_SEARCH_PAGE" \
	sh "$FINDDUP" --confirmed-host gitlab.com --repo g/p --title "export"
expect_rc "finddup(page cap): -> exit 0 (still a clean query)" 0
stdout_has "finddup(page cap): the count is still reported" "PM_DUPLICATE_COUNT=100"
stderr_has "finddup(page cap): warns the count is a floor, not a total" \
	"this count is a floor, not a total"
stderr_has "finddup(page cap): names the page limit it hit" "100-match page limit"

# One BELOW the page size must stay silent — a warning on every ordinary query
# would be noise, and this is what proves the trigger is the cap and not the size.
NEARLY_FULL_SEARCH_PAGE=$(awk 'BEGIN { for (i = 1; i <= 99; i++) printf "https://gitlab.com/g/p/-/issues/%d\n", i }')
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LIST_URLS=$NEARLY_FULL_SEARCH_PAGE" \
	sh "$FINDDUP" --confirmed-host gitlab.com --repo g/p --title "export"
expect_rc "finddup(just under the page cap): -> exit 0" 0
stdout_has "finddup(just under the page cap): count reported" "PM_DUPLICATE_COUNT=99"
check "finddup(just under the page cap): NO truncation warning (99 of 100 is a complete set)" \
	"the page-limit warning fired for a page that was not full" \
	"$( printf '%s\n' "$CUR_ERR" | grep -Fq -- 'page limit' && echo 1 || echo 0 )"

section "find-duplicate.sh — the READ-ONLY contract, asserted by mutation-log ABSENCE (TEST-006)"
# This script's header promises it "never writes anything". Every case above only
# ever asserted what it PRINTS, so a regression that added a create/update/note/
# close call would have left the whole suite green. Handing the stub every mutation
# log and requiring all of them to be ABSENT is what actually holds the promise: the
# stub only creates a log file when the matching subcommand is invoked.
FINDDUP_NO_CREATE="$WORK/finddup-must-not-create"
FINDDUP_NO_UPDATE="$WORK/finddup-must-not-update"
FINDDUP_NO_NOTE="$WORK/finddup-must-not-note"
FINDDUP_NO_CLOSE="$WORK/finddup-must-not-close"
FINDDUP_NO_LABEL_CREATE="$WORK/finddup-must-not-create-labels"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LIST_URLS=https://gitlab.com/g/p/-/issues/2" \
	"GLAB_STUB_CREATE_LOG=$FINDDUP_NO_CREATE" "GLAB_STUB_UPDATE_LOG=$FINDDUP_NO_UPDATE" \
	"GLAB_STUB_NOTE_LOG=$FINDDUP_NO_NOTE" "GLAB_STUB_CLOSE_LOG=$FINDDUP_NO_CLOSE" \
	"GLAB_STUB_LABEL_CREATE_LOG=$FINDDUP_NO_LABEL_CREATE" \
	sh "$FINDDUP" --confirmed-host gitlab.com --repo g/p --title "export"
expect_rc "finddup(read-only): -> exit 0" 0
stdout_has "finddup(read-only): the query really ran" "PM_DUPLICATE_COUNT=1"
file_missing "finddup(read-only): glab issue create was NEVER invoked" "$FINDDUP_NO_CREATE"
file_missing "finddup(read-only): glab issue update was NEVER invoked" "$FINDDUP_NO_UPDATE"
file_missing "finddup(read-only): glab issue note was NEVER invoked" "$FINDDUP_NO_NOTE"
file_missing "finddup(read-only): glab issue close was NEVER invoked" "$FINDDUP_NO_CLOSE"
file_missing "finddup(read-only): glab label create was NEVER invoked" "$FINDDUP_NO_LABEL_CREATE"

# ===========================================================================
# link-children.sh
# ===========================================================================
section "link-children.sh — usage / argument errors"
run 1 sh "$LINKKIDS" --confirmed-host gitlab.com -h
expect_rc "linkkids(usage): -h -> exit 0" 0
stdout_has "linkkids(usage): help text" "Usage:"

run 1 sh "$LINKKIDS" --confirmed-host gitlab.com --epic-issue 1 --child 2
expect_rc "linkkids(missing --repo): -> exit 2" 2
stderr_has "linkkids(missing --repo): diagnostic" "--repo is required"

run 1 sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --child 2
expect_rc "linkkids(missing --epic-issue): -> exit 2" 2
stderr_has "linkkids(missing --epic-issue): diagnostic" "--epic-issue is required"

run 1 sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 1
expect_rc "linkkids(missing --child): -> exit 2" 2
stderr_has "linkkids(missing --child): diagnostic" "at least one --child is required"

run 1 sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue abc --child 2
expect_rc "linkkids(non-numeric --epic-issue): -> exit 2" 2
stderr_has "linkkids(non-numeric --epic-issue): diagnostic" "positive integer"

run 1 sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 1 --child abc
expect_rc "linkkids(non-numeric --child): -> exit 2" 2

run 1 sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic 1 --child 2
expect_rc "linkkids(--epic rejected): the flag is --epic-issue, so nothing implies native GitLab epics -> exit 2" 2
stderr_has "linkkids(--epic rejected): diagnostic" "unknown option: --epic"

run 1 sh "$LINKKIDS" --confirmed-host gitlab.com --repo lonelyproject --epic-issue 1 --child 2
expect_rc "linkkids(single-segment path): -> exit 2" 2
stderr_has "linkkids(single-segment path): diagnostic" "at least one '/'"

run 1 sh "$LINKKIDS" --confirmed-host gitlab.com --repo 'g/..' --epic-issue 1 --child 2
expect_rc "linkkids(traversal path): -> exit 2" 2

run 1 sh "$LINKKIDS" --confirmed-host gitlab.com --bogus
expect_rc "linkkids(unknown option): -> exit 2" 2
stderr_has "linkkids(unknown option): diagnostic" "unknown option"

section "link-children.sh — glab absent / not authenticated"
run 0 sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 1 --child 2
expect_rc "linkkids(no-glab): -> exit 1" 1
stderr_has "linkkids(no-glab): install hint" "gitlab-org/cli"

run 1 "GLAB_STUB_AUTHED=0" sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 1 --child 2
expect_rc "linkkids(unauth): -> exit 1" 1
stderr_has "linkkids(unauth): diagnostic" "not authenticated"

section "link-children.sh — happy path (two new children)"
KIDS_DESC1="$WORK/linkkids-description1"
KIDS_UPDATE_LOG1="$WORK/linkkids-update-log1"
KIDS_VIEW_LOG1="$WORK/linkkids-view-log1"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_VIEW_BODY=## Outcome
Ship CSV export." "GLAB_STUB_DESC_FILE=$KIDS_DESC1" "GLAB_STUB_UPDATE_LOG=$KIDS_UPDATE_LOG1" \
	"GLAB_STUB_VIEW_LOG=$KIDS_VIEW_LOG1" \
	sh "$LINKKIDS" --confirmed-host gitlab.com --repo "$DEEP_PATH" --epic-issue 10 --child 11 --child 12
expect_rc "linkkids(happy): -> exit 0" 0
stdout_has "linkkids(happy): PM_LINKED=2" "PM_LINKED=2"
check "linkkids(happy): original description preserved" "original content lost" \
	"$( [ -f "$KIDS_DESC1" ] && grep -Fq 'Ship CSV export.' "$KIDS_DESC1" && echo 0 || echo 1 )"
check "linkkids(happy): the heading was added exactly once" "expected exactly one '## Linked children' line" \
	"$( line_count_eq "$KIDS_DESC1" '## Linked children' 1 && echo 0 || echo 1 )"
check "linkkids(happy): child 11 appended exactly once" "expected exactly one '- [ ] #11' line" \
	"$( line_count_eq "$KIDS_DESC1" '- [ ] #11' 1 && echo 0 || echo 1 )"
check "linkkids(happy): child 12 appended exactly once" "expected exactly one '- [ ] #12' line" \
	"$( line_count_eq "$KIDS_DESC1" '- [ ] #12' 1 && echo 0 || echo 1 )"
check "linkkids(happy): the epic iid is passed POSITIONALLY (glab takes <id>)" "the epic iid was not the first argv token" \
	"$( argv_first_is "$KIDS_UPDATE_LOG1" '10' && echo 0 || echo 1 )"
check "linkkids(happy): --repo (3-segment) passed as one token" "deep repo path missing/mangled in argv" \
	"$( argv_has_pair "$KIDS_UPDATE_LOG1" '--repo' "$DEEP_PATH" && echo 0 || echo 1 )"
check "linkkids(happy): argv carries NO --yes (glab issue update has no such flag)" "a --yes token was passed; real glab rejects it on issue update" \
	"$( argv_has_token "$KIDS_UPDATE_LOG1" '--yes' && echo 1 || echo 0 )"
check "linkkids(happy): the description was read back as json via --output/--jq" "the view call did not request json" \
	"$( argv_has_pair "$KIDS_VIEW_LOG1" '--output' 'json' && echo 0 || echo 1 )"
check "linkkids(happy): the view --jq selects .description with an empty-string fallback" "the view --jq expression drifted" \
	"$( argv_has_pair "$KIDS_VIEW_LOG1" '--jq' '.description // ""' && echo 0 || echo 1 )"

section "link-children.sh — idempotent (one already linked, one new)"
KIDS_DESC2="$WORK/linkkids-description2"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_VIEW_BODY=## Outcome
Ship CSV export.

## Linked children
- [ ] #11" "GLAB_STUB_DESC_FILE=$KIDS_DESC2" \
	sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 10 --child 11 --child 13
expect_rc "linkkids(idempotent): -> exit 0" 0
stdout_has "linkkids(idempotent): PM_LINKED=1 (only the new child counted)" "PM_LINKED=1"
check "linkkids(idempotent): child 13 appended exactly once" "expected exactly one '- [ ] #13' line" \
	"$( line_count_eq "$KIDS_DESC2" '- [ ] #13' 1 && echo 0 || echo 1 )"
check "linkkids(idempotent): child 11 still appears exactly once (not duplicated)" "expected exactly one '- [ ] #11' line" \
	"$( line_count_eq "$KIDS_DESC2" '- [ ] #11' 1 && echo 0 || echo 1 )"
check "linkkids(idempotent): heading not duplicated" "expected exactly one '## Linked children' line" \
	"$( line_count_eq "$KIDS_DESC2" '## Linked children' 1 && echo 0 || echo 1 )"

section "link-children.sh — idempotent regardless of checkbox state"
KIDS_DESC3="$WORK/linkkids-description3"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_VIEW_BODY=## Linked children
- [x] #11" "GLAB_STUB_DESC_FILE=$KIDS_DESC3" \
	sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 10 --child 11 --child 14
expect_rc "linkkids(checked-box): -> exit 0" 0
stdout_has "linkkids(checked-box): PM_LINKED=1 (checked #11 not re-counted)" "PM_LINKED=1"
check "linkkids(checked-box): checked #11 NOT duplicated as an unchecked line" "an unwanted duplicate '- [ ] #11' line was appended" \
	"$( line_count_eq "$KIDS_DESC3" '- [ ] #11' 0 && echo 0 || echo 1 )"
check "linkkids(checked-box): #11 still appears exactly once, still checked" "expected exactly one '- [x] #11' line" \
	"$( line_count_eq "$KIDS_DESC3" '- [x] #11' 1 && echo 0 || echo 1 )"
check "linkkids(checked-box): child 14 appended exactly once" "expected exactly one '- [ ] #14' line" \
	"$( line_count_eq "$KIDS_DESC3" '- [ ] #14' 1 && echo 0 || echo 1 )"

section "link-children.sh — a HAND-EDITED checklist line is still recognized (SHELL-002)"
# THE BUG THIS PINS: the already-linked probe and the splice anchor were both
# EXACT-line anchored ("^- \[[ xX]\] #N\$"), so they only recognized lines THIS
# script had written. A human editing the epic in the GitLab web UI can perfectly
# reasonably leave a trailing space, indent the item under a parent bullet, or save
# through a client that writes CRLF — and every one of those made the probe MISS a
# child that IS linked, so the line was appended a SECOND time and PM_LINKED
# over-reported it as new.
#
# All three shapes are present at once, each for a different already-linked child,
# so a fix that handles only one of them still fails here.
#
# The fixture is BUILT WITH printf, not written literally in this file: a trailing
# space and a CR are exactly the bytes an editor's trim-on-save would silently
# delete, which would turn these assertions into ones that pass for no reason.
# Each assertion below therefore checks that the line was NOT re-appended in the
# CANONICAL shape this script writes (no trailing space, no indent, no CR) — that
# canonical form is absent iff the probe recognized the hand-edited one.
KIDS_HANDEDITED_BODY=$(printf '## Linked children\n- [ ] #11 \n  - [ ] #12\n- [x] #13\r')
KIDS_DESC_HANDEDITED="$WORK/linkkids-description-handedited"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_VIEW_BODY=$KIDS_HANDEDITED_BODY" \
	"GLAB_STUB_DESC_FILE=$KIDS_DESC_HANDEDITED" \
	sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 10 \
		--child 11 --child 12 --child 13 --child 14
expect_rc "linkkids(hand-edited lines): -> exit 0" 0
stdout_has "linkkids(hand-edited lines): PM_LINKED=1 — only the genuinely new child counted" "PM_LINKED=1"
check "linkkids(trailing space): the fixture's trailing-space line really survived into the write-back" \
	"the '- [ ] #11 ' fixture line lost its trailing space, so the assertion below would prove nothing" \
	"$( line_count_eq "$KIDS_DESC_HANDEDITED" '- [ ] #11 ' 1 && echo 0 || echo 1 )"
check "linkkids(trailing space): #11 was NOT re-appended in canonical form" "a trailing space made the probe miss an existing link" \
	"$( line_count_eq "$KIDS_DESC_HANDEDITED" '- [ ] #11' 0 && echo 0 || echo 1 )"
check "linkkids(indented): #12 was NOT re-appended" "an indented checklist line made the probe miss an existing link" \
	"$( line_count_eq "$KIDS_DESC_HANDEDITED" '- [ ] #12' 0 && echo 0 || echo 1 )"
check "linkkids(CRLF): #13 was NOT re-appended" "a CR line ending made the probe miss an existing link" \
	"$( line_count_eq "$KIDS_DESC_HANDEDITED" '- [ ] #13' 0 && echo 0 || echo 1 )"
check "linkkids(hand-edited lines): the genuinely new #14 WAS appended, exactly once" "the new child was lost or duplicated" \
	"$( line_count_eq "$KIDS_DESC_HANDEDITED" '- [ ] #14' 1 && echo 0 || echo 1 )"
check "linkkids(hand-edited lines): the heading was NOT duplicated" "expected exactly one '## Linked children' line" \
	"$( line_count_eq "$KIDS_DESC_HANDEDITED" '## Linked children' 1 && echo 0 || echo 1 )"
# The SPLICE anchor must tolerate the same shapes: the new line belongs AFTER the
# last existing checklist line, so an anchor that stopped recognizing the section at
# the hand-edited line would insert #14 in the wrong place (or start a second
# section). Asserting the new line is the LAST line proves the anchor advanced past
# all three.
check "linkkids(hand-edited lines): #14 was spliced AFTER the last existing checklist line" \
	"the splice anchor stopped at a hand-edited line and inserted in the wrong place" \
	"$( [ "$(awk 'END { print $0 }' "$KIDS_DESC_HANDEDITED")" = '- [ ] #14' ] && echo 0 || echo 1 )"

section "link-children.sh — heading exists but is NOT the last section"
KIDS_DESC4="$WORK/linkkids-description4"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_VIEW_BODY=## Outcome
Ship it.

## Linked children
- [ ] #11

## Non-goals
- nothing else" "GLAB_STUB_DESC_FILE=$KIDS_DESC4" \
	sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 10 --child 12
expect_rc "linkkids(mid-doc-heading): -> exit 0" 0
stdout_has "linkkids(mid-doc-heading): PM_LINKED=1" "PM_LINKED=1"
check "linkkids(mid-doc-heading): child 12 appended exactly once" "expected exactly one '- [ ] #12' line" \
	"$( line_count_eq "$KIDS_DESC4" '- [ ] #12' 1 && echo 0 || echo 1 )"
check "linkkids(mid-doc-heading): '## Non-goals' still FOLLOWS the checklist (not orphaned above it)" \
	"the new line landed at EOF, below '## Non-goals', instead of under '## Linked children'" \
	"$( awk '/^- \[ \] #12$/{c=NR} /^## Non-goals$/{g=NR} END{exit(c>0 && g>c ? 0 : 1)}' "$KIDS_DESC4" && echo 0 || echo 1 )"
check "linkkids(mid-doc-heading): heading not duplicated" "expected exactly one '## Linked children' line" \
	"$( line_count_eq "$KIDS_DESC4" '## Linked children' 1 && echo 0 || echo 1 )"

section "link-children.sh — duplicate --child arguments are linked at most once"
KIDS_DESC5="$WORK/linkkids-description5"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_VIEW_BODY=## Outcome
Ship it." "GLAB_STUB_DESC_FILE=$KIDS_DESC5" \
	sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 10 --child 11 --child 11
expect_rc "linkkids(dup-child-arg): -> exit 0" 0
stdout_has "linkkids(dup-child-arg): PM_LINKED=1 (not inflated by the duplicate arg)" "PM_LINKED=1"
check "linkkids(dup-child-arg): #11 appended exactly once, not twice" "expected exactly one '- [ ] #11' line" \
	"$( line_count_eq "$KIDS_DESC5" '- [ ] #11' 1 && echo 0 || echo 1 )"

section "link-children.sh — already fully linked (no-op, no update call at all)"
KIDS_UPDATE_LOG2="$WORK/linkkids-update-log2"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_VIEW_BODY=## Linked children
- [ ] #11" "GLAB_STUB_UPDATE_LOG=$KIDS_UPDATE_LOG2" \
	sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 10 --child 11
expect_rc "linkkids(no-op): -> exit 0" 0
stdout_has "linkkids(no-op): PM_LINKED=0" "PM_LINKED=0"
file_missing "linkkids(no-op): glab issue update never invoked" "$KIDS_UPDATE_LOG2"

section "link-children.sh — adversarial EXISTING description is spliced, never evaluated"
# The epic's current description is untrusted repo content. It is read straight
# to a file and spliced by awk on files, so metacharacters must survive intact
# and must never be executed.
KIDS_DESC6="$WORK/linkkids-description6"
# shellcheck disable=SC2016  # the $(...)/backticks are the payload under test: they MUST stay literal
run 1 "GLAB_STUB_AUTHED=1" 'GLAB_STUB_VIEW_BODY=## Outcome
this line runs $(whoami) and `id` if the description were ever evaluated as shell
'"'"'; rm -rf /; echo '"'"'' "GLAB_STUB_DESC_FILE=$KIDS_DESC6" \
	sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 10 --child 21
expect_rc "linkkids(adversarial): -> exit 0" 0
stdout_has "linkkids(adversarial): PM_LINKED=1" "PM_LINKED=1"
# shellcheck disable=SC2016  # same deliberate literal as above
check "linkkids(adversarial): the metacharacter line survived unexpanded into the new description" \
	"shell metacharacters in the EXISTING description were expanded or dropped" \
	"$( grep -Fq -- 'runs $(whoami) and `id`' "$KIDS_DESC6" && echo 0 || echo 1 )"
check "linkkids(adversarial): the rm -rf payload line survived as inert text" "the adversarial line was dropped or altered" \
	"$( grep -Fq -- "; rm -rf /; echo " "$KIDS_DESC6" && echo 0 || echo 1 )"
check "linkkids(adversarial): the new child line was still appended" "expected exactly one '- [ ] #21' line" \
	"$( line_count_eq "$KIDS_DESC6" '- [ ] #21' 1 && echo 0 || echo 1 )"

section "link-children.sh — a JSON-QUOTED description read-back (characterization)"
# WHY THIS CASE EXISTS: link-children.sh is the ONE script here that reads a
# description back and writes it STRAIGHT BACK to a live issue, so how glab's
# `--jq '.description // ""'` renders a string is load-bearing for it in a way it
# is not anywhere else. Live testing confirmed the RAW rendering (every other
# link-children case above), and this case pins what happens if a future glab
# switched to a JSON-QUOTED one: the quoted text is spliced through UNCHANGED —
# surrounding quotes and literal backslash-n included — rather than being
# half-normalized into something lossy. It is a CHARACTERIZATION test: if that
# ever changes, this fails loudly instead of silently corrupting an epic.
KIDS_DESC_JSON="$WORK/linkkids-description-json"
run 1 "GLAB_STUB_AUTHED=1" 'GLAB_STUB_VIEW_BODY="## Outcome\nShip CSV export."' \
	"GLAB_STUB_DESC_FILE=$KIDS_DESC_JSON" \
	sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 10 --child 31
expect_rc "linkkids(json-quoted read-back): -> exit 0" 0
stdout_has "linkkids(json-quoted read-back): PM_LINKED=1" "PM_LINKED=1"
check "linkkids(json-quoted read-back): the quoted text is relayed VERBATIM, not half-normalized" \
	"the JSON-quoted description was altered — check whether the change is intentional before accepting it" \
	"$( grep -Fxq -- '"## Outcome\nShip CSV export."' "$KIDS_DESC_JSON" && echo 0 || echo 1 )"
check "linkkids(json-quoted read-back): the new child line was still appended exactly once" "expected exactly one '- [ ] #31' line" \
	"$( line_count_eq "$KIDS_DESC_JSON" '- [ ] #31' 1 && echo 0 || echo 1 )"
check "linkkids(json-quoted read-back): the heading was added exactly once" "expected exactly one '## Linked children' line" \
	"$( line_count_eq "$KIDS_DESC_JSON" '## Linked children' 1 && echo 0 || echo 1 )"

section "link-children.sh — 0 and leading-zero iids are usage errors, never a dead link"
# `--child 0` used to SPLICE a dead "- [ ] #0" line into the epic and report
# PM_LINKED=1 — a silently wrong outcome, not merely a confusing error — and
# `--child 007` would have linked issue 7.
KIDS_UPDATE_LOG_ZERO="$WORK/linkkids-update-log-zero"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_VIEW_BODY=body" "GLAB_STUB_UPDATE_LOG=$KIDS_UPDATE_LOG_ZERO" \
	sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 10 --child 0
expect_rc "linkkids(--child 0): -> exit 2" 2
stderr_has "linkkids(--child 0): diagnostic" "--child must be a positive integer"
file_missing "linkkids(--child 0): the epic was never updated with a dead '#0' link" "$KIDS_UPDATE_LOG_ZERO"
run 1 sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 10 --child 007
expect_rc "linkkids(--child 007): -> exit 2 (007 would have linked issue 7)" 2
run 1 sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 0 --child 2
expect_rc "linkkids(--epic-issue 0): -> exit 2" 2
stderr_has "linkkids(--epic-issue 0): diagnostic" "positive integer"
run 1 sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 007 --child 2
expect_rc "linkkids(--epic-issue 007): -> exit 2" 2

section "link-children.sh — epic issue not readable"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_VIEW_RC=1" sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 999 --child 1
expect_rc "linkkids(epic-not-found): -> exit 1" 1
stderr_has "linkkids(epic-not-found): diagnostic" "could not read epic issue"

section "link-children.sh — glab issue update itself fails"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_VIEW_BODY=body" "GLAB_STUB_UPDATE_RC=1" \
	sh "$LINKKIDS" --confirmed-host gitlab.com --repo g/p --epic-issue 10 --child 1
expect_rc "linkkids(update-fail): -> exit 1" 1
stderr_has "linkkids(update-fail): reports failure" "glab issue update failed"

# ===========================================================================
# ensure-labels.sh
# ===========================================================================
section "ensure-labels.sh — usage / argument errors"
run 1 sh "$ENSURELABELS" --confirmed-host gitlab.com -h
expect_rc "ensurelabels(usage): -h -> exit 0" 0
stdout_has "ensurelabels(usage): help text" "Usage:"

run 1 sh "$ENSURELABELS" --confirmed-host gitlab.com --label bug
expect_rc "ensurelabels(missing --repo): -> exit 2" 2
stderr_has "ensurelabels(missing --repo): diagnostic" "--repo is required"

run 1 sh "$ENSURELABELS" --confirmed-host gitlab.com --repo g/p
expect_rc "ensurelabels(missing --label): -> exit 2" 2
stderr_has "ensurelabels(missing --label): diagnostic" "at least one --label is required"

run 1 sh "$ENSURELABELS" --confirmed-host gitlab.com --repo lonelyproject --label bug
expect_rc "ensurelabels(single-segment path): -> exit 2" 2
stderr_has "ensurelabels(single-segment path): diagnostic" "at least one '/'"

run 1 sh "$ENSURELABELS" --confirmed-host gitlab.com --repo 'g/..' --label bug
expect_rc "ensurelabels(traversal path): -> exit 2" 2

run 1 sh "$ENSURELABELS" --confirmed-host gitlab.com --repo g/p --label bug --color zzzzzz
expect_rc "ensurelabels(invalid --color): -> exit 2" 2
stderr_has "ensurelabels(invalid --color): diagnostic" "6 hex digits"

run 1 sh "$ENSURELABELS" --confirmed-host gitlab.com --bogus
expect_rc "ensurelabels(unknown option): -> exit 2" 2
stderr_has "ensurelabels(unknown option): diagnostic" "unknown option"

section "ensure-labels.sh — glab absent / not authenticated (fail-closed)"
run 0 sh "$ENSURELABELS" --confirmed-host gitlab.com --repo g/p --label bug
expect_rc "ensurelabels(no-glab): -> exit 1" 1
stderr_has "ensurelabels(no-glab): install hint" "gitlab-org/cli"

run 1 "GLAB_STUB_AUTHED=0" sh "$ENSURELABELS" --confirmed-host gitlab.com --repo g/p --label bug
expect_rc "ensurelabels(unauth): -> exit 1" 1
stderr_has "ensurelabels(unauth): diagnostic" "not authenticated"

section "ensure-labels.sh — the labels lookup itself fails"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABEL_LIST_RC=1" sh "$ENSURELABELS" --confirmed-host gitlab.com --repo g/p --label bug
expect_rc "ensurelabels(lookup-fail): -> exit 1" 1
stderr_has "ensurelabels(lookup-fail): reports failure" "failed to look up labels"

section "ensure-labels.sh — creates only missing labels, idempotent across duplicates"
LABEL_LOG1="$WORK/label-create-log1"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABELS=type:story" "GLAB_STUB_LABEL_CREATE_LOG=$LABEL_LOG1" \
	sh "$ENSURELABELS" --confirmed-host gitlab.com --repo group/sub/proj --label "type:story,area:billing" --label "area:billing" \
		--color ff0000 --description "auto-created"
expect_rc "ensurelabels(idempotent): -> exit 0" 0
stdout_has "ensurelabels(idempotent): created only area:billing" "PM_LABELS_CREATED=area:billing"
stdout_has "ensurelabels(idempotent): existing reports type:story" "PM_LABELS_EXISTING=type:story"
check "ensurelabels(idempotent): exactly ONE glab label create call (deduped)" "expected exactly one ARGV_BEGIN block" \
	"$( [ "$(grep -Fxc -- 'ARGV_BEGIN' "$LABEL_LOG1")" -eq 1 ] && echo 0 || echo 1 )"
check "ensurelabels(idempotent): the name goes behind glab's --name flag" "no '--name area:billing' pair in argv" \
	"$( argv_has_pair "$LABEL_LOG1" '--name' 'area:billing' && echo 0 || echo 1 )"
check "ensurelabels(idempotent): --color passed as one token" "color missing/misplaced in argv" \
	"$( argv_has_pair "$LABEL_LOG1" '--color' 'ff0000' && echo 0 || echo 1 )"
check "ensurelabels(idempotent): --description passed as one token" "description missing/misplaced in argv" \
	"$( argv_has_pair "$LABEL_LOG1" '--description' 'auto-created' && echo 0 || echo 1 )"
check "ensurelabels(idempotent): argv carries NO --yes (glab label create has no such flag)" "a --yes token was passed; real glab rejects it on label create" \
	"$( argv_has_token "$LABEL_LOG1" '--yes' && echo 1 || echo 0 )"

section "ensure-labels.sh — a leading '#' on --color is accepted (glab's own spelling)"
LABEL_LOG2="$WORK/label-create-log2"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABELS=" "GLAB_STUB_LABEL_CREATE_LOG=$LABEL_LOG2" \
	sh "$ENSURELABELS" --confirmed-host gitlab.com --repo g/p --label bug --color '#428BCA'
expect_rc "ensurelabels(hash-color): -> exit 0" 0
check "ensurelabels(hash-color): the '#'-prefixed hex is relayed verbatim as one token" "the color was altered or split" \
	"$( argv_has_pair "$LABEL_LOG2" '--color' '#428BCA' && echo 0 || echo 1 )"

section "ensure-labels.sh — the PAGE WALK sees an existing label on page 2 (no re-create)"
LABEL_LOG3="$WORK/label-create-log3"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABELS=$FULL_LABEL_PAGE" "GLAB_STUB_LABELS_P2=on-page-two" \
	"GLAB_STUB_LABEL_CREATE_LOG=$LABEL_LOG3" \
	sh "$ENSURELABELS" --confirmed-host gitlab.com --repo g/p --label on-page-two
expect_rc "ensurelabels(paged): -> exit 0" 0
stdout_has "ensurelabels(paged): reported as ALREADY EXISTING, found on page 2" "PM_LABELS_EXISTING=on-page-two"
stdout_re "ensurelabels(paged): nothing was created" '^PM_LABELS_CREATED=$'
file_missing "ensurelabels(paged): glab label create never invoked" "$LABEL_LOG3"

section "ensure-labels.sh — adversarial label name reaches glab verbatim and inert"
LABEL_LOG4="$WORK/label-create-log4"
# shellcheck disable=SC2016  # deliberate: the single-quoted $(...)/`...` text is the literal adversarial label we assert was NEVER expanded
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABELS=" "GLAB_STUB_LABEL_CREATE_LOG=$LABEL_LOG4" \
	sh "$ENSURELABELS" --confirmed-host gitlab.com --repo group/sub/proj --label '$(whoami) `id`'
expect_rc "ensurelabels(adversarial-label): -> exit 0" 0
# shellcheck disable=SC2016  # same deliberate literal as above
stdout_has "ensurelabels(adversarial-label): reported created verbatim" 'PM_LABELS_CREATED=$(whoami) `id`'
# shellcheck disable=SC2016  # same deliberate literal as above
check "ensurelabels(adversarial-label): the literal text reached glab's argv behind --name (inert, never evaluated)" \
	"literal \$(whoami)/backtick label text missing from glab's logged argv" \
	"$( argv_has_pair "$LABEL_LOG4" '--name' '$(whoami) `id`' && echo 0 || echo 1 )"

section "ensure-labels.sh — a leading-dash label name is safe behind --name"
# The GitHub sibling has to put the label name after a literal `--` because gh
# takes it POSITIONALLY; glab takes it behind its own `--name` flag, whose value
# is consumed unconditionally, so a '-'-leading name needs no such dance here.
LABEL_LOG6="$WORK/label-create-log6"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABELS=" "GLAB_STUB_LABEL_CREATE_LOG=$LABEL_LOG6" \
	sh "$ENSURELABELS" --confirmed-host gitlab.com --repo g/p --label '-dashy'
expect_rc "ensurelabels(dash-name): a '-'-leading label VALUE is accepted -> exit 0" 0
check "ensurelabels(dash-name): it reaches glab as the --name value, not as a flag" "the dash-leading name was not passed as --name's value" \
	"$( argv_has_pair "$LABEL_LOG6" '--name' '-dashy' && echo 0 || echo 1 )"

section "ensure-labels.sh — an EXISTING label whose name contains a double quote is not re-created"
# The lookup strips only a SURROUNDING PAIR of quotes from glab's --jq rows. A
# global strip (the old `gsub(/"/, "")`) turned a label literally named
# `say "hi"` into `say hi`, so this run would have tried to CREATE a label that
# already exists — an outward, persistent write glab then rejects, reported as a
# spurious failure.
LABEL_LOG_QUOTED="$WORK/label-create-log-quoted"
run 1 "GLAB_STUB_AUTHED=1" 'GLAB_STUB_LABELS=say "hi"' "GLAB_STUB_LABEL_CREATE_LOG=$LABEL_LOG_QUOTED" \
	sh "$ENSURELABELS" --confirmed-host gitlab.com --repo g/p --label 'say "hi"'
expect_rc "ensurelabels(quoted name): -> exit 0" 0
stdout_has "ensurelabels(quoted name): reported as ALREADY EXISTING, quotes intact" 'PM_LABELS_EXISTING=say "hi"'
stdout_re "ensurelabels(quoted name): nothing was created" '^PM_LABELS_CREATED=$'
file_missing "ensurelabels(quoted name): glab label create never invoked" "$LABEL_LOG_QUOTED"

section "ensure-labels.sh — a create failure is best-effort, not all-or-nothing"
LABEL_LOG7="$WORK/label-create-log7"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABELS=" "GLAB_STUB_LABEL_CREATE_RC=1" "GLAB_STUB_LABEL_CREATE_LOG=$LABEL_LOG7" \
	sh "$ENSURELABELS" --confirmed-host gitlab.com --repo g/p --label "bug,feature"
expect_rc "ensurelabels(create-fail): -> exit 1" 1
stderr_has "ensurelabels(create-fail): reports which label failed" "failed to create label 'bug'"
check "ensurelabels(create-fail): both create calls were still attempted" "expected 2 ARGV_BEGIN blocks (best-effort, not abort-on-first-failure)" \
	"$( [ "$(grep -Fxc -- 'ARGV_BEGIN' "$LABEL_LOG7")" -eq 2 ] && echo 0 || echo 1 )"

section "ensure-labels.sh — the flagship MIXED case: one label fails, the other still succeeds"
LABEL_LOG8="$WORK/label-create-log8"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_LABELS=" "GLAB_STUB_LABEL_CREATE_FAIL_LIST=feature" "GLAB_STUB_LABEL_CREATE_LOG=$LABEL_LOG8" \
	sh "$ENSURELABELS" --confirmed-host gitlab.com --repo g/p --label "bug,feature"
expect_rc "ensurelabels(mixed): -> exit 1 (the one failure taints the exit code)" 1
stdout_has "ensurelabels(mixed): the SUCCEEDING label is still reported created" "PM_LABELS_CREATED=bug"
stdout_re "ensurelabels(mixed): PM_LABELS_EXISTING is empty (neither label pre-existed)" '^PM_LABELS_EXISTING=$'
stderr_has "ensurelabels(mixed): names the ONE label that failed" "failed to create label 'feature'"
check "ensurelabels(mixed): 'bug' was NOT also reported as failed" "the succeeding label's create was unexpectedly flagged as failed" \
	"$( printf '%s\n' "$CUR_ERR" | grep -Fq -- "failed to create label 'bug'" && echo 1 || echo 0 )"
check "ensurelabels(mixed): both create calls were attempted (best-effort continues past the failure)" "expected 2 ARGV_BEGIN blocks" \
	"$( [ "$(grep -Fxc -- 'ARGV_BEGIN' "$LABEL_LOG8")" -eq 2 ] && echo 0 || echo 1 )"

# ===========================================================================
# comment.sh
# ===========================================================================
section "comment.sh — usage / argument errors"
run 1 sh "$COMMENT" --confirmed-host gitlab.com -h
expect_rc "comment(usage): -h -> exit 0" 0
stdout_has "comment(usage): help text" "Usage:"

CBODY="$WORK/comment-body.md"
printf 'Thanks for the report!\n' >"$CBODY"

run 1 sh "$COMMENT" --confirmed-host gitlab.com --issue 1 --body-file "$CBODY"
expect_rc "comment(missing --repo): -> exit 2" 2
stderr_has "comment(missing --repo): diagnostic" "--repo is required"

run 1 sh "$COMMENT" --confirmed-host gitlab.com --repo g/p --body-file "$CBODY"
expect_rc "comment(missing --issue): -> exit 2" 2
stderr_has "comment(missing --issue): diagnostic" "--issue is required"

run 1 sh "$COMMENT" --confirmed-host gitlab.com --repo g/p --issue 1
expect_rc "comment(missing --body-file): -> exit 2" 2
stderr_has "comment(missing --body-file): diagnostic" "--body-file is required"

run 1 sh "$COMMENT" --confirmed-host gitlab.com --repo g/p --issue abc --body-file "$CBODY"
expect_rc "comment(non-numeric --issue): -> exit 2" 2
stderr_has "comment(non-numeric --issue): diagnostic" "positive integer"

run 1 sh "$COMMENT" --confirmed-host gitlab.com --repo g/p --issue 1 --body-file "$WORK/does-not-exist"
expect_rc "comment(nonexistent body-file): -> exit 2" 2
stderr_has "comment(nonexistent body-file): diagnostic" "does not exist or is not readable"

run 1 sh "$COMMENT" --confirmed-host gitlab.com --repo g/p --issue 1 --body-file "$WORK/empty-body.md"
expect_rc "comment(empty body-file): -> exit 2" 2
stderr_has "comment(empty body-file): diagnostic" "is empty"

COMMENT_LOG_DASH="$WORK/comment-log-dash"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_NOTE_LOG=$COMMENT_LOG_DASH" \
	sh "$COMMENT" --confirmed-host gitlab.com --repo g/p --issue 1 --body-file "$WORK/dash-body.md"
expect_rc "comment(body is literally '-'): -> exit 2" 2
stderr_has "comment('-' guard): explains the editor hazard" "interactive editor"
file_missing "comment('-' guard): glab issue note never invoked" "$COMMENT_LOG_DASH"

run 1 sh "$COMMENT" --confirmed-host gitlab.com --repo lonelyproject --issue 1 --body-file "$CBODY"
expect_rc "comment(single-segment path): -> exit 2" 2
stderr_has "comment(single-segment path): diagnostic" "at least one '/'"

run 1 sh "$COMMENT" --confirmed-host gitlab.com --repo 'g/..' --issue 1 --body-file "$CBODY"
expect_rc "comment(traversal path): -> exit 2" 2

run 1 sh "$COMMENT" --confirmed-host gitlab.com --bogus
expect_rc "comment(unknown option): -> exit 2" 2
stderr_has "comment(unknown option): diagnostic" "unknown option"

section "comment.sh — glab absent / not authenticated"
run 0 sh "$COMMENT" --confirmed-host gitlab.com --repo g/p --issue 1 --body-file "$CBODY"
expect_rc "comment(no-glab): -> exit 1" 1
stderr_has "comment(no-glab): install hint" "gitlab-org/cli"

run 1 "GLAB_STUB_AUTHED=0" sh "$COMMENT" --confirmed-host gitlab.com --repo g/p --issue 1 --body-file "$CBODY"
expect_rc "comment(unauth): -> exit 1" 1
stderr_has "comment(unauth): diagnostic" "not authenticated"

section "comment.sh — successful comment"
COMMENT_LOG1="$WORK/comment-log1"
COMMENT_MSG_SEEN1="$WORK/comment-message-seen1"
# GLAB_STUB_NOTE_OUT is spelled out (rather than left on the stub default) because
# the URL must live under the project this run names: the extractor requires the
# matched token's path to contain the confirmed --repo value.
DEEP_NOTE_URL="https://gitlab.com/$DEEP_PATH/-/work_items/5#note_42"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_NOTE_LOG=$COMMENT_LOG1" "GLAB_STUB_MSG_FILE=$COMMENT_MSG_SEEN1" \
	"GLAB_STUB_NOTE_OUT=$DEEP_NOTE_URL" \
	sh "$COMMENT" --confirmed-host gitlab.com --repo "$DEEP_PATH" --issue 5 --body-file "$CBODY"
expect_rc "comment(success): -> exit 0" 0
stdout_has "comment(success): PM_COMMENT_URL (the work-items note anchor found by shape)" "PM_COMMENT_URL=$DEEP_NOTE_URL"
check "comment(success): the issue iid is passed POSITIONALLY (glab issue note takes <issue-id>)" "the iid was not the first argv token" \
	"$( argv_first_is "$COMMENT_LOG1" '5' && echo 0 || echo 1 )"
check "comment(success): --repo (3-segment) passed as one token" "deep repo path missing/mangled in argv" \
	"$( argv_has_pair "$COMMENT_LOG1" '--repo' "$DEEP_PATH" && echo 0 || echo 1 )"
check "comment(success): argv carries a --message token (glab's only comment mechanism)" "no --message token in argv" \
	"$( argv_has_token "$COMMENT_LOG1" '--message' && echo 0 || echo 1 )"
check "comment(success): argv has NO --body-file token (that is the GitHub sibling's flag)" "a --body-file token leaked into the glab argv" \
	"$( argv_has_token "$COMMENT_LOG1" '--body-file' && echo 1 || echo 0 )"
check "comment(success): argv carries NO --yes (glab issue note has no such flag)" "a --yes token was passed; real glab rejects it on issue note" \
	"$( argv_has_token "$COMMENT_LOG1" '--yes' && echo 1 || echo 0 )"
if diff_value_file "$CBODY" "$COMMENT_MSG_SEEN1"; then COMMENT_DIFF_RC=0; else COMMENT_DIFF_RC=1; fi
check "comment(success): the message value glab received is byte-identical to the file" \
	"$(cat "$WORK/value_diff" 2>/dev/null)" \
	"$COMMENT_DIFF_RC"

section "comment.sh — both issue-URL path shapes are accepted, with and without a note anchor"
# The stub default above covers the current '/-/work_items/<iid>#note_<id>' shape
# glab actually prints (live-verified). These four cases pin the rest of the
# matrix: the CLASSIC '/-/issues/' path (an older self-managed instance) and the
# anchorless form of each, all of which must still populate PM_COMMENT_URL.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_NOTE_OUT=https://gitlab.example.com/deep/group/nest/proj/-/issues/5#note_42" \
	sh "$COMMENT" --confirmed-host gitlab.com --repo deep/group/nest/proj --issue 5 --body-file "$CBODY"
expect_rc "comment(classic-shape-anchored): -> exit 0" 0
stdout_has "comment(classic-shape-anchored): classic '/-/issues/' + note anchor still accepted" \
	"PM_COMMENT_URL=https://gitlab.example.com/deep/group/nest/proj/-/issues/5#note_42"

run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_NOTE_OUT=https://gitlab.example.com/deep/group/nest/proj/-/issues/5" \
	sh "$COMMENT" --confirmed-host gitlab.com --repo deep/group/nest/proj --issue 5 --body-file "$CBODY"
expect_rc "comment(classic-shape-bare): -> exit 0" 0
stdout_has "comment(classic-shape-bare): classic '/-/issues/' with NO anchor still accepted" \
	"PM_COMMENT_URL=https://gitlab.example.com/deep/group/nest/proj/-/issues/5"

run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_NOTE_OUT=https://gitlab.example.com/deep/group/nest/proj/-/work_items/5" \
	sh "$COMMENT" --confirmed-host gitlab.com --repo deep/group/nest/proj --issue 5 --body-file "$CBODY"
expect_rc "comment(work-items-bare): -> exit 0" 0
stdout_has "comment(work-items-bare): '/-/work_items/' with NO anchor accepted" \
	"PM_COMMENT_URL=https://gitlab.example.com/deep/group/nest/proj/-/work_items/5"

# Guards the broadening from going too far — see the create counterpart, including
# why --repo MUST match the fixture URL's own project path (otherwise the project
# filter rejects the token first and the shape restriction is never exercised). An
# unrelated path segment must leave the courtesy field empty rather than relay a
# URL that is not this note's.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_NOTE_OUT=https://gitlab.com/group/sub/proj/-/merge_requests/9#note_42" \
	sh "$COMMENT" --confirmed-host gitlab.com --repo group/sub/proj --issue 5 --body-file "$CBODY"
expect_rc "comment(wrong-path-segment): -> exit 0 (courtesy contract, never a hard fail)" 0
stdout_re "comment(wrong-path-segment): a merge_requests note URL of THIS project is NOT relayed" '^PM_COMMENT_URL=$'

section "comment.sh — successful comment with NO URL returned (courtesy contract)"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_NOTE_OUT=" sh "$COMMENT" --confirmed-host gitlab.com --repo g/p --issue 1 --body-file "$CBODY"
expect_rc "comment(empty-url): -> exit 0 (the URL is a courtesy, not proof of success)" 0
stdout_re "comment(empty-url): PM_COMMENT_URL is empty" '^PM_COMMENT_URL=$'

section "comment.sh — glab issue note itself fails"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_NOTE_RC=1" sh "$COMMENT" --confirmed-host gitlab.com --repo g/p --issue 1 --body-file "$CBODY"
expect_rc "comment(glab-fail): -> exit 1" 1
stderr_has "comment(glab-fail): reports failure" "glab issue note failed"

section "comment.sh — adversarial comment content stays inert (golden-diff)"
CADVERSARIAL="$WORK/comment-adversarial.md"
cat >"$CADVERSARIAL" <<'BODY_EOF'
Thanks for the report.

PM_ARTIFACT_BODY
EOF
this line runs $(whoami) and `id` if the body were ever evaluated as shell
Closing as a duplicate of #4.

BODY_EOF
COMMENT_LOG2="$WORK/comment-log2"
COMMENT_MSG_SEEN2="$WORK/comment-message-seen2"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_NOTE_LOG=$COMMENT_LOG2" "GLAB_STUB_MSG_FILE=$COMMENT_MSG_SEEN2" \
	sh "$COMMENT" --confirmed-host gitlab.com --repo group/sub/proj --issue 1 --body-file "$CADVERSARIAL"
expect_rc "comment(adversarial): -> exit 0" 0
if diff_value_file "$CADVERSARIAL" "$COMMENT_MSG_SEEN2"; then CADV_DIFF_RC=0; else CADV_DIFF_RC=1; fi
check "comment(adversarial): message reached glab BYTE-IDENTICAL, trailing newlines included" \
	"$(cat "$WORK/value_diff" 2>/dev/null)" \
	"$CADV_DIFF_RC"
# shellcheck disable=SC2016  # the $(...) and backticks are the payload under test
check "comment(adversarial): the metacharacter line survived unexpanded" "shell metacharacters were expanded or dropped" \
	"$( value_block "$COMMENT_LOG2" 'MESSAGE_VALUE' | grep -Fq -- 'runs $(whoami) and `id`' && echo 0 || echo 1 )"

section "comment.sh — a URL-shaped line in the OUTPUT cannot hijack PM_COMMENT_URL (SEC-001)"
# Same class of defect as create-issue.sh's: the FIRST shape-matching token in the
# captured output used to win, so anything URL-shaped that glab echoed back (a
# title, a quoted link) could displace the real note URL. The candidate must now
# carry the confirmed --repo path, and the dedup leaves at most one line per distinct
# URL, so the single survivor is taken outright.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_NOTE_OUT=on https://evil.example/attacker/project/-/issues/1
https://gitlab.com/group/sub/proj/-/work_items/5#note_42" \
	sh "$COMMENT" --confirmed-host gitlab.com --repo group/sub/proj --issue 5 --body-file "$CBODY"
expect_rc "comment(url-shaped output line): -> exit 0" 0
stdout_has "comment(url-shaped output line): PM_COMMENT_URL is the REAL note URL" "PM_COMMENT_URL=https://gitlab.com/group/sub/proj/-/work_items/5#note_42"
check "comment(url-shaped output line): the attacker URL never reaches stdout" "an unrelated URL was relayed to the caller" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'evil.example' && echo 1 || echo 0 )"

section "comment.sh — the project filter is ANCHORED to the host (SEC-002)"
# Same residual gap as create-issue.sh's (see that section for the mechanism): the
# filter was an UNANCHORED index() substring test, so this project's path buried
# under a foreign host qualified. The spoof is the SOLE shape-matching token here, so
# the ambiguity guard cannot save it and the anchor is the only thing that can.
# DELIBERATE difference from create-issue.sh: the note was already posted, so the
# courtesy contract leaves PM_COMMENT_URL empty rather than failing.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_NOTE_OUT=note: https://attacker.example/x/group/sub/proj/-/work_items/5#note_9" \
	sh "$COMMENT" --confirmed-host gitlab.com --repo group/sub/proj --issue 5 --body-file "$CBODY"
expect_rc "comment(unanchored spoof, sole candidate): -> exit 0 (the note WAS posted)" 0
stdout_re "comment(unanchored spoof): PM_COMMENT_URL is empty, never the spoof" '^PM_COMMENT_URL=$'
check "comment(unanchored spoof): the attacker URL never reaches stdout" \
	"an extra leading path segment let a foreign host masquerade as this project" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'attacker.example' && echo 1 || echo 0 )"

section "comment.sh — TWO distinct project URLs leave PM_COMMENT_URL EMPTY + warn (SEC-001)"
# The DELIBERATE difference from create-issue.sh: the note was already posted and
# PM_COMMENT_URL is a documented courtesy field, so ambiguity must not invent a
# failure exit — it leaves the key empty (never a guess) and says so on stderr.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_NOTE_OUT=duplicate of https://gitlab.com/group/sub/proj/-/issues/4
https://gitlab.com/group/sub/proj/-/work_items/5#note_42" \
	sh "$COMMENT" --confirmed-host gitlab.com --repo group/sub/proj --issue 5 --body-file "$CBODY"
expect_rc "comment(ambiguous URLs): -> exit 0 (the note WAS posted)" 0
stdout_re "comment(ambiguous URLs): PM_COMMENT_URL is empty, never guessed" '^PM_COMMENT_URL=$'
stderr_has "comment(ambiguous URLs): warns why the field is empty" "MORE THAN ONE distinct issue/note URL"
stderr_has "comment(ambiguous URLs): points at find-duplicate.sh" "find-duplicate.sh"

section "comment.sh — the URL arriving ONLY on stderr still populates PM_COMMENT_URL"
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_NOTE_ERR_OUT=https://gitlab.com/group/sub/proj/-/work_items/5#note_42" \
	sh "$COMMENT" --confirmed-host gitlab.com --repo group/sub/proj --issue 5 --body-file "$CBODY"
expect_rc "comment(url-on-stderr): -> exit 0" 0
stdout_has "comment(url-on-stderr): PM_COMMENT_URL recovered from stderr" "PM_COMMENT_URL=https://gitlab.com/group/sub/proj/-/work_items/5#note_42"

section "comment.sh — a spoof on stdout cannot outrank the genuine URL on stderr (SEC-003)"
# Same residual gap as create-issue.sh's (see that section for the full mechanism):
# stdout was scanned FIRST and stderr only as a fallback, so a URL-shaped token
# echoed on stdout — from the COMMENT BODY or the issue title — carrying THIS
# project's path under a foreign host won unopposed whenever glab put the real URL on
# stderr. Both streams now form ONE pool. The spoofed issue iid is 5 — the same issue
# this run is commenting on — so the iid cross-check below cannot be what saves this
# case; only the unified scan can.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_NOTE_OUT=on https://evil.example/group/sub/proj/-/issues/5" \
	"GLAB_STUB_NOTE_ERR_OUT=https://gitlab.com/group/sub/proj/-/work_items/5#note_42" \
	sh "$COMMENT" --confirmed-host gitlab.com --repo group/sub/proj --issue 5 --body-file "$CBODY"
expect_rc "comment(stdout spoof vs stderr URL): -> exit 0 (the note WAS posted)" 0
stdout_re "comment(stdout spoof vs stderr URL): PM_COMMENT_URL is empty, never the spoof" '^PM_COMMENT_URL=$'
stderr_has "comment(stdout spoof vs stderr URL): both streams' candidates reached the ambiguity guard" "MORE THAN ONE distinct issue/note URL"
check "comment(stdout spoof vs stderr URL): the attacker URL never reaches stdout" "the spoofed stdout URL won because stderr was not consulted" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'evil.example' && echo 1 || echo 0 )"

section "comment.sh — a URL naming a DIFFERENT issue than --issue is refused (SEC-003)"
# The second half of the SEC-003 fix, available ONLY to the scripts that were handed
# the iid: --issue was validated as a positive integer up front, so it is
# authoritative ground truth the extraction can be cross-checked against. Here the
# sole candidate is a well-formed URL — right host, right project path, even a real
# note anchor — but for issue #4, while the note was posted on #5. Without the
# cross-check the pool holds exactly one candidate, so the ambiguity guard has
# nothing to catch and #4's URL is relayed as if it were this note's. The '#note_'
# anchor must be stripped BEFORE the comparison, or the note id would be compared
# instead of the issue iid.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_NOTE_OUT=duplicate of https://gitlab.com/group/sub/proj/-/issues/4#note_99" \
	sh "$COMMENT" --confirmed-host gitlab.com --repo group/sub/proj --issue 5 --body-file "$CBODY"
expect_rc "comment(iid mismatch): -> exit 0 (the note WAS posted)" 0
stdout_re "comment(iid mismatch): PM_COMMENT_URL is empty, never another issue's URL" '^PM_COMMENT_URL=$'
stderr_has "comment(iid mismatch): the warning names the issue actually printed" "for issue #4"
stderr_has "comment(iid mismatch): the warning names the issue commented on" "not the issue that was commented on (#5)"
check "comment(iid mismatch): the other issue's URL is never relayed on stdout" "a URL for a different issue was relayed as this note's" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'issues/4' && echo 1 || echo 0 )"

section "comment.sh — --issue rejects 0 and leading-zero forms (usage error, not a glab failure)"
COMMENT_LOG_ZERO="$WORK/comment-log-zero"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_NOTE_LOG=$COMMENT_LOG_ZERO" \
	sh "$COMMENT" --confirmed-host gitlab.com --repo g/p --issue 0 --body-file "$CBODY"
expect_rc "comment(--issue 0): -> exit 2, not a raw glab failure" 2
stderr_has "comment(--issue 0): diagnostic" "positive integer"
file_missing "comment(--issue 0): glab issue note never invoked" "$COMMENT_LOG_ZERO"
run 1 sh "$COMMENT" --confirmed-host gitlab.com --repo g/p --issue 007 --body-file "$CBODY"
expect_rc "comment(--issue 007): -> exit 2 (007 is not the iid GitLab echoes back)" 2

# ===========================================================================
# update-issue.sh
# ===========================================================================
section "update-issue.sh — usage / argument errors"
run 1 sh "$UPDATE" --confirmed-host gitlab.com -h
expect_rc "update(usage): -h -> exit 0" 0
stdout_has "update(usage): help text" "Usage:"

run 1 sh "$UPDATE" --confirmed-host gitlab.com --issue 1 --title x
expect_rc "update(missing --repo): -> exit 2" 2
stderr_has "update(missing --repo): diagnostic" "--repo is required"

run 1 sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --title x
expect_rc "update(missing --issue): -> exit 2" 2
stderr_has "update(missing --issue): diagnostic" "--issue is required"

run 1 sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --issue abc --title x
expect_rc "update(non-numeric --issue): -> exit 2" 2
stderr_has "update(non-numeric --issue): diagnostic" "positive integer"

run 1 sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --issue 1
expect_rc "update(no fields given): -> exit 2" 2
stderr_has "update(no fields given): diagnostic" "at least one field to change is required"

run 1 sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --issue 1 --body-file "$WORK/does-not-exist"
expect_rc "update(nonexistent body-file): -> exit 2" 2
stderr_has "update(nonexistent body-file): diagnostic" "does not exist or is not readable"

run 1 sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --issue 1 --body-file "$WORK/empty-body.md"
expect_rc "update(empty body-file): -> exit 2" 2
stderr_has "update(empty body-file): diagnostic" "is empty"

run 1 sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --issue 1 --body-file "$WORK/dash-body.md"
expect_rc "update(body is literally '-'): -> exit 2" 2
stderr_has "update('-' guard): explains the editor hazard" "interactive editor"

run 1 sh "$UPDATE" --confirmed-host gitlab.com --repo lonelyproject --issue 1 --title x
expect_rc "update(single-segment path): -> exit 2" 2
stderr_has "update(single-segment path): diagnostic" "at least one '/'"

run 1 sh "$UPDATE" --confirmed-host gitlab.com --repo 'g/..' --issue 1 --title x
expect_rc "update(traversal path): -> exit 2" 2

run 1 sh "$UPDATE" --confirmed-host gitlab.com --bogus
expect_rc "update(unknown option): -> exit 2" 2
stderr_has "update(unknown option): diagnostic" "unknown option"

section "update-issue.sh — glab absent / not authenticated"
run 0 sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --issue 1 --title x
expect_rc "update(no-glab): -> exit 1" 1
stderr_has "update(no-glab): install hint" "gitlab-org/cli"

run 1 "GLAB_STUB_AUTHED=0" sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --issue 1 --title x
expect_rc "update(unauth): -> exit 1" 1
stderr_has "update(unauth): diagnostic" "not authenticated"

section "update-issue.sh — body NOT clobbered when --body-file omitted"
UPDATE_LOG1="$WORK/update-log1"
# GLAB_STUB_UPDATE_OUT is spelled out (rather than left on the stub default)
# because the URL must live under the project this run names: the extractor
# requires the matched token's path to contain the confirmed --repo value.
DEEP_ISSUE_URL_5="https://gitlab.com/$DEEP_PATH/-/work_items/5"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_LOG=$UPDATE_LOG1" "GLAB_STUB_UPDATE_OUT=$DEEP_ISSUE_URL_5" \
	sh "$UPDATE" --confirmed-host gitlab.com --repo "$DEEP_PATH" --issue 5 --title "renamed" \
		--add-label "bug,urgent" --remove-label stale \
		--add-assignee dave --remove-assignee erin --milestone "Q3"
expect_rc "update(no-body-clobber): -> exit 0" 0
stdout_has "update(no-body-clobber): PM_ISSUE_URL (the real '/-/work_items/<iid>' shape)" "PM_ISSUE_URL=$DEEP_ISSUE_URL_5"
check "update(no-body-clobber): argv has NO --description token" "a --description token was found even though none was given — this would CLOBBER the body" \
	"$( argv_has_token "$UPDATE_LOG1" '--description' && echo 1 || echo 0 )"
check "update(no-body-clobber): argv has NO --body-file token either" "a --body-file token was found" \
	"$( argv_has_token "$UPDATE_LOG1" '--body-file' && echo 1 || echo 0 )"
check "update(no-body-clobber): the iid is passed POSITIONALLY (glab takes <id>)" "the issue iid was not the first argv token" \
	"$( argv_first_is "$UPDATE_LOG1" '5' && echo 0 || echo 1 )"
check "update(no-body-clobber): argv carries NO --yes (glab issue update has no such flag)" "a --yes token was passed; real glab rejects it on issue update" \
	"$( argv_has_token "$UPDATE_LOG1" '--yes' && echo 1 || echo 0 )"
check "update(no-body-clobber): --repo (3-segment) passed as one token" "deep repo path missing/mangled in argv" \
	"$( argv_has_pair "$UPDATE_LOG1" '--repo' "$DEEP_PATH" && echo 0 || echo 1 )"
check "update(no-body-clobber): --title passed as one token" "title missing/misplaced in argv" \
	"$( argv_has_pair "$UPDATE_LOG1" '--title' 'renamed' && echo 0 || echo 1 )"
check "update(no-body-clobber): --add-label bug -> glab --label bug" "add-label bug missing from argv" \
	"$( argv_has_pair "$UPDATE_LOG1" '--label' 'bug' && echo 0 || echo 1 )"
check "update(no-body-clobber): --add-label urgent (same comma-list) -> glab --label urgent" "add-label urgent missing from argv" \
	"$( argv_has_pair "$UPDATE_LOG1" '--label' 'urgent' && echo 0 || echo 1 )"
check "update(no-body-clobber): --remove-label stale -> glab --unlabel stale (NOT --remove-label)" "remove-label was not translated to glab's --unlabel" \
	"$( argv_has_pair "$UPDATE_LOG1" '--unlabel' 'stale' && echo 0 || echo 1 )"
check "update(no-body-clobber): --add-assignee dave -> glab --assignee +dave" "add-assignee was not '+'-prefixed (glab would REPLACE the set)" \
	"$( argv_has_pair "$UPDATE_LOG1" '--assignee' '+dave' && echo 0 || echo 1 )"
check "update(no-body-clobber): --remove-assignee erin -> glab --assignee !erin" "remove-assignee was not '!'-prefixed" \
	"$( argv_has_pair "$UPDATE_LOG1" '--assignee' '!erin' && echo 0 || echo 1 )"
check "update(no-body-clobber): no removal value starts with '-' (an argument parser would read it as a flag)" "a '-'-prefixed removal value was passed" \
	"$( argv_has_token "$UPDATE_LOG1" '-erin' && echo 1 || echo 0 )"
check "update(no-body-clobber): an unprefixed bare assignee is never passed (that would REPLACE the set)" "a bare 'dave' token was passed" \
	"$( argv_has_token "$UPDATE_LOG1" 'dave' && echo 1 || echo 0 )"
check "update(no-body-clobber): --milestone Q3 passed as one token" "milestone missing from argv" \
	"$( argv_has_pair "$UPDATE_LOG1" '--milestone' 'Q3' && echo 0 || echo 1 )"

section "update-issue.sh — body IS replaced when --body-file is given"
UBODY="$WORK/update-body.md"
printf '## Updated\nNew content.\n\n' >"$UBODY"
UPDATE_LOG2="$WORK/update-log2"
UBODY_SEEN="$WORK/update-body-seen"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_LOG=$UPDATE_LOG2" "GLAB_STUB_DESC_FILE=$UBODY_SEEN" \
	sh "$UPDATE" --confirmed-host gitlab.com --repo group/sub/proj --issue 5 --body-file "$UBODY"
expect_rc "update(body-replace): -> exit 0" 0
check "update(body-replace): argv HAS a --description token" "expected a --description token in argv" \
	"$( argv_has_token "$UPDATE_LOG2" '--description' && echo 0 || echo 1 )"
check "update(body-replace): the body value is relayed" "body content missing" \
	"$( value_block "$UPDATE_LOG2" 'DESCRIPTION_VALUE' | grep -Fq -- '## Updated' && echo 0 || echo 1 )"
if diff_value_file "$UBODY" "$UBODY_SEEN"; then UBODY_DIFF_RC=0; else UBODY_DIFF_RC=1; fi
check "update(body-replace): body byte-identical, trailing blank line preserved" \
	"$(cat "$WORK/value_diff" 2>/dev/null)" \
	"$UBODY_DIFF_RC"

section "update-issue.sh — --milestone 0 is how a milestone is unassigned"
UPDATE_LOG3="$WORK/update-log3"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_LOG=$UPDATE_LOG3" \
	sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --issue 5 --milestone 0
expect_rc "update(milestone-unassign): -> exit 0" 0
check "update(milestone-unassign): '0' is relayed verbatim as glab's unassign value" "no '--milestone 0' pair in argv" \
	"$( argv_has_pair "$UPDATE_LOG3" '--milestone' '0' && echo 0 || echo 1 )"

section "update-issue.sh — glab issue update itself fails"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_RC=1" sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --issue 1 --title x
expect_rc "update(glab-fail): -> exit 1" 1
stderr_has "update(glab-fail): reports failure" "glab issue update failed"

section "update-issue.sh — both issue-URL path shapes are accepted"
# The stub default above covers the current '/-/work_items/<iid>' shape glab
# actually prints (live-verified, where matching only '/-/issues/' left
# PM_ISSUE_URL empty on a perfectly successful update). This case pins the
# CLASSIC path, which must keep working for an older self-managed instance.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_UPDATE_OUT=https://gitlab.example.com/deep/group/nest/proj/-/issues/5" \
	sh "$UPDATE" --confirmed-host gitlab.com --repo deep/group/nest/proj --issue 5 --title x
expect_rc "update(classic-shape): -> exit 0" 0
stdout_has "update(classic-shape): classic '/-/issues/' URL still accepted" \
	"PM_ISSUE_URL=https://gitlab.example.com/deep/group/nest/proj/-/issues/5"

# Guards the broadening from going too far — see the create counterpart, including
# why --repo MUST match the fixture URL's own project path (otherwise the project
# filter rejects the token first and the shape restriction is never exercised).
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_UPDATE_OUT=https://gitlab.com/group/sub/proj/-/merge_requests/9" \
	sh "$UPDATE" --confirmed-host gitlab.com --repo group/sub/proj --issue 5 --title x
expect_rc "update(wrong-path-segment): -> exit 0 (courtesy contract, never a hard fail)" 0
stdout_re "update(wrong-path-segment): a merge_requests URL of THIS project is NOT relayed" '^PM_ISSUE_URL=$'

section "update-issue.sh — successful update with NO URL returned (courtesy contract)"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_OUT=" sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --issue 1 --title x
expect_rc "update(empty-url): -> exit 0 (the URL is a courtesy, not proof of success)" 0
stdout_re "update(empty-url): PM_ISSUE_URL is empty" '^PM_ISSUE_URL=$'

section "update-issue.sh — a URL-shaped TITLE cannot hijack PM_ISSUE_URL (SEC-001)"
# Same live-observed defect as create-issue.sh's, same fix: the candidate must
# carry the confirmed --repo path, and the dedup leaves at most one line per distinct
# URL, so the single survivor is taken outright rather than picked from several
# occurrences.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_UPDATE_OUT=#5 See https://evil.example/attacker/project/-/issues/1
 https://gitlab.com/group/sub/proj/-/work_items/5" \
	sh "$UPDATE" --confirmed-host gitlab.com --repo group/sub/proj --issue 5 --title "See https://evil.example/attacker/project/-/issues/1"
expect_rc "update(url-shaped title): -> exit 0" 0
stdout_has "update(url-shaped title): PM_ISSUE_URL is the REAL URL" "PM_ISSUE_URL=https://gitlab.com/group/sub/proj/-/work_items/5"
check "update(url-shaped title): the attacker URL never reaches stdout" "the title's URL was relayed to the caller" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'evil.example' && echo 1 || echo 0 )"

section "update-issue.sh — the project filter is ANCHORED to the host (SEC-002)"
# Same residual gap as create-issue.sh's (see that section for the mechanism). The
# spoof is the SOLE shape-matching token, so the ambiguity guard cannot save it and
# the anchor is the only thing that can. DELIBERATE difference from create-issue.sh:
# the edit already succeeded, so the courtesy contract leaves PM_ISSUE_URL empty
# rather than failing.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_UPDATE_OUT=#5 See https://attacker.example/x/group/sub/proj/-/work_items/5" \
	sh "$UPDATE" --confirmed-host gitlab.com --repo group/sub/proj --issue 5 \
		--title "See https://attacker.example/x/group/sub/proj/-/work_items/5"
expect_rc "update(unanchored spoof, sole candidate): -> exit 0 (the update DID happen)" 0
stdout_re "update(unanchored spoof): PM_ISSUE_URL is empty, never the spoof" '^PM_ISSUE_URL=$'
check "update(unanchored spoof): the attacker URL never reaches stdout" \
	"an extra leading path segment let a foreign host masquerade as this project" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'attacker.example' && echo 1 || echo 0 )"

section "update-issue.sh — a REPEATED flag accumulates as well as a comma-list does (TEST-002)"
# All four accumulators share ONE value-returning `accumulate` helper, and every
# case above exercised only the comma-list half of the "repeatable AND/OR
# comma-separated" contract. An accumulator that OVERWROTE instead of appending
# would have kept the whole suite green.
UPDATE_LOG_REPEAT="$WORK/update-log-repeated-flags"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_OUT=" "GLAB_STUB_UPDATE_LOG=$UPDATE_LOG_REPEAT" \
	sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --issue 5 \
		--add-label first --add-label second \
		--remove-label stale --remove-label old \
		--add-assignee alice --add-assignee bob \
		--remove-assignee carol --remove-assignee dave
expect_rc "update(repeated flags): -> exit 0" 0
check "update(repeated flags): both --add-label values arrived" "a repeated --add-label was lost" \
	"$( argv_has_pair "$UPDATE_LOG_REPEAT" '--label' 'first' && argv_has_pair "$UPDATE_LOG_REPEAT" '--label' 'second' && echo 0 || echo 1 )"
check "update(repeated flags): both --remove-label values arrived as --unlabel" "a repeated --remove-label was lost" \
	"$( argv_has_pair "$UPDATE_LOG_REPEAT" '--unlabel' 'stale' && argv_has_pair "$UPDATE_LOG_REPEAT" '--unlabel' 'old' && echo 0 || echo 1 )"
check "update(repeated flags): both --add-assignee values arrived '+'-prefixed" "a repeated --add-assignee was lost" \
	"$( argv_has_pair "$UPDATE_LOG_REPEAT" '--assignee' '+alice' && argv_has_pair "$UPDATE_LOG_REPEAT" '--assignee' '+bob' && echo 0 || echo 1 )"
check "update(repeated flags): both --remove-assignee values arrived '!'-prefixed" "a repeated --remove-assignee was lost" \
	"$( argv_has_pair "$UPDATE_LOG_REPEAT" '--assignee' '!carol' && argv_has_pair "$UPDATE_LOG_REPEAT" '--assignee' '!dave' && echo 0 || echo 1 )"

section "update-issue.sh — comma-list trimming, empty-skip and the glob guard (TEST-003 / TEST-004)"
UPDATE_LOG_TRIM="$WORK/update-log-trim"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_OUT=" "GLAB_STUB_UPDATE_LOG=$UPDATE_LOG_TRIM" \
	sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --issue 5 --add-label "bug, urgent ,," --remove-label '*'
expect_rc "update(csv trim + glob): -> exit 0" 0
check "update(csv trim): 'bug' arrived clean" "the first token was mangled" \
	"$( argv_has_pair "$UPDATE_LOG_TRIM" '--label' 'bug' && echo 0 || echo 1 )"
check "update(csv trim): ' urgent ' arrived TRIMMED to 'urgent'" "surrounding whitespace was not trimmed" \
	"$( argv_has_pair "$UPDATE_LOG_TRIM" '--label' 'urgent' && echo 0 || echo 1 )"
check "update(csv trim): the UNTRIMMED ' urgent ' never reached argv" "an untrimmed token was passed to glab" \
	"$( argv_has_pair "$UPDATE_LOG_TRIM" '--label' ' urgent ' && echo 1 || echo 0 )"
check "update(csv trim): the empty elements produced NO empty --label value" "an empty label value was passed to glab" \
	"$( argv_has_pair "$UPDATE_LOG_TRIM" '--label' '' && echo 1 || echo 0 )"
check "update(glob guard): the literal '*' reached --unlabel (it was NOT filename-expanded)" \
	"the '*' was glob-expanded against the cwd instead of staying literal" \
	"$( argv_has_pair "$UPDATE_LOG_TRIM" '--unlabel' '*' && echo 0 || echo 1 )"

section "update-issue.sh — TWO distinct project URLs leave PM_ISSUE_URL EMPTY + warn (SEC-001)"
# The DELIBERATE difference from create-issue.sh: the edit itself already succeeded
# and PM_ISSUE_URL is a documented courtesy field, so ambiguity must not invent a
# failure exit — it leaves the key empty (never a guess) and says so on stderr.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_UPDATE_OUT=#5 Replaces https://gitlab.com/group/sub/proj/-/issues/4
 https://gitlab.com/group/sub/proj/-/work_items/5" \
	sh "$UPDATE" --confirmed-host gitlab.com --repo group/sub/proj --issue 5 --title "Replaces https://gitlab.com/group/sub/proj/-/issues/4"
expect_rc "update(ambiguous URLs): -> exit 0 (the update DID happen)" 0
stdout_re "update(ambiguous URLs): PM_ISSUE_URL is empty, never guessed" '^PM_ISSUE_URL=$'
stderr_has "update(ambiguous URLs): warns why the field is empty" "MORE THAN ONE distinct issue URL"
stderr_has "update(ambiguous URLs): points at find-duplicate.sh" "find-duplicate.sh"

section "update-issue.sh — the URL arriving ONLY on stderr still populates PM_ISSUE_URL"
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_UPDATE_ERR_OUT=https://gitlab.com/group/sub/proj/-/work_items/5" \
	sh "$UPDATE" --confirmed-host gitlab.com --repo group/sub/proj --issue 5 --title x
expect_rc "update(url-on-stderr): -> exit 0" 0
stdout_has "update(url-on-stderr): PM_ISSUE_URL recovered from stderr" "PM_ISSUE_URL=https://gitlab.com/group/sub/proj/-/work_items/5"

section "update-issue.sh — a spoof on stdout cannot outrank the genuine URL on stderr (SEC-003)"
# Same residual gap as create-issue.sh's (see that section for the full mechanism):
# stdout was scanned FIRST and stderr only as a fallback, so a title-borne URL
# carrying THIS project's path under a foreign host won unopposed whenever glab put
# the real URL on stderr. Both streams now form ONE pool. The spoofed iid is 5 — the
# same issue this run is updating — so the iid cross-check below cannot be what saves
# this case; only the unified scan can.
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_UPDATE_OUT=#5 See https://evil.example/group/sub/proj/-/issues/5" \
	"GLAB_STUB_UPDATE_ERR_OUT= https://gitlab.com/group/sub/proj/-/work_items/5" \
	sh "$UPDATE" --confirmed-host gitlab.com --repo group/sub/proj --issue 5 --title "See https://evil.example/group/sub/proj/-/issues/5"
expect_rc "update(stdout spoof vs stderr URL): -> exit 0 (the update DID happen)" 0
stdout_re "update(stdout spoof vs stderr URL): PM_ISSUE_URL is empty, never the spoof" '^PM_ISSUE_URL=$'
stderr_has "update(stdout spoof vs stderr URL): both streams' candidates reached the ambiguity guard" "MORE THAN ONE distinct issue URL"
check "update(stdout spoof vs stderr URL): the attacker URL never reaches stdout" "the spoofed stdout URL won because stderr was not consulted" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'evil.example' && echo 1 || echo 0 )"

section "update-issue.sh — a URL naming a DIFFERENT iid than --issue is refused (SEC-003)"
# The second half of the SEC-003 fix, available ONLY to the scripts that were handed
# the iid: --issue was validated as a positive integer up front, so it is
# authoritative ground truth the extraction can be cross-checked against. Here the
# sole candidate is a perfectly well-formed URL — right host, right project path —
# for issue #4, while the issue actually updated is #5. Without the cross-check the
# pool holds exactly one candidate, so the ambiguity guard has nothing to catch and
# #4's URL is relayed as if it were this edit's. The mismatch is treated as "no URL
# found": empty key, warn, still exit 0 (the courtesy contract forbids failing a
# completed edit).
run 1 "GLAB_STUB_AUTHED=1" \
	"GLAB_STUB_UPDATE_OUT=#5 Duplicate of https://gitlab.com/group/sub/proj/-/issues/4" \
	sh "$UPDATE" --confirmed-host gitlab.com --repo group/sub/proj --issue 5 --title "Duplicate of https://gitlab.com/group/sub/proj/-/issues/4"
expect_rc "update(iid mismatch): -> exit 0 (the update DID happen)" 0
stdout_re "update(iid mismatch): PM_ISSUE_URL is empty, never another issue's URL" '^PM_ISSUE_URL=$'
stderr_has "update(iid mismatch): the warning names the iid actually printed" "for iid #4"
stderr_has "update(iid mismatch): the warning names the issue that was updated" "not the issue that was updated (#5)"
check "update(iid mismatch): the other issue's URL is never relayed on stdout" "a URL for a different issue was relayed as this one's" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'issues/4' && echo 1 || echo 0 )"

section "update-issue.sh — --issue rejects 0 and leading-zero forms; --milestone 0 still works"
UPDATE_LOG_ZERO="$WORK/update-log-zero"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_UPDATE_LOG=$UPDATE_LOG_ZERO" \
	sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --issue 0 --title x
expect_rc "update(--issue 0): -> exit 2, not a raw glab failure" 2
stderr_has "update(--issue 0): diagnostic" "positive integer"
file_missing "update(--issue 0): glab issue update never invoked" "$UPDATE_LOG_ZERO"
run 1 sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --issue 007 --title x
expect_rc "update(--issue 007): -> exit 2 (007 is not the iid GitLab echoes back)" 2
# The hardened iid validator must NOT bleed into --milestone, whose documented
# unassign value is literally 0 (asserted in full further up).
run 1 "GLAB_STUB_AUTHED=1" sh "$UPDATE" --confirmed-host gitlab.com --repo g/p --issue 5 --milestone 0
expect_rc "update(--milestone 0 with a valid --issue): still accepted -> exit 0" 0

# ===========================================================================
# close-issue.sh
# ===========================================================================
section "close-issue.sh — usage / argument errors"
run 1 sh "$CLOSE" --confirmed-host gitlab.com -h
expect_rc "close(usage): -h -> exit 0" 0
stdout_has "close(usage): help text" "Usage:"

run 1 sh "$CLOSE" --confirmed-host gitlab.com --issue 1
expect_rc "close(missing --repo): -> exit 2" 2
stderr_has "close(missing --repo): diagnostic" "--repo is required"

run 1 sh "$CLOSE" --confirmed-host gitlab.com --repo g/p
expect_rc "close(missing --issue): -> exit 2" 2
stderr_has "close(missing --issue): diagnostic" "--issue is required"

run 1 sh "$CLOSE" --confirmed-host gitlab.com --repo g/p --issue abc
expect_rc "close(non-numeric --issue): -> exit 2" 2
stderr_has "close(non-numeric --issue): diagnostic" "positive integer"

run 1 sh "$CLOSE" --confirmed-host gitlab.com --repo g/p --issue 1 --reason completed
expect_rc "close(--reason rejected): GitLab has no CLI close-reason, so the flag is deliberately absent -> exit 2" 2
stderr_has "close(--reason rejected): diagnostic" "unknown option: --reason"

run 1 sh "$CLOSE" --confirmed-host gitlab.com --repo g/p --issue 1 --comment-file "$WORK/does-not-exist"
expect_rc "close(nonexistent comment-file): -> exit 2" 2
stderr_has "close(nonexistent comment-file): diagnostic" "does not exist or is not readable"

run 1 sh "$CLOSE" --confirmed-host gitlab.com --repo g/p --issue 1 --comment-file "$WORK/empty-body.md"
expect_rc "close(empty comment-file): -> exit 2" 2
stderr_has "close(empty comment-file): diagnostic" "is empty"

CLOSE_NOTE_LOG_DASH="$WORK/close-note-log-dash"
CLOSE_LOG_DASH="$WORK/close-log-dash"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_NOTE_LOG=$CLOSE_NOTE_LOG_DASH" "GLAB_STUB_CLOSE_LOG=$CLOSE_LOG_DASH" \
	sh "$CLOSE" --confirmed-host gitlab.com --repo g/p --issue 1 --comment-file "$WORK/dash-body.md"
expect_rc "close(comment is literally '-'): -> exit 2" 2
stderr_has "close('-' guard): explains the editor hazard" "interactive editor"
file_missing "close('-' guard): glab issue note never invoked" "$CLOSE_NOTE_LOG_DASH"
file_missing "close('-' guard): glab issue close never invoked" "$CLOSE_LOG_DASH"

run 1 sh "$CLOSE" --confirmed-host gitlab.com --repo lonelyproject --issue 1
expect_rc "close(single-segment path): -> exit 2" 2
stderr_has "close(single-segment path): diagnostic" "at least one '/'"

run 1 sh "$CLOSE" --confirmed-host gitlab.com --repo 'g/..' --issue 1
expect_rc "close(traversal path): -> exit 2" 2

run 1 sh "$CLOSE" --confirmed-host gitlab.com --bogus
expect_rc "close(unknown option): -> exit 2" 2
stderr_has "close(unknown option): diagnostic" "unknown option"

section "close-issue.sh — glab absent / not authenticated"
run 0 sh "$CLOSE" --confirmed-host gitlab.com --repo g/p --issue 1
expect_rc "close(no-glab): -> exit 1" 1
stderr_has "close(no-glab): install hint" "gitlab-org/cli"

run 1 "GLAB_STUB_AUTHED=0" sh "$CLOSE" --confirmed-host gitlab.com --repo g/p --issue 1
expect_rc "close(unauth): -> exit 1" 1
stderr_has "close(unauth): diagnostic" "not authenticated"

section "close-issue.sh — bare close (no comment)"
CLOSE_LOG1="$WORK/close-log1"
CLOSE_NOTE_LOG1="$WORK/close-note-log1"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_CLOSE_LOG=$CLOSE_LOG1" "GLAB_STUB_NOTE_LOG=$CLOSE_NOTE_LOG1" \
	sh "$CLOSE" --confirmed-host gitlab.com --repo "$DEEP_PATH" --issue 9
expect_rc "close(bare): -> exit 0" 0
check "close(bare): the iid is passed POSITIONALLY (glab issue close takes <id>|<url>)" "the iid was not the first argv token" \
	"$( argv_first_is "$CLOSE_LOG1" '9' && echo 0 || echo 1 )"
check "close(bare): --repo (3-segment) passed as one token" "deep repo path missing/mangled in argv" \
	"$( argv_has_pair "$CLOSE_LOG1" '--repo' "$DEEP_PATH" && echo 0 || echo 1 )"
check "close(bare): argv has NO --reason token (glab issue close has no such flag)" "a --reason token was passed; real glab rejects it" \
	"$( argv_has_token "$CLOSE_LOG1" '--reason' && echo 1 || echo 0 )"
check "close(bare): argv carries NO --yes (glab issue close has no such flag)" "a --yes token was passed; real glab rejects it on issue close" \
	"$( argv_has_token "$CLOSE_LOG1" '--yes' && echo 1 || echo 0 )"
file_missing "close(bare): no comment was posted when none was asked for" "$CLOSE_NOTE_LOG1"

section "close-issue.sh — --comment-file posts a note BEFORE closing"
CCOMMENT="$WORK/close-comment.md"
printf 'Closing as resolved.\n' >"$CCOMMENT"
CLOSE_NOTE_LOG2="$WORK/close-note-log2"
CLOSE_LOG2="$WORK/close-log2"
CLOSE_MSG_SEEN="$WORK/close-message-seen"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_NOTE_LOG=$CLOSE_NOTE_LOG2" "GLAB_STUB_CLOSE_LOG=$CLOSE_LOG2" \
	"GLAB_STUB_MSG_FILE=$CLOSE_MSG_SEEN" \
	sh "$CLOSE" --confirmed-host gitlab.com --repo group/sub/proj --issue 9 --comment-file "$CCOMMENT"
expect_rc "close(with-comment): -> exit 0" 0
check "close(with-comment): the note was posted" "no glab issue note call was logged" \
	"$( [ -f "$CLOSE_NOTE_LOG2" ] && echo 0 || echo 1 )"
check "close(with-comment): the issue was also closed" "no glab issue close call was logged" \
	"$( [ -f "$CLOSE_LOG2" ] && echo 0 || echo 1 )"
check "close(with-comment): the note used --message, not a close-time comment flag" "no --message token in the note argv" \
	"$( argv_has_token "$CLOSE_NOTE_LOG2" '--message' && echo 0 || echo 1 )"
if diff_value_file "$CCOMMENT" "$CLOSE_MSG_SEEN"; then CLOSE_MSG_DIFF_RC=0; else CLOSE_MSG_DIFF_RC=1; fi
check "close(with-comment): the closing comment reached glab byte-identical to the file" \
	"$(cat "$WORK/value_diff" 2>/dev/null)" \
	"$CLOSE_MSG_DIFF_RC"

section "close-issue.sh — comment post failure aborts BEFORE closing"
CLOSE_LOG3="$WORK/close-log3"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_NOTE_RC=1" "GLAB_STUB_CLOSE_LOG=$CLOSE_LOG3" \
	sh "$CLOSE" --confirmed-host gitlab.com --repo g/p --issue 9 --comment-file "$CCOMMENT"
expect_rc "close(comment-fail): -> exit 1" 1
stderr_has "close(comment-fail): reports failure" "failed to post closing comment"
file_missing "close(comment-fail): glab issue close never invoked" "$CLOSE_LOG3"

section "close-issue.sh — glab issue close itself fails"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_CLOSE_RC=1" sh "$CLOSE" --confirmed-host gitlab.com --repo g/p --issue 9
expect_rc "close(glab-fail): -> exit 1" 1
stderr_has "close(glab-fail): reports failure" "glab issue close failed"
check "close(glab-fail): NO already-posted warning when no comment was ever posted" "the warning appeared even though --comment-file was never given" \
	"$( printf '%s\n' "$CUR_ERR" | grep -Fq -- 'ALREADY POSTED' && echo 1 || echo 0 )"

section "close-issue.sh — --issue rejects 0 and leading-zero forms (usage error, not a glab failure)"
CLOSE_LOG_ZERO="$WORK/close-log-zero"
CLOSE_NOTE_LOG_ZERO="$WORK/close-note-log-zero"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_CLOSE_LOG=$CLOSE_LOG_ZERO" "GLAB_STUB_NOTE_LOG=$CLOSE_NOTE_LOG_ZERO" \
	sh "$CLOSE" --confirmed-host gitlab.com --repo g/p --issue 0 --comment-file "$CCOMMENT"
expect_rc "close(--issue 0): -> exit 2, not a raw glab failure" 2
stderr_has "close(--issue 0): diagnostic" "positive integer"
file_missing "close(--issue 0): glab issue close never invoked" "$CLOSE_LOG_ZERO"
file_missing "close(--issue 0): no closing comment was posted either" "$CLOSE_NOTE_LOG_ZERO"
run 1 sh "$CLOSE" --confirmed-host gitlab.com --repo g/p --issue 007
expect_rc "close(--issue 007): -> exit 2 (007 is not the iid GitLab echoes back)" 2

section "close-issue.sh — close fails AFTER a comment posted: warns against a double-post retry"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_CLOSE_RC=1" sh "$CLOSE" --confirmed-host gitlab.com --repo g/p --issue 9 --comment-file "$CCOMMENT"
expect_rc "close(glab-fail-after-comment): -> exit 1" 1
stderr_has "close(glab-fail-after-comment): reports the close failure" "glab issue close failed"
stderr_has "close(glab-fail-after-comment): warns the comment was already posted" "ALREADY POSTED"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n== summary ==\n'
printf 'ran %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ] || exit 1
printf 'ALL TESTS PASSED\n'
exit 0
