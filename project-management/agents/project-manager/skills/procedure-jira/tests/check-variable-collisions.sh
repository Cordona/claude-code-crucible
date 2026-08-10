#!/usr/bin/env sh
#
# check-variable-collisions.sh — a static guard for the ONE invariant the
# split of jira.sh into 43 units makes harder to eyeball.
#
# WHY THIS EXISTS. POSIX sh has no `local`. Every variable a function assigns is
# a PROCESS-GLOBAL, so a scratch name reused by two functions that can appear in
# the same call chain silently clobbers the caller's copy. skill/lib/runtime.sh's
# CONVENTION note is this engine's answer: every function's scratch/parameter
# variables carry a name unique to that function (jira_curl's `method`/`url`,
# resolve_account_id's `value`/`account_id`, the mnr_*/fpa_*/sched_*/bulk_*
# prefixes, ...). NOTHING about that namespace changed when the engine was
# split — but the violations became much harder to SPOT, because two colliding
# functions now sit in two different files instead of one screen apart. This
# script restores the eyeball.
#
# WHAT IT CHECKS, in three passes:
#   1. Every assignment target `[a-z_][a-z0-9_]*=` in skill/lib/*.sh +
#      skill/scripts/*.sh, attributed to the function it sits in — wherever on
#      its line it sits, not merely line-initial. An assignment counts when the
#      text before it ends where a new simple command may begin: the line start,
#      a separator or opener (`;` `&&` `||` `(` `{` backtick), one of the
#      `then`/`else`/`elif`/`do`/`in` keywords, or a case branch's `)`.
#      `while ... read -r NAME` and `for NAME in` targets are captured too: they
#      are process-globals with exactly the same clobber semantics, and leaving
#      them out would let a real collision through.
#   2. A call graph, closed transitively — which functions each function can
#      reach, however indirectly.
#   3. A DANGEROUS collision = two functions f and g that BOTH assign the same
#      name, where f can reach g, AND f still READS that name on a line AFTER
#      the call that reaches g. That last clause is the whole point: a scratch
#      name a function writes and consumes immediately — before it ever calls
#      into the other writer — cannot be corrupted by it. Only a value the
#      caller expects to survive ACROSS the callee boundary is at risk. Sharing
#      a name without that overlap is noise, and reporting it would train the
#      reader to ignore this script.
#
# WHY "AFTER" IS LINE-STRICT, and the one case it cannot see. A read on the
# SAME line as the call is always safe: an argument (`callee "$name"`) is
# expanded BEFORE the callee runs. The blind spot is a read on the call's own
# line inside a LOOP, where the NEXT iteration reads what the PREVIOUS one's
# callee wrote. Two such overlaps used to exist in this engine — cmd_search /
# build_search_request_body shared $jql, and resolve_fields_csv /
# resolve_field_name shared $config_file. Both were safe in practice, but both
# have since been given per-function prefixes (search_jql/bsrb_jql,
# rfc_config_file/rfn_config_file) so the blind spot no longer has anything to
# hide. Keep it that way: a shared scratch name read on a call's own line
# inside a loop is the ONE defect shape this script cannot see.
#
# WHICH MID-LINE WRITES PASS 1 STILL CANNOT SEE. Pass 1 originally matched only
# a LINE-INITIAL `name=`, which made every `cmd || x=…`, `…; x=…` and
# `then x=…` in skill/lib/ invisible to it AS A WRITE — a live collision of that
# shape was once found by a human reading the code, not by this gate.
# statement_start() has since closed the separator, opener, keyword and
# case-branch forms. What follows is the list of what it STILL misses, each
# entry checked against the current tree rather than inherited from the last
# revision of this comment.
#
# UNDER-REPORTS — an invisible write, the direction that can HIDE a defect:
#   * an assignment after `!`, `while`, `until` or `time`. This engine writes
#     one: `if ! rmu_code=$(curl …)` at skill/lib/http.sh:210. $rmu_code has a
#     single, prefix-unique writer today, so nothing is hidden — but the write
#     itself is invisible, and a second writer of that name would be too.
#   * an assignment inside a ONE-LINE function body (`f() { x=…; }`) — the
#     function-header branch consumes such a line whole and never scans it.
#     This engine writes three: $entry and $rest in list_top_indent(),
#     list_top_type() and list_top_buffer(), skill/scripts/md-to-adf.sh:667-669.
#     Each writes and consumes its value on that one line, so again nothing is
#     hidden today — but a fourth writer of $entry or $rest would be.
#   * a case branch spelled with POSIX's optional LEADING paren
#     (`(PATTERN) x=…`). statement_start()'s case rule demands a `(`-free
#     prefix, which is exactly what keeps it off `"$(cmd)tail=…"`; a leading
#     paren is the price. This engine spells no branch that way.
#   * an assignment built or run through `eval` / a quoted command string, which
#     no line-oriented matcher can resolve. This engine has no `eval`.
#   * a `for NAME in` that is not line-initial (`…; for x in …`) — the `for`
#     matcher is anchored. This engine has none.
#
# OVER-REPORTS — a phantom write. It can raise a FALSE ALARM but never hide a
# real collision, so each is left alone deliberately:
#   * a literal `name=` inside a quoted string right after a real separator
#     (`printf 'a; b=c'`). No such string exists in this engine today.
#   * an `&` that is a query-string separator rather than `&&` or a background
#     `&`: `url="${base}?a=1&b=2"` registers a phantom write of $b. Narrowing
#     this would trade a safe direction for an unsafe one, so it stays. It has
#     no live effect — the engine's one such URL joins on `&maxResults=`, whose
#     capital letter breaks the lowercase-only name match.
#   * a write inside a PARENTHESIZED subshell (`( x=… )`, `$( x=… )`) is
#     counted even though the value cannot escape it. A PIPELINE subshell
#     (`cmd | x=…`) is not counted, because a lone `|` is deliberately not a
#     separator — see statement_start() for why that matters.
#
# EXCLUSIONS — each is an intentional shared global or a one-shot idiom, never a
# scratch name (one line of reason each):
#   ec           cleanup()'s captured exit status; the EXIT trap runs once, last.
#   _jira_unit   jira.sh's sourcing-loop variable; `unset` immediately after.
#
# UPPERCASE NAMES ARE OUT OF SCOPE BY CONSTRUCTION, not by an exclusion list:
# the assignment pattern above matches a LOWERCASE initial only, and this engine
# spells every deliberately shared global in upper case (OPT_*, WORKDIR,
# TICKET_KEY, CONFIRMED_HOST, PROJECT_CONFIG_FILE, JIRA_HTTP_*, *_COUNTER,
# AGILE_COLLECTED, TAB_PAIR_*, SEARCH_UNBOUNDED, COMMAND, JQL_CLAUSES). Those are
# SUPPOSED to be shared; flagging them would be pure noise.
#
# SELF-TEST — this gate checks its OWN analyzer before it checks the engine,
# on every run, and refuses to report a verdict if it cannot. A static analyzer
# has a failure mode no assertion about the codebase can catch: a regex that
# stops matching after a layout change, or a derived table that comes back
# empty, degrades silently to "no collisions found" + exit 0 — a BROKEN gate
# and a CLEAN codebase produce byte-identical output. Two guards close that:
#   * fixtures/varcheck/{dangerous,dangerous-midline,safe}/ — two known-dangerous
#     collisions that MUST be reported (exit 1), and two known-safe shapes that
#     MUST NOT be (exit 0): a shared name whose writers never overlap, and a `)`
#     that closes a command substitution rather than a case branch. The second
#     is the false-positive counterweight to the case-branch rule, and it fails
#     the moment that rule stops demanding a `(`-free prefix. The analyzer is
#     re-run against each via $JIRA_VARCHECK_SKILL_DIR before the real scan; a
#     mismatch aborts with a named diagnostic. dangerous-midline/ covers one
#     mid-line write form per statement-start shape and is asserted BY VARIABLE
#     NAME, not by exit status alone — losing four of its five forms would
#     still exit 1.
#   * an emptiness check on every derived table (files/assign/funcs/calls) —
#     an empty one means the scan matched nothing, which is never true of this
#     engine and always means the analyzer, not the code, is at fault.
#
# Usage:  sh check-variable-collisions.sh
# Exit 0 = no dangerous collision. Exit 1 = at least one, reported below (or
# the analyzer itself failed its self-test / produced an empty table).
#
# Portability: POSIX sh + POSIX awk/grep/sed/sort only — no bashisms, no process
# substitution. Runs identically on macOS (BSD userland) and Linux.
#
set -eu

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# $JIRA_VARCHECK_SKILL_DIR is the self-test's own seam: set, it points the
# analyzer at a fixture tree instead of the real skill AND suppresses the
# self-test (so the recursive invocation below terminates).
SKILL_DIR=$(cd "${JIRA_VARCHECK_SKILL_DIR:-$TESTS_DIR/../skill}" && pwd)

# run_self_test — re-run this analyzer against each fixture tree and assert the
# verdict it is supposed to reach. Aborts the whole gate on any mismatch: a gate
# that cannot prove itself must not be trusted to clear the engine.
run_self_test() {
	self_test_case dangerous 1
	self_test_case safe 0
	self_test_case dangerous-midline 1 'vcm_semi vcm_and vcm_or vcm_then vcm_case'
	printf 'self-test ok (both dangerous fixtures are reported, the safe one is not)\n'
}

# self_test_case NAME WANT_EXIT [REQUIRED_NAMES] — run this analyzer against the
# fixture tree NAME and assert it exits WANT_EXIT. REQUIRED_NAMES, when given,
# is a space-separated list of variables the report must NAME; exit status alone
# is too coarse for a fixture that proves several matcher shapes at once, since
# losing all but one of them still exits 1.
self_test_case() {
	st_name=$1
	st_want=$2
	st_required_names=${3:-}
	st_dir="$TESTS_DIR/fixtures/varcheck/$st_name"
	[ -d "$st_dir" ] || {
		printf '%s: SELF-TEST BROKEN: missing fixture tree %s\n' "${0##*/}" "$st_dir" >&2
		exit 1
	}

	st_got=0
	st_report=$(JIRA_VARCHECK_SKILL_DIR="$st_dir" sh "$0" 2>&1) || st_got=$?
	if [ "$st_got" -ne "$st_want" ]; then
		printf '%s: SELF-TEST FAILED: the %s fixture should exit %s, got %s.\n' \
			"${0##*/}" "$st_name" "$st_want" "$st_got" >&2
		abort_analyzer_broken
	fi

	for st_required in $st_required_names; do
		case $st_report in
			*"\$$st_required:"*) ;;
			*)
				printf '%s: SELF-TEST FAILED: the %s fixture exited %s but its report never names $%s.\n' \
					"${0##*/}" "$st_name" "$st_want" "$st_required" >&2
				abort_analyzer_broken
				;;
		esac
	done
}

# abort_analyzer_broken — the shared tail of every self-test failure. Once the
# analyzer is suspect its verdict on the engine is worthless, so stop here
# rather than reporting one.
abort_analyzer_broken() {
	printf '  The ANALYZER is broken, not (necessarily) the engine — a clean\n' >&2
	printf '  result from it would be meaningless. Fix the analyzer first.\n' >&2
	exit 1
}

[ -n "${JIRA_VARCHECK_SKILL_DIR:-}" ] || run_self_test

WORK=$(mktemp -d "${TMPDIR:-/tmp}/jira-varcheck.XXXXXX")
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

: >"$WORK/files"
for unit_file in "$SKILL_DIR"/lib/*.sh "$SKILL_DIR"/scripts/*.sh; do
	[ -f "$unit_file" ] || continue
	printf '%s\n' "$unit_file" >>"$WORK/files"
done
[ -s "$WORK/files" ] || {
	printf '%s: no unit files found under %s\n' "${0##*/}" "$SKILL_DIR" >&2
	exit 1
}

# ---------------------------------------------------------------------------
# Pass 1 — scan each unit into typed rows:
#   ASSIGN <TAB> file <TAB> function <TAB> line <TAB> name
#   READ   <TAB> file <TAB> function <TAB> line <TAB> name
#   WORD   <TAB> file <TAB> function <TAB> line <TAB> token
#   DEF    <TAB> file <TAB> function <TAB> line <TAB> function
# A function body runs from its `name() {` header to the first `}` at column 0
# — the layout every unit in this engine follows. `function` is empty for a
# top-level (non-function) row.
# ---------------------------------------------------------------------------
: >"$WORK/raw"
while IFS= read -r unit_file; do
	awk -v FNAME="$unit_file" '
		function emit(kind, name) {
			printf "%s\t%s\t%s\t%d\t%s\n", kind, FNAME, fn, FNR, name
		}
		# statement_start(before) -> 1 when BEFORE — the text preceding a
		# candidate `name=` on its own line — ends where a new simple command
		# may begin: the line start, a separator or opener (`;` `&&` `||` `(`
		# `{` backtick), a compound-command keyword, or a case-branch `)`. It
		# admits `cmd || x=…`, `…; x=…`, `then x=…` and `PATTERN) x=…` while
		# still rejecting `--flag=v` (preceded by `-`) and the `b=1` tail of
		# `A_b=1` (preceded by `_`).
		#
		# The case-branch test demands BEFORE hold no `(` AT ALL, which is what
		# keeps it off a command substitution glued to more string: in
		# `"$(urlencode "$x")type=…"` the text before `type=` also ends in `)`,
		# yet carries the matching `(`, so it is correctly not a statement
		# start. A real branch pattern never carries one, however baroque:
		# `*\?*)` and `*[+-][0-9][0-9]:[0-9][0-9])` both pass. The cost is the
		# one branch form POSIX allows but this engine never writes: a
		# LEADING-paren pattern (`(foo) x=…`) is not seen as a write.
		#
		# A LONE `|` and a closing `}` are deliberately NOT separators here.
		# Neither can precede an assignment whose value outlives the line
		# (`cmd | x=1` writes in a subshell; `} x=1` is not valid shell at all),
		# and admitting them costs real noise: the jq program `… | type=="array"`
		# and the query fragment `"${qs}type=$(…)"` both LOOK like a write to
		# $type, and neither is one.
		function statement_start(before) {
			sub(/[ \t]+$/, "", before)
			if (before == "")                   return 1
			if (before ~ /(;|&|\|\||\(|\{|`)$/) return 1
			if (before ~ /(^|[ \t;&|({])(then|else|elif|do|in)$/) return 1
			if (before ~ /^[^(]*\)$/)           return 1
			return 0
		}
		# scan_assignments(line) — emit every assignment target on LINE,
		# wherever in the line it sits, not just a line-initial one. See
		# statement_start() for the boundary test, and the header of this
		# script for the residual mid-line shapes it still cannot see.
		function scan_assignments(line,   sa_off, sa_rest, sa_name) {
			sa_off = 0
			sa_rest = line
			while (match(sa_rest, /[a-z_][a-z0-9_]*=/)) {
				sa_name = substr(sa_rest, RSTART, RLENGTH - 1)
				if (statement_start(substr(line, 1, sa_off + RSTART - 1)))
					emit("ASSIGN", sa_name)
				sa_off += RSTART + RLENGTH - 1
				sa_rest = substr(sa_rest, RSTART + RLENGTH)
			}
		}
		/^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/ {
			hdr = $0; sub(/\(\).*/, "", hdr); fn = hdr
			emit("DEF", fn)
			# a one-line function (`f() { ...; }`) has no body lines of its own
			if ($0 ~ /\}[ \t]*$/) fn = ""
			next
		}
		/^\}[ \t]*$/ { fn = ""; next }
		/^[ \t]*#/   { next }
		{
			line = $0
			scan_assignments(line)
			if (match(line, /read -r [a-z_][a-z0-9_]*/)) {
				emit("ASSIGN", substr(line, RSTART + 8, RLENGTH - 8))
			}
			if (match(line, /^[ \t]*for [a-z_][a-z0-9_]* in /)) {
				t = substr(line, RSTART, RLENGTH)
				sub(/^[ \t]*for /, "", t); sub(/ in $/, "", t)
				emit("ASSIGN", t)
			}
			rest = line
			while (match(rest, /\$\{?[a-z_][a-z0-9_]*/)) {
				t = substr(rest, RSTART, RLENGTH); sub(/^\$\{?/, "", t)
				emit("READ", t)
				rest = substr(rest, RSTART + RLENGTH)
			}
			rest = line
			while (match(rest, /[A-Za-z_][A-Za-z0-9_]*/)) {
				emit("WORD", substr(rest, RSTART, RLENGTH))
				rest = substr(rest, RSTART + RLENGTH)
			}
		}
	' "$unit_file" >>"$WORK/raw"
done <"$WORK/files"

grep '^ASSIGN	' "$WORK/raw" | cut -f2- >"$WORK/assign"
grep '^READ	'   "$WORK/raw" | cut -f2- >"$WORK/read"
grep '^DEF	'    "$WORK/raw" | cut -f5  | LC_ALL=C sort -u >"$WORK/funcs"

# Calls: a WORD token inside function F that names a DEFINED function G != F.
awk -F'\t' '
	NR == FNR { known[$1] = 1; next }
	$1 == "WORD" && $3 != "" && $5 != $3 && ($5 in known) {
		print $3 "\t" $5 "\t" $4
	}
' "$WORK/funcs" "$WORK/raw" | LC_ALL=C sort -u >"$WORK/calls"

# ---------------------------------------------------------------------------
# Pass 2 — transitive reachability: a DFS from every node over the call graph.
# ---------------------------------------------------------------------------
cut -f1,2 "$WORK/calls" | LC_ALL=C sort -u |
	awk -F'\t' '
		{ adj[$1] = adj[$1] " " $2; node[$1] = 1; node[$2] = 1 }
		END {
			for (s in node) {
				split("", seen); split("", stack)
				depth = 1; stack[1] = s
				while (depth > 0) {
					cur = stack[depth--]
					m = split(adj[cur], out, " ")
					for (i = 1; i <= m; i++) {
						t = out[i]
						if (t == "" || (t in seen)) continue
						seen[t] = 1
						print s "\t" t
						stack[++depth] = t
					}
				}
			}
		}
	' | LC_ALL=C sort -u >"$WORK/reach"

# ---------------------------------------------------------------------------
# Analyzer sanity — every derived table must be NON-EMPTY. An empty one means
# the scan matched nothing (a changed layout, a broken regex, a mis-globbed
# path), and the collision analysis that follows would then find nothing FOR
# THE WRONG REASON and exit 0. Fail loudly instead: a broken analyzer must
# never be mistaken for a clean codebase.
# ---------------------------------------------------------------------------
for sanity_table in assign read funcs calls reach; do
	[ -s "$WORK/$sanity_table" ] || {
		printf '%s: ANALYZER BROKEN: the derived "%s" table is EMPTY after scanning %s file(s) under %s.\n' \
			"${0##*/}" "$sanity_table" "$(grep -c . "$WORK/files")" "$SKILL_DIR" >&2
		printf '  This is a defect in THIS script (a stale regex or path), not a clean result.\n' >&2
		exit 1
	}
done

# ---------------------------------------------------------------------------
# Pass 3 — collisions, in one awk analysis over the four derived tables.
# ---------------------------------------------------------------------------
awk -F'\t' '
	function basename(p,   n, a) { n = split(p, a, "/"); return a[n] }

	FILENAME == ASSIGN_F {
		if ($2 == "") next                       # top-level, not a scratch name
		if ($4 == "ec" || $4 == "_jira_unit") next   # documented exclusions
		key = $4 "\t" $2
		if (!(key in ownseen)) {
			ownseen[key] = 1
			owners[$4] = owners[$4] " " $2
			nfun[$4]++
			home[$4 "\t" $2] = basename($1)
		}
		fkey = $4 "\t" basename($1)
		if (!(fkey in fseen)) { fseen[fkey] = 1; nfile[$4]++ }
		next
	}
	FILENAME == READ_F  { if ($2 != "") rd[$2 "\t" $4] = rd[$2 "\t" $4] " " $3; next }
	FILENAME == CALLS_F { callline[$1 "\t" $2] = ($1 "\t" $2 in callline && callline[$1 "\t" $2] < $3) ? callline[$1 "\t" $2] : $3; next }
	FILENAME == REACH_F { reach[$1 "\t" $2] = 1; next }

	function reads_after(f, name, l,   i, a, m) {
		m = split(rd[f "\t" name], a, " ")
		for (i = 1; i <= m; i++) if (a[i] != "" && a[i] + 0 > l) return 1
		return 0
	}
	# earliest line in f whose call target is g or can reach g
	function entry_line(f, g,   k, p, best, l) {
		best = -1
		for (k in callline) {
			split(k, p, "\t")
			if (p[1] != f) continue
			if (p[2] != g && !((p[2] "\t" g) in reach)) continue
			l = callline[k]
			if (best < 0 || l < best) best = l
		}
		return best
	}

	END {
		nmulti = 0
		for (name in nfile) {
			if (nfile[name] < 2) continue
			multi[++nmulti] = name
		}
		if (nmulti) {
			printf "\nnames assigned in more than one FILE (informational — a shared name\n"
			printf "is only a DEFECT when its two writers can meet in one call chain):\n"
			n = asortish(multi, nmulti)
			for (i = 1; i <= nmulti; i++) {
				name = multi[i]
				printf "  %s\n", name
				m = split(owners[name], a, " ")
				for (j = 1; j <= m; j++)
					if (a[j] != "")
						printf "      %s() in %s\n", a[j], home[name "\t" a[j]]
			}
		}

		bad = 0
		for (name in nfun) {
			if (nfun[name] < 2) continue
			m = split(owners[name], a, " ")
			for (i = 1; i <= m; i++) for (j = 1; j <= m; j++) {
				f = a[i]; g = a[j]
				if (f == "" || g == "" || f == g) continue
				if (!((f "\t" g) in reach)) continue
				l = entry_line(f, g)
				if (l < 0) continue
				if (!reads_after(f, name, l)) continue
				if (!bad) {
					printf "\nDANGEROUS COLLISION(S) — a caller reads a scratch name it shares\n"
					printf "with a function it calls, so the callee clobbers it across the\n"
					printf "boundary:\n"
				}
				bad = 1
				printf "  $%s: %s() reaches %s() at its line %d, then reads $%s again\n",
					name, f, g, l, name
			}
		}
		if (bad) {
			printf "\nFIX: rename the scratch variable in ONE of the two functions to a\n"
			printf "name unique to it (see skill/lib/runtime.sh'"'"'s CONVENTION note).\n"
			exit 1
		}
		printf "\nno dangerous variable collisions\n"
	}

	# a tiny insertion sort — POSIX awk has no asort()
	function asortish(arr, n,   i, k, v) {
		for (i = 2; i <= n; i++) {
			v = arr[i]; k = i - 1
			while (k > 0 && arr[k] > v) { arr[k + 1] = arr[k]; k-- }
			arr[k + 1] = v
		}
		return n
	}
' ASSIGN_F="$WORK/assign" READ_F="$WORK/read" CALLS_F="$WORK/calls" REACH_F="$WORK/reach" \
	"$WORK/assign" "$WORK/read" "$WORK/calls" "$WORK/reach" >"$WORK/report" || collision=1

printf 'scanned %s unit file(s); %s function(s); %s assignment site(s)\n' \
	"$(grep -c . "$WORK/files")" "$(grep -c . "$WORK/funcs")" "$(grep -c . "$WORK/assign")"
cat "$WORK/report"
[ "${collision:-0}" -eq 0 ]
