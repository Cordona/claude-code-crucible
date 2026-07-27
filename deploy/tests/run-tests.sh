#!/bin/sh
# run-tests.sh — zero-dependency POSIX test harness for deploy.sh
#
# Builds temporary fixture "framework" trees (agents / skills / CLAUDE.md at various
# nesting depths) via mktemp -d, runs deploy.sh against throwaway targets, and asserts
# behaviour. Not bats; pure POSIX sh, self-contained. shellcheck -s sh clean.
#
# Prints a PASS/FAIL line per assertion and a final tally; exits non-zero if any fail.

set -u

LC_ALL=C
export LC_ALL

# ---------------------------------------------------------------------------
# Locate deploy.sh and a scratch root
# ---------------------------------------------------------------------------

TDIR=$(cd "$(dirname "$0")" && pwd -P) || exit 1
DEPLOY="$TDIR/../deploy.sh"
[ -f "$DEPLOY" ] || {
	printf 'cannot find deploy.sh at %s\n' "$DEPLOY" >&2
	exit 1
}

TESTROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$TESTROOT" 2>/dev/null' EXIT INT TERM

OUT="$TESTROOT/out"
ERR="$TESTROOT/err"
RC=0

# The deployer's own DEFAULT_REQUIRED_AGENTS list, as a comma-separated --required-agents
# value. Since deploy.sh applies that default only to its OWN tree (see IS_OWN_TREE),
# tests that build a synthetic fixture tree and want to exercise Check 2 with the "real"
# five-agent roster must opt in explicitly with this value.
FIXTURE_REQUIRED_AGENTS="decision-arbiter,review-arbiter,software-architect,git-operator,docs-writer"

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

RUN=0
PASSED=0
FAILED=0

ok() {
	RUN=$((RUN + 1))
	PASSED=$((PASSED + 1))
	printf 'PASS: %s\n' "$1"
}

no() {
	RUN=$((RUN + 1))
	FAILED=$((FAILED + 1))
	printf 'FAIL: %s\n' "$1"
}

# t_true DESC CMD... -> pass if CMD succeeds
t_true() {
	t_desc=$1
	shift
	if "$@"; then ok "$t_desc"; else no "$t_desc"; fi
}

# t_false DESC CMD... -> pass if CMD fails
t_false() {
	t_desc=$1
	shift
	if "$@"; then no "$t_desc"; else ok "$t_desc"; fi
}

assert_link() { t_true "$1" test -h "$2"; }
assert_nolink() { t_false "$1" test -h "$2"; }

assert_symlink_live() {
	if [ -h "$2" ] && [ -e "$2" ]; then ok "$1"; else no "$1"; fi
}

assert_regfile() {
	if [ -f "$2" ] && [ ! -h "$2" ]; then ok "$1"; else no "$1"; fi
}

assert_absent() {
	if [ ! -e "$2" ] && [ ! -h "$2" ]; then ok "$1"; else no "$1"; fi
}

# assert_dir_empty DESC DIR -> pass if DIR does not exist, OR exists with zero entries.
# Used for "nothing applied" claims where DIR is $tgt itself: new_dir() (below) already
# pre-creates the target via "mktemp -d", so $tgt always EXISTS before deploy.sh ever
# runs — assert_absent on $tgt would therefore never pass regardless of behavior.
# Checking emptiness is the correct, stronger form of "nothing was applied here".
assert_dir_empty() {
	if [ ! -e "$2" ]; then
		ok "$1"
		return
	fi
	if [ -d "$2" ] && [ -z "$(find "$2" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
		ok "$1"
	else
		no "$1"
	fi
}

assert_content() { t_true "$1" cmp -s "$2" "$3"; }

assert_grep() {
	if grep -q "$2" "$3"; then ok "$1"; else no "$1"; fi
}

# Negative form of assert_grep — asserts the pattern is ABSENT from the file.
assert_not_grep() {
	if grep -q "$2" "$3"; then no "$1 (unexpected match: $2)"; else ok "$1"; fi
}

assert_rc() {
	if [ "$2" -eq "$3" ]; then ok "$1"; else no "$1 (want rc=$2 got $3)"; fi
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

# mk_agent FILE NAME -> writes an agent markdown file with name+description frontmatter.
mk_agent() {
	mkdir -p "$(dirname "$1")"
	cat >"$1" <<EOF
---
name: $2
description: Test agent named $2
---

# $2

Agent body.
EOF
}

# mk_agent_quoted FILE NAME -> agent with a quoted name value (exercises quote trimming).
mk_agent_quoted() {
	mkdir -p "$(dirname "$1")"
	cat >"$1" <<EOF
---
name: "$2"
description: >-
  Test agent with a folded and quoted name value.
---

# $2
EOF
}

# mk_agent_with_skills FILE NAME SKILL... -> agent with name+description frontmatter
# plus a "skills:" list referencing the given SKILL names (may be zero or more).
mk_agent_with_skills() {
	maws_file=$1
	maws_name=$2
	shift 2
	mkdir -p "$(dirname "$maws_file")"
	cat >"$maws_file" <<EOF
---
name: $maws_name
description: Test agent named $maws_name
skills:
EOF
	for maws_skill in "$@"; do
		printf '  - %s\n' "$maws_skill" >>"$maws_file"
	done
	cat >>"$maws_file" <<EOF
---

# $maws_name
EOF
}

# mk_skill DIR NAME -> creates DIR/SKILL.md plus a bundled scripts/tool.sh
mk_skill() {
	mkdir -p "$1/scripts"
	cat >"$1/SKILL.md" <<EOF
---
name: $2
description: Test skill named $2
---

# $2
EOF
	cat >"$1/scripts/tool.sh" <<EOF
#!/bin/sh
echo "$2 tool"
EOF
}

# run_deploy ARGS... -> runs the REAL, unmodified deploy.sh CLI (no injected flags), so
# DEFAULT_REQUIRED_AGENTS and Check 1/Check 2 are in effect exactly as a real invocation
# would see them, unless ARGS itself overrides them. Captures stdout/stderr/exit into
# OUT/ERR/RC. This is the name a new case should reach for by default.
run_deploy() {
	"$DEPLOY" "$@" >"$OUT" 2>"$ERR"
	RC=$?
}

# run_deploy_no_required_check ARGS... -> like run_deploy, but appends
# '--required-agents ""' (disabling Check 2: required-agents presence) UNLESS ARGS
# already sets --required-agents itself. NOTE: since deploy.sh itself only applies
# DEFAULT_REQUIRED_AGENTS to its OWN tree (IS_OWN_TREE), this injection
# is now belt-and-braces for every mktemp-based fixture below (a foreign source already
# has the default off). It stays as explicit, self-documenting insurance against that
# scoping ever changing, and IS load-bearing for case_is_own_tree_enforcement, which
# deliberately runs a COPIED deploy.sh so IS_OWN_TREE=1 and exercises the real default —
# see plain run_deploy there and in the Check 1 / Check 2 cases.
run_deploy_no_required_check() {
	rd_has_ra=0
	for rd_arg in "$@"; do
		case $rd_arg in
		--required-agents | --required-agents=*) rd_has_ra=1 ;;
		esac
	done
	if [ "$rd_has_ra" -eq 1 ]; then
		"$DEPLOY" "$@" >"$OUT" 2>"$ERR"
	else
		"$DEPLOY" "$@" --required-agents "" >"$OUT" 2>"$ERR"
	fi
	RC=$?
}

# snapshot DIR FILE -> records a stable listing (paths + symlink targets) of DIR
snapshot() {
	{
		find "$1" 2>/dev/null | LC_ALL=C sort | while IFS= read -r sp; do
			if [ -h "$sp" ]; then
				printf '%s -> %s\n' "$sp" "$(readlink "$sp")"
			else
				printf '%s\n' "$sp"
			fi
		done
	} >"$2"
}

new_dir() {
	mktemp -d "$TESTROOT/nd.XXXXXX"
}

# ===========================================================================
# Case 1: discovery at arbitrary depths (path-independent)
# ===========================================================================
case_depths() {
	printf '\n-- Case 1: discovery at arbitrary depths --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent "$src/a1.md" agent-top
	mk_agent "$src/x/y/z/deep.md" agent-deep
	mk_skill "$src/skill-top" skill-top
	mk_skill "$src/p/q/r/nested" skill-deep

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case1: exit 0" 0 "$RC"
	assert_symlink_live "case1: shallow agent deployed" "$tgt/agents/agent-top.md"
	assert_symlink_live "case1: deep agent deployed" "$tgt/agents/agent-deep.md"
	assert_symlink_live "case1: shallow skill deployed" "$tgt/skills/skill-top"
	assert_symlink_live "case1: deep skill deployed" "$tgt/skills/skill-deep"
	assert_content "case1: deep agent content matches source" \
		"$tgt/agents/agent-deep.md" "$src/x/y/z/deep.md"
	assert_content "case1: deep skill SKILL.md matches source" \
		"$tgt/skills/skill-deep/SKILL.md" "$src/p/q/r/nested/SKILL.md"
	assert_grep "case1: report lists CREATE count" '^CREATE' "$OUT"
}

# ===========================================================================
# Case 2: name comes from frontmatter, not filename or dir name
# ===========================================================================
case_name_from_frontmatter() {
	printf '\n-- Case 2: name from frontmatter, not path --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	# Agent file named differently from its frontmatter name.
	mk_agent "$src/misleading-filename.md" real-agent-name
	# Quoted-name agent.
	mk_agent_quoted "$src/deep/another.md" quoted-agent
	# Skill dir named differently from its frontmatter name.
	mk_skill "$src/wrong-dir-name" real-skill-name

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case2: exit 0" 0 "$RC"
	assert_symlink_live "case2: agent uses frontmatter name" "$tgt/agents/real-agent-name.md"
	assert_absent "case2: agent NOT named after filename" "$tgt/agents/misleading-filename.md"
	assert_symlink_live "case2: quoted name trimmed" "$tgt/agents/quoted-agent.md"
	assert_symlink_live "case2: skill uses frontmatter name" "$tgt/skills/real-skill-name"
	assert_absent "case2: skill NOT named after dir" "$tgt/skills/wrong-dir-name"
}

# ===========================================================================
# Case 3: root CLAUDE.md symlinked to <target>/CLAUDE.md
# ===========================================================================
case_root_config() {
	printf '\n-- Case 3: root CLAUDE.md --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	printf '# Claude Code Configuration\nhello\n' >"$src/CLAUDE.md"
	mk_agent "$src/a.md" some-agent

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case3: exit 0" 0 "$RC"
	assert_symlink_live "case3: CLAUDE.md symlinked" "$tgt/CLAUDE.md"
	assert_content "case3: CLAUDE.md content matches" "$tgt/CLAUDE.md" "$src/CLAUDE.md"
	# The root CLAUDE.md (no frontmatter) must NOT be treated as an agent.
	assert_absent "case3: CLAUDE.md not deployed as agent" "$tgt/agents/CLAUDE.md"
}

# ===========================================================================
# Case 4: tests/, .git/, deploy/ and .DS_Store ignored
# ===========================================================================
case_ignored() {
	printf '\n-- Case 4: ignored paths --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent "$src/keeper.md" keeper-agent
	# Decoys that must be ignored:
	mk_agent "$src/tests/ignored.md" tests-agent
	mk_skill "$src/tests/skilldir" tests-skill
	mk_agent "$src/.git/hooks/ignored.md" git-agent
	mk_skill "$src/.git/skilldir" git-skill
	mk_agent "$src/deploy/ignored.md" deploy-agent
	mk_skill "$src/deploy/skilldir" deploy-skill
	# .DS_Store should never be discovered.
	printf '\0garbage\n' >"$src/.DS_Store"
	mk_agent "$src/sub/.DS_Store.md" ds-like

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case4: exit 0" 0 "$RC"
	assert_symlink_live "case4: real agent deployed" "$tgt/agents/keeper-agent.md"
	assert_absent "case4: tests/ agent ignored" "$tgt/agents/tests-agent.md"
	assert_absent "case4: tests/ skill ignored" "$tgt/skills/tests-skill"
	assert_absent "case4: .git/ agent ignored" "$tgt/agents/git-agent.md"
	assert_absent "case4: .git/ skill ignored" "$tgt/skills/git-skill"
	assert_absent "case4: deploy/ agent ignored" "$tgt/agents/deploy-agent.md"
	assert_absent "case4: deploy/ skill ignored" "$tgt/skills/deploy-skill"
	assert_absent "case4: DS_Store not present in target" "$tgt/.DS_Store"
}

# ===========================================================================
# Case 5: collision -> non-zero exit, nothing applied
# ===========================================================================
case_collision() {
	printf '\n-- Case 5: name collision --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent "$src/one/dup.md" dup-agent
	mk_agent "$src/two/dup.md" dup-agent

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case5: exit 3 on collision" 3 "$RC"
	assert_grep "case5: collision reported to stderr" 'COLLISION' "$ERR"
	assert_grep "case5: collision names the agent" 'dup-agent' "$ERR"
	# Nothing applied: target agents dir not even created.
	assert_absent "case5: nothing applied (no agents dir)" "$tgt/agents"
}

# ===========================================================================
# Case 6: idempotency (second identical run = zero changes)
# ===========================================================================
case_idempotent() {
	printf '\n-- Case 6: idempotency --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent "$src/a.md" idem-agent
	mk_skill "$src/s" idem-skill
	printf '# Claude Code Configuration\n' >"$src/CLAUDE.md"

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case6: first run exit 0" 0 "$RC"
	snapshot "$tgt" "$TESTROOT/snap1"

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case6: second run exit 0" 0 "$RC"
	snapshot "$tgt" "$TESTROOT/snap2"

	assert_grep "case6: second run creates nothing" '^CREATE (0):' "$OUT"
	assert_grep "case6: second run skips items" '^SKIP (3):' "$OUT"
	t_true "case6: on-disk state unchanged" cmp -s "$TESTROOT/snap1" "$TESTROOT/snap2"
}

# ===========================================================================
# Case 7: --dry-run changes nothing on disk
# ===========================================================================
case_dry_run() {
	printf '\n-- Case 7: dry-run --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent "$src/a.md" dry-agent
	mk_skill "$src/s" dry-skill
	printf '# Claude Code Configuration\n' >"$src/CLAUDE.md"

	run_deploy_no_required_check --dry-run --source "$src" --target "$tgt"
	assert_rc "case7: exit 0" 0 "$RC"
	assert_grep "case7: report says dry-run" 'dry-run' "$OUT"
	assert_grep "case7: plan shows CREATE (3)" '^CREATE (3):' "$OUT"
	# Nothing written.
	assert_absent "case7: no agents dir created" "$tgt/agents"
	assert_absent "case7: no skills dir created" "$tgt/skills"
	assert_absent "case7: no CLAUDE.md link created" "$tgt/CLAUDE.md"
}

# ===========================================================================
# Case 8: --copy-agents copies agents but still symlinks skills
# ===========================================================================
case_copy_agents() {
	printf '\n-- Case 8: --copy-agents --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent "$src/a.md" copy-agent
	mk_skill "$src/s" copy-skill

	run_deploy_no_required_check --copy-agents --source "$src" --target "$tgt"
	assert_rc "case8: exit 0" 0 "$RC"
	assert_regfile "case8: agent is a real copy (not symlink)" "$tgt/agents/copy-agent.md"
	assert_content "case8: copied agent content matches" "$tgt/agents/copy-agent.md" "$src/a.md"
	assert_link "case8: skill is still a symlink" "$tgt/skills/copy-skill"
	assert_content "case8: skill script reachable via link" \
		"$tgt/skills/copy-skill/scripts/tool.sh" "$src/s/scripts/tool.sh"
}

# ===========================================================================
# Case 9: prune removes stale framework links; leaves foreign links & real copies
# ===========================================================================
case_prune() {
	printf '\n-- Case 9: prune scope --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent "$src/keep.md" keep-agent
	mk_agent "$src/gone.md" gone-agent

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case9: initial run exit 0" 0 "$RC"
	assert_symlink_live "case9: gone-agent initially present" "$tgt/agents/gone-agent.md"

	# Add a FOREIGN symlink (points outside the framework) and a REAL copy.
	foreign_target="$TESTROOT/foreign.txt"
	printf 'foreign\n' >"$foreign_target"
	ln -s "$foreign_target" "$tgt/agents/foreign-link.md"
	printf 'a real copy\n' >"$tgt/agents/real-copy.md"

	# Remove a source, then re-run.
	rm -f "$src/gone.md"
	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case9: re-run exit 0" 0 "$RC"

	assert_symlink_live "case9: keep-agent survives" "$tgt/agents/keep-agent.md"
	assert_absent "case9: stale framework link pruned" "$tgt/agents/gone-agent.md"
	assert_grep "case9: prune reported" 'gone-agent' "$OUT"
	assert_link "case9: foreign symlink untouched" "$tgt/agents/foreign-link.md"
	assert_content "case9: foreign symlink still resolves" \
		"$tgt/agents/foreign-link.md" "$foreign_target"
	assert_regfile "case9: real copy untouched" "$tgt/agents/real-copy.md"

	# --no-prune must NOT remove a stale link.
	src2=$(new_dir)
	tgt2=$(new_dir)
	mk_agent "$src2/x.md" np-keep
	mk_agent "$src2/y.md" np-gone
	run_deploy_no_required_check --source "$src2" --target "$tgt2"
	assert_rc "case9: no-prune setup exit 0" 0 "$RC"
	rm -f "$src2/y.md"
	run_deploy_no_required_check --no-prune --source "$src2" --target "$tgt2"
	assert_rc "case9: no-prune run exit 0" 0 "$RC"
	assert_link "case9: --no-prune keeps stale link" "$tgt2/agents/np-gone.md"
}

# ===========================================================================
# Case 10: diverged real copy left in place; identical real copy -> symlink
# ===========================================================================
case_diverged() {
	printf '\n-- Case 10: diverged vs identical copies --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent "$src/same.md" identical-agent
	mk_agent "$src/diff.md" diverged-agent
	mkdir -p "$tgt/agents"

	# Identical real copy in place of a link.
	cp "$src/same.md" "$tgt/agents/identical-agent.md"
	# Diverged real copy (edited).
	cp "$src/diff.md" "$tgt/agents/diverged-agent.md"
	printf 'LOCAL EDIT\n' >>"$tgt/agents/diverged-agent.md"

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case10: exit 0" 0 "$RC"

	assert_link "case10: identical copy replaced by symlink" "$tgt/agents/identical-agent.md"
	assert_grep "case10: identical reported as REPLACE" 'identical-agent' "$OUT"

	assert_regfile "case10: diverged copy left as real file" "$tgt/agents/diverged-agent.md"
	assert_grep "case10: diverged reported" 'diverged-agent' "$OUT"
	assert_grep "case10: DIVERGED section present" '^DIVERGED' "$OUT"
	# The diverged copy must NOT have been clobbered.
	t_true "case10: diverged copy content preserved" \
		grep -q 'LOCAL EDIT' "$tgt/agents/diverged-agent.md"
}

# ===========================================================================
# Case 11: skill symlink carries its bundled scripts/
# ===========================================================================
case_bundled_scripts() {
	printf '\n-- Case 11: skill bundled scripts --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_skill "$src/deep/nested/bundle" bundle-skill
	printf 'extra payload\n' >"$src/deep/nested/bundle/scripts/extra.sh"

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case11: exit 0" 0 "$RC"
	assert_link "case11: skill is a symlink" "$tgt/skills/bundle-skill"
	t_true "case11: bundled scripts dir reachable" test -d "$tgt/skills/bundle-skill/scripts"
	assert_content "case11: tool.sh reachable via link" \
		"$tgt/skills/bundle-skill/scripts/tool.sh" "$src/deep/nested/bundle/scripts/tool.sh"
	assert_content "case11: extra.sh reachable via link" \
		"$tgt/skills/bundle-skill/scripts/extra.sh" "$src/deep/nested/bundle/scripts/extra.sh"
}

# ===========================================================================
# Case 12: --only restricts the run to one type
# ===========================================================================
case_only() {
	printf '\n-- Case 12: --only scope --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent "$src/a.md" only-agent
	mk_skill "$src/s" only-skill
	printf '# Claude Code Configuration\n' >"$src/CLAUDE.md"

	run_deploy_no_required_check --only agents --source "$src" --target "$tgt"
	assert_rc "case12: --only agents exit 0" 0 "$RC"
	assert_symlink_live "case12: agent deployed" "$tgt/agents/only-agent.md"
	assert_absent "case12: skill NOT deployed" "$tgt/skills/only-skill"
	assert_absent "case12: config NOT deployed" "$tgt/CLAUDE.md"

	tgt2=$(new_dir)
	run_deploy_no_required_check --only skills --source "$src" --target "$tgt2"
	assert_rc "case12: --only skills exit 0" 0 "$RC"
	assert_symlink_live "case12: skill deployed" "$tgt2/skills/only-skill"
	assert_absent "case12: agent NOT deployed" "$tgt2/agents/only-agent.md"

	tgt3=$(new_dir)
	run_deploy_no_required_check --only config --source "$src" --target "$tgt3"
	assert_rc "case12: --only config exit 0" 0 "$RC"
	assert_symlink_live "case12: config deployed" "$tgt3/CLAUDE.md"
	assert_absent "case12: agents dir not created" "$tgt3/agents"
}

# ===========================================================================
# Case 13: usage / argument errors
# ===========================================================================
case_usage() {
	printf '\n-- Case 13: usage errors --\n'
	run_deploy_no_required_check --help
	assert_rc "case13: --help exits 0" 0 "$RC"
	assert_grep "case13: --help prints usage" 'Usage:' "$OUT"

	run_deploy_no_required_check --bogus-flag
	assert_rc "case13: unknown flag exits 2" 2 "$RC"

	run_deploy_no_required_check --only bogus --source "$TESTROOT" --target "$TESTROOT/x"
	assert_rc "case13: bad --only exits 2" 2 "$RC"

	run_deploy_no_required_check --source /no/such/dir/anywhere --target "$TESTROOT/x"
	t_true "case13: missing source is fatal (non-zero)" test "$RC" -ne 0
	assert_rc "case13: missing source exits 1" 1 "$RC"
}

# ===========================================================================
# Case 14: replace an incorrect (wrongly-pointed) framework symlink
# ===========================================================================
case_relink() {
	printf '\n-- Case 14: relink wrong symlink --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent "$src/a.md" relink-agent
	mkdir -p "$tgt/agents"
	# Pre-existing symlink pointing at the WRONG source path (but still inside source).
	mk_agent "$src/other.md" relink-agent-src2
	ln -s "$src/other.md" "$tgt/agents/relink-agent.md"

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case14: exit 0" 0 "$RC"
	assert_symlink_live "case14: link still present" "$tgt/agents/relink-agent.md"
	assert_content "case14: link now points at correct source" \
		"$tgt/agents/relink-agent.md" "$src/a.md"
}

# ===========================================================================
# Case 15: unsafe frontmatter name — skill dies, agent skipped+warned
# ===========================================================================
case_unsafe_name() {
	printf '\n-- Case 15: unsafe name: values --\n'
	# Skill with a traversal name -> hard error.
	src=$(new_dir)
	tgt=$(new_dir)
	mk_skill "$src/evil" "../../../../etc/pwned"
	run_deploy_no_required_check --source "$src" --target "$tgt"
	t_true "case15: unsafe skill name is fatal (non-zero)" test "$RC" -ne 0
	assert_grep "case15: unsafe skill name diagnosed" "unsafe 'name:'" "$ERR"
	assert_absent "case15: nothing escaped the target" "$tgt/../etc"

	# Agent with a slash in the name -> skipped, warned, run still succeeds.
	src2=$(new_dir)
	tgt2=$(new_dir)
	mk_agent "$src2/good.md" good-agent
	mk_agent "$src2/bad.md" "../../evil"
	run_deploy_no_required_check --source "$src2" --target "$tgt2"
	assert_rc "case15: run with bad agent still exits 0" 0 "$RC"
	assert_grep "case15: bad agent warned as unsafe" "unsafe 'name:'" "$ERR"
	assert_symlink_live "case15: good agent still deployed" "$tgt2/agents/good-agent.md"
	assert_absent "case15: unsafe agent not deployed anywhere" "$tgt2/agents/evil.md"
	# No traversal artifact created next to the target.
	assert_absent "case15: no escaped agent file" "$tgt2/../evil.md"
}

# ===========================================================================
# Case 16: prune must NOT follow a `..`-escaping foreign symlink
# ===========================================================================
case_prune_traversal() {
	printf '\n-- Case 16: prune traversal guard --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent "$src/keep.md" trav-keep
	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case16: setup exit 0" 0 "$RC"

	# A symlink whose LITERAL target string starts with the framework root but escapes it
	# via `..`. It must be treated as foreign and left untouched by prune.
	outside="$TESTROOT/outside-secret.txt"
	printf 'secret\n' >"$outside"
	src_canon=$(cd "$src" && pwd -P)
	ln -s "$src_canon/../../outside-secret.txt" "$tgt/agents/escaper.md" 2>/dev/null ||
		ln -s "$outside" "$tgt/agents/escaper.md"

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case16: re-run exit 0" 0 "$RC"
	assert_link "case16: traversal foreign link NOT pruned" "$tgt/agents/escaper.md"
	assert_grep "case16: escaper not listed under PRUNE" 'trav-keep' "$OUT"
	t_false "case16: escaper name absent from report" grep -q 'escaper' "$OUT"
}

# ===========================================================================
# Case 17: foreign symlink at a managed name is protected (DIVERGED, not REPLACE)
# ===========================================================================
case_foreign_protected() {
	printf '\n-- Case 17: foreign symlink at managed name --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent "$src/a.md" managed-agent
	mkdir -p "$tgt/agents"
	# User's own link at the SAME name, pointing outside the framework.
	dotfile="$TESTROOT/dotfiles-agent.md"
	printf 'user managed\n' >"$dotfile"
	ln -s "$dotfile" "$tgt/agents/managed-agent.md"

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case17: exit 0" 0 "$RC"
	assert_link "case17: foreign link still a symlink" "$tgt/agents/managed-agent.md"
	assert_content "case17: foreign link untouched (still user's file)" \
		"$tgt/agents/managed-agent.md" "$dotfile"
	assert_grep "case17: reported as DIVERGED" '^DIVERGED' "$OUT"
	assert_grep "case17: names the protected agent" 'managed-agent' "$OUT"

	# Same protection under --copy-agents.
	tgt2=$(new_dir)
	mkdir -p "$tgt2/agents"
	ln -s "$dotfile" "$tgt2/agents/managed-agent.md"
	run_deploy_no_required_check --copy-agents --source "$src" --target "$tgt2"
	assert_rc "case17: copy-agents exit 0" 0 "$RC"
	assert_link "case17: copy-agents leaves foreign link" "$tgt2/agents/managed-agent.md"
	assert_content "case17: copy-agents did not clobber foreign link" \
		"$tgt2/agents/managed-agent.md" "$dotfile"
}

# ===========================================================================
# Case 18: CRLF frontmatter parses identically to LF
# ===========================================================================
case_crlf() {
	printf '\n-- Case 18: CRLF frontmatter --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	# Write an agent with CRLF line endings (%b keeps the format from starting with '-').
	mkdir -p "$src"
	printf '%b' '---\r\nname: crlf-agent\r\ndescription: has carriage returns\r\n---\r\n\r\n# body\r\n' \
		>"$src/crlf.md"
	# And a CRLF skill.
	mkdir -p "$src/sk"
	printf '%b' '---\r\nname: crlf-skill\r\ndescription: crlf skill\r\n---\r\n' >"$src/sk/SKILL.md"

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case18: exit 0" 0 "$RC"
	assert_symlink_live "case18: CRLF agent name parsed (no trailing CR)" \
		"$tgt/agents/crlf-agent.md"
	assert_symlink_live "case18: CRLF skill name parsed" "$tgt/skills/crlf-skill"
	# A stray CR in the name would have produced a different path; assert the clean one only.
	assert_grep "case18: report lists clean agent name" 'crlf-agent' "$OUT"
}

# ===========================================================================
# Case 19: empty-string --target / --source are rejected
# ===========================================================================
case_empty_args() {
	printf '\n-- Case 19: empty option arguments --\n'
	run_deploy_no_required_check --target "" --source "$TESTROOT"
	assert_rc "case19: empty --target rejected (rc 2)" 2 "$RC"
	run_deploy_no_required_check --source "" --target "$TESTROOT/x"
	assert_rc "case19: empty --source rejected (rc 2)" 2 "$RC"
	run_deploy_no_required_check --only "" --source "$TESTROOT" --target "$TESTROOT/x"
	assert_rc "case19: empty --only rejected (rc 2)" 2 "$RC"
	run_deploy_no_required_check --target= --source "$TESTROOT"
	assert_rc "case19: empty --target= rejected (rc 2)" 2 "$RC"
}

# ===========================================================================
# Case 20: target inside the framework root is refused
# ===========================================================================
case_target_inside_source() {
	printf '\n-- Case 20: target nested in source --\n'
	src=$(new_dir)
	mk_agent "$src/a.md" nested-agent
	run_deploy_no_required_check --source "$src" --target "$src/sub/target"
	t_true "case20: nested target is fatal (non-zero)" test "$RC" -ne 0
	assert_rc "case20: nested target exits 1" 1 "$RC"
	assert_grep "case20: diagnosed as inside framework root" 'inside the framework root' "$ERR"

	run_deploy_no_required_check --source "$src" --target "$src"
	t_true "case20: target == source is fatal" test "$RC" -ne 0
}

# ===========================================================================
# Case 21: skills: reference resolution (Check 1) -> exit 4, nothing applied
# ===========================================================================
case_skill_ref_check() {
	printf '\n-- Case 21: skills: reference resolution (Check 1) --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_skill "$src/sk" real-skill
	mk_agent_with_skills "$src/bad.md" ref-agent missing-skill

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case21: unresolved skill ref exits 4" 4 "$RC"
	assert_grep "case21: names the agent" 'ref-agent' "$ERR"
	assert_grep "case21: names the unresolved skill" 'missing-skill' "$ERR"
	# Target-wide emptiness: mkdir of the target itself happens strictly AFTER both
	# checks in main(), so on a violation NOTHING at all should exist under $tgt (a
	# stronger, more meaningful claim than just "$tgt/agents" is absent).
	assert_dir_empty "case21: nothing applied (target dir empty/absent)" "$tgt"

	# An agent whose skills: entry DOES resolve deploys normally.
	src2=$(new_dir)
	tgt2=$(new_dir)
	mk_skill "$src2/sk" real-skill
	mk_agent_with_skills "$src2/good.md" ok-agent real-skill
	run_deploy_no_required_check --source "$src2" --target "$tgt2"
	assert_rc "case21: resolved skill ref exits 0" 0 "$RC"
	assert_symlink_live "case21: agent with resolved ref deployed" "$tgt2/agents/ok-agent.md"

	# mk_agent_with_skills with ZERO skill args writes a "skills:" key with an empty
	# block (immediately followed by the frontmatter close) — zero references, not an
	# error, proving the "zero or more" claim in its own doc comment.
	src3=$(new_dir)
	tgt3=$(new_dir)
	mk_agent_with_skills "$src3/zero.md" zero-skills-agent
	run_deploy_no_required_check --source "$src3" --target "$tgt3"
	assert_rc "case21: skills: block with zero items exits 0" 0 "$RC"
	assert_symlink_live "case21: zero-skills agent deployed" "$tgt3/agents/zero-skills-agent.md"
}

# ===========================================================================
# Case 22: required-agents presence (Check 2) -> exit 5, nothing applied
# ===========================================================================
case_required_agents_check() {
	printf '\n-- Case 22: required-agents presence (Check 2) --\n'
	# Fixture satisfies four of the five default-required agents; docs-writer is
	# intentionally omitted. This is a SYNTHETIC (foreign) tree, so DEFAULT_REQUIRED_AGENTS
	# does NOT apply automatically (it is scoped to IS_OWN_TREE) — every assertion below
	# that wants the check enforced opts in explicitly via --required-agents.
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent "$src/a.md" decision-arbiter
	mk_agent "$src/b.md" review-arbiter
	mk_agent "$src/c.md" software-architect
	mk_agent "$src/d.md" git-operator

	run_deploy --required-agents "$FIXTURE_REQUIRED_AGENTS" --source "$src" --target "$tgt"
	assert_rc "case22: missing required agent exits 5" 5 "$RC"
	assert_grep "case22: names the missing agent" 'docs-writer' "$ERR"
	# Target-wide emptiness: mkdir of the target itself happens strictly AFTER both
	# checks, so a violation must leave NOTHING under $tgt, not just "$tgt/agents" absent.
	assert_dir_empty "case22: nothing applied (target dir empty/absent)" "$tgt"

	# A foreign tree with NO --required-agents override at all deploys with Check 2 a
	# no-op (the whole point of the own-tree scoping): the same tree, still missing docs-writer,
	# deploys cleanly with zero flags.
	tgt1b=$(new_dir)
	run_deploy --source "$src" --target "$tgt1b"
	assert_rc "case22: foreign tree with no override has Check 2 disabled by default" 0 "$RC"

	# --required-agents "" disables the check entirely, explicitly: the same tree, still
	# missing docs-writer, still deploys.
	tgt2=$(new_dir)
	run_deploy --required-agents "" --source "$src" --target "$tgt2"
	assert_rc "case22: --required-agents \"\" disables the check" 0 "$RC"
	assert_symlink_live "case22: tree missing a default-required agent still deploys" \
		"$tgt2/agents/decision-arbiter.md"

	# A custom --required-agents list that the fixture DOES satisfy passes.
	tgt3=$(new_dir)
	run_deploy --required-agents "decision-arbiter,git-operator" --source "$src" --target "$tgt3"
	assert_rc "case22: satisfied custom required-agents list exits 0" 0 "$RC"

	# The negative twin: a custom list containing a name the fixture does NOT satisfy
	# must still fail (guards against a regression that silently treats any override as
	# an empty/no-op list).
	tgt3b=$(new_dir)
	run_deploy --required-agents "decision-arbiter,nonexistent-agent" --source "$src" --target "$tgt3b"
	assert_rc "case22: unsatisfied custom required-agents list exits 5" 5 "$RC"
	assert_grep "case22: names the unsatisfied custom entry" 'nonexistent-agent' "$ERR"

	# Whitespace around comma-separated entries is tolerated AND still enforced — the
	# positive case alone (rc 0) is asserting only that entries were "parsed"; a
	# regression that silently treats a whitespace-padded list as empty/no-op would
	# ALSO pass rc 0, so the negative twin (an unsatisfied padded entry -> rc 5, named)
	# is what actually proves enforcement.
	tgt3c=$(new_dir)
	run_deploy --required-agents " decision-arbiter , git-operator " --source "$src" --target "$tgt3c"
	assert_rc "case22: whitespace-padded required-agents list exits 0" 0 "$RC"

	tgt3d=$(new_dir)
	run_deploy --required-agents " decision-arbiter , nonexistent-agent " --source "$src" --target "$tgt3d"
	assert_rc "case22: unsatisfied whitespace-padded list is still enforced, exits 5" 5 "$RC"
	assert_grep "case22: names the unsatisfied padded entry" 'nonexistent-agent' "$ERR"

	# The '=' form works identically, including the empty-disable spelling.
	tgt4=$(new_dir)
	run_deploy --required-agents="$FIXTURE_REQUIRED_AGENTS" --source "$src" --target "$tgt4"
	assert_rc "case22: --required-agents=LIST ('=' form) enforces the check" 5 "$RC"

	tgt5=$(new_dir)
	run_deploy --required-agents= --source "$src" --target "$tgt5"
	assert_rc "case22: --required-agents= (empty, '=' form) disables the check" 0 "$RC"
}

# ===========================================================================
# Case 23: both checks together, happy path -> exit 0
# ===========================================================================
case_checks_happy_path() {
	printf '\n-- Case 23: skills refs + required agents happy path --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_skill "$src/sk" helper-skill
	mk_agent_with_skills "$src/arbiter.md" decision-arbiter helper-skill
	mk_agent "$src/fa.md" review-arbiter
	mk_agent "$src/sa.md" software-architect
	mk_agent "$src/go.md" git-operator
	mk_agent "$src/dw.md" docs-writer

	# Foreign tree: opt in explicitly so Check 2 is actually exercised (the default is own-tree-only).
	run_deploy --required-agents "$FIXTURE_REQUIRED_AGENTS" --source "$src" --target "$tgt"
	assert_rc "case23: happy path exits 0" 0 "$RC"
	assert_symlink_live "case23: decision-arbiter (resolved skills ref) deployed" "$tgt/agents/decision-arbiter.md"
	assert_symlink_live "case23: referenced skill deployed" "$tgt/skills/helper-skill"
	assert_symlink_live "case23: docs-writer deployed" "$tgt/agents/docs-writer.md"
}

# ===========================================================================
# Case 24: the real crucible tree passes both checks under --dry-run
# ===========================================================================
# Case 3b: CLAUDE.md is discovered by MARKER anywhere under the root, not pinned
# to the root itself. Regression guard: it formerly required $ROOT/CLAUDE.md, so
# moving the file produced a silent PRUNE of the deployed copy instead of a
# redeploy — "not found" and "deliberately removed" were indistinguishable.
# ===========================================================================
case_nested_config() {
	printf '\n-- Case 3b: CLAUDE.md discovered in a subdirectory --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mkdir -p "$src/main-thread"
	printf '# Claude Code Configuration\nnested\n' >"$src/main-thread/CLAUDE.md"
	mk_agent "$src/a.md" some-agent

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case3b: exit 0" 0 "$RC"
	assert_symlink_live "case3b: nested CLAUDE.md symlinked" "$tgt/CLAUDE.md"
	assert_content "case3b: nested CLAUDE.md content matches" "$tgt/CLAUDE.md" "$src/main-thread/CLAUDE.md"
	assert_grep "case3b: nothing pruned" '^PRUNE (0):' "$OUT"
}

# ===========================================================================
# Case 3c: two CLAUDE.md under the root is ambiguous and FATAL (exit 3), never
# silently resolved to one of them.
# ===========================================================================
case_duplicate_config() {
	printf '\n-- Case 3c: duplicate CLAUDE.md is fatal --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mkdir -p "$src/main-thread"
	printf '# Claude Code Configuration\none\n' >"$src/CLAUDE.md"
	printf '# Claude Code Configuration\ntwo\n' >"$src/main-thread/CLAUDE.md"
	mk_agent "$src/a.md" some-agent

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case3c: duplicate CLAUDE.md exits 3" 3 "$RC"
	# Duplicates flow through the SAME collisions pipeline as agent/skill name clashes,
	# so the banner and shape are uniform rather than bespoke to config.
	assert_grep "case3c: reported via the COLLISIONS banner" 'COLLISIONS' "$ERR"
	assert_grep "case3c: names the config category" 'config "CLAUDE.md"' "$ERR"
	assert_grep "case3c: lists the nested path" 'main-thread/CLAUDE.md' "$ERR"
	# Count, do not match $src: deploy canonicalizes paths (/private/var/... on macOS),
	# so a literal $src comparison would fail for a reason unrelated to the behaviour.
	t_true "case3c: lists BOTH offending paths" test "$(grep -c '/CLAUDE\.md$' "$ERR")" = 2
	assert_absent "case3c: nothing deployed" "$tgt/CLAUDE.md"
}

# ===========================================================================
# Case 3d: the real regression — CLAUDE.md is already DEPLOYED, then the source
# MOVES to a subdirectory. Under the old pinned-path discovery this reported
# "PRUNE (1) config CLAUDE.md" and DELETED the live contract instead of
# re-pointing it. Every other config fixture is a single run against a fresh
# target, so none of them can observe a prune at all.
# ===========================================================================
case_config_source_moved() {
	printf '\n-- Case 3d: deployed config survives a source move --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	printf '# Claude Code Configuration\nv1\n' >"$src/CLAUDE.md"
	mk_agent "$src/a.md" some-agent

	# Phase 1 — deploy with the config at the root.
	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case3d: first deploy exits 0" 0 "$RC"
	assert_symlink_live "case3d: config deployed" "$tgt/CLAUDE.md"

	# Phase 2 — move the SOURCE, redeploy into the SAME target.
	mkdir -p "$src/main-thread"
	mv "$src/CLAUDE.md" "$src/main-thread/CLAUDE.md"
	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case3d: redeploy exits 0" 0 "$RC"
	assert_grep "case3d: nothing pruned after the move" '^PRUNE (0):' "$OUT"
	assert_symlink_live "case3d: contract still deployed" "$tgt/CLAUDE.md"
	assert_content "case3d: content still matches" "$tgt/CLAUDE.md" "$src/main-thread/CLAUDE.md"
	# The link must now resolve to the NEW location, not the old one.
	# Compare the suffix, not $src: deploy stores canonical paths (/private/var/... on
	# macOS) while $src is the raw mktemp path — a full-path compare would fail for a
	# reason unrelated to the behaviour under test.
	case "$(readlink "$tgt/CLAUDE.md")" in
	*/main-thread/CLAUDE.md) ok "case3d: link repointed at the moved source" ;;
	*) no "case3d: link repointed at the moved source (got $(readlink "$tgt/CLAUDE.md"))" ;;
	esac
	# And the report must name the source, so a silent source swap is visible.
	assert_grep "case3d: report names the new source" 'main-thread/CLAUDE.md' "$OUT"
}

# ===========================================================================
case_real_tree() {
	printf '\n-- Case 24: real crucible tree passes both checks --\n'
	real_root=$(cd "$TDIR/../.." && pwd -P) || {
		no "case24: could not resolve the real crucible root"
		return
	}
	# CLAUDE.md is found by MARKER anywhere under the root, not pinned to the root itself
	# (it lives in main-thread/). Anchor the sanity check on a path-independent marker.
	[ -d "$real_root/deploy" ] && [ -n "$(find "$real_root" -name CLAUDE.md -not -path '*/.git/*' -print -quit)" ] || {
		no "case24: sanity check failed — $real_root does not look like the crucible root"
		return
	}
	tgt=$(new_dir)
	run_deploy --source "$real_root" --dry-run --target "$tgt"
	assert_rc "case24: real tree dry-run exits 0 (both checks pass)" 0 "$RC"
	assert_grep "case24: dry-run report present" 'dry-run' "$OUT"
}

# ===========================================================================
# Case 24b: IS_OWN_TREE=1 genuinely ENFORCES DEFAULT_REQUIRED_AGENTS. Case 24
# only asserts rc 0 on a PASSING tree, and every other case runs a foreign fixture with
# an explicit --required-agents override — so a regression that hardcoded IS_OWN_TREE=0
# (silently disabling the default everywhere) would leave every other case green. This
# case copies deploy.sh INTO a fixture tree and runs the COPY directly with no
# --required-agents override, so SCRIPT_DIR/.. IS the fixture root and IS_OWN_TREE=1 is
# reached through the real code path, not simulated.
# ===========================================================================
case_is_own_tree_enforcement() {
	printf '\n-- Case 24b: IS_OWN_TREE=1 enforces DEFAULT_REQUIRED_AGENTS --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mkdir -p "$src/deploy"
	cp "$DEPLOY" "$src/deploy/deploy.sh"
	mk_agent "$src/a.md" decision-arbiter
	mk_agent "$src/b.md" review-arbiter
	mk_agent "$src/c.md" software-architect
	mk_agent "$src/d.md" git-operator
	# docs-writer intentionally omitted; no --required-agents override at all.

	sh "$src/deploy/deploy.sh" --target "$tgt" >"$OUT" 2>"$ERR"
	RC=$?
	assert_rc "case24b: own-tree run enforces the default list, exits 5" 5 "$RC"
	assert_grep "case24b: names the missing docs-writer" 'docs-writer' "$ERR"
}

# ===========================================================================
# Case 25: a realistic skills: block shape (comment/blank/quoted/inline-comment items,
# followed by ANOTHER top-level key that has its own block list) parses correctly.
# No real agent in this framework ever makes skills: the LAST key before "---" — every
# real agent follows it with model:/color:/permissionMode: (often tools: as its own
# list) — so this shape exercises the block-end branch the way production files do.
# ===========================================================================
case_skill_block_shape() {
	printf '\n-- Case 25: realistic skills: block shape --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_skill "$src/sk1" real-skill
	mk_skill "$src/sk2" quoted-skill
	mk_skill "$src/sk3" real-skill-2
	mkdir -p "$src"
	cat >"$src/shape.md" <<'EOF'
---
name: shape-agent
description: Test agent with a realistic skills: block shape
skills:
  # leading comment, then a blank line

  - real-skill
  - "quoted-skill"
  - real-skill-2  # inline trailing comment
tools:
  - Read
  - Grep
model: sonnet
---

# shape-agent
EOF

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case25: realistic skills: block shape exits 0" 0 "$RC"
	assert_symlink_live "case25: shape-agent deployed" "$tgt/agents/shape-agent.md"
	# The tools: list must NOT have been swallowed into the skills: block: "Read"/"Grep"
	# are not skills and must not appear as unresolved references (which would fail this
	# case with exit 4 instead of 0 — assert_rc above already covers it, but the intent
	# is documented here for the next reader).

	# Negative twin: every item in the positive fixture above resolves, so "parsed all
	# items" and "dropped all items after the comment/blank" would BOTH yield rc 0 —
	# that is exactly the gate-defeating direction. Put an UNRESOLVED item after the
	# leading comment + blank line to prove the block genuinely continues past them.
	src2=$(new_dir)
	tgt2=$(new_dir)
	mkdir -p "$src2"
	cat >"$src2/shape-unresolved.md" <<'EOF'
---
name: shape-agent-unresolved
description: Test agent whose skills: block has an unresolved item after a comment+blank
skills:
  # leading comment, then a blank line

  - missing-after-comment
tools:
  - Read
---

# shape-agent-unresolved
EOF
	run_deploy_no_required_check --source "$src2" --target "$tgt2"
	assert_rc "case25: unresolved item after comment/blank is still caught" 4 "$RC"
	assert_grep "case25: names the unresolved post-comment skill" 'missing-after-comment' "$ERR"
}

# ===========================================================================
# Case 26: skills: YAML forms outside the plain supported indented block list either
# still resolve correctly (unindented items, key-side spellings) or fail LOUD rather
# than silently passing (flow style, scalar value). An explicit
# empty value ([], ~, null) is valid YAML "no skills" and must NOT fail (the ruling).
# ===========================================================================
case_skill_ref_yaml_forms() {
	printf '\n-- Case 26: skills: edge YAML forms --\n'

	# Unindented block sequence item: MUST still be recognized as a real reference.
	src1=$(new_dir)
	tgt1=$(new_dir)
	mkdir -p "$src1"
	cat >"$src1/unindented.md" <<'EOF'
---
name: unindented-agent
description: agent with an unindented skills: list
skills:
- bogus-unresolved-skill
---

# unindented-agent
EOF
	run_deploy_no_required_check --source "$src1" --target "$tgt1"
	assert_rc "case26: unindented skills: item is still caught (exit 4)" 4 "$RC"
	assert_grep "case26: names the unresolved unindented skill" 'bogus-unresolved-skill' "$ERR"
	assert_dir_empty "case26: nothing applied for unindented form" "$tgt1"

	# Flow-style "skills: [a, b]" -> unsupported form: must die loudly (exit 1, with a
	# diagnosable message), not silently pass.
	src2=$(new_dir)
	tgt2=$(new_dir)
	mkdir -p "$src2"
	cat >"$src2/flow.md" <<'EOF'
---
name: flow-agent
description: agent with a flow-style skills: value
skills: [a, b]
---

# flow-agent
EOF
	run_deploy_no_required_check --source "$src2" --target "$tgt2"
	assert_rc "case26: flow-style skills: value exits 1" 1 "$RC"
	assert_grep "case26: flow-style form is diagnosed" 'unsupported skills: form' "$ERR"
	assert_dir_empty "case26: nothing applied for flow-style form" "$tgt2"

	# Scalar "skills: a" -> unsupported form: must die loudly (exit 1, with a diagnosable
	# message), not silently pass.
	src3=$(new_dir)
	tgt3=$(new_dir)
	mkdir -p "$src3"
	cat >"$src3/scalar.md" <<'EOF'
---
name: scalar-agent
description: agent with a scalar skills: value
skills: a
---

# scalar-agent
EOF
	run_deploy_no_required_check --source "$src3" --target "$tgt3"
	assert_rc "case26: scalar skills: value exits 1" 1 "$RC"
	assert_grep "case26: scalar form is diagnosed" 'unsupported skills: form' "$ERR"
	assert_dir_empty "case26: nothing applied for scalar form" "$tgt3"

	# Explicit-empty spellings ([], ~, null) are idiomatic YAML for "no skills" and must
	# deploy cleanly (rc 0), never hard-fail the whole deploy — the ruling.
	src4=$(new_dir)
	tgt4=$(new_dir)
	mkdir -p "$src4"
	cat >"$src4/empty-list.md" <<'EOF'
---
name: empty-list-agent
description: agent with an explicit empty-list skills: value
skills: []
---

# empty-list-agent
EOF
	run_deploy_no_required_check --source "$src4" --target "$tgt4"
	assert_rc "case26: skills: [] exits 0" 0 "$RC"
	assert_symlink_live "case26: skills: [] agent deployed" "$tgt4/agents/empty-list-agent.md"

	src5=$(new_dir)
	tgt5=$(new_dir)
	mkdir -p "$src5"
	cat >"$src5/tilde.md" <<'EOF'
---
name: tilde-agent
description: agent with an explicit skills: ~ value
skills: ~
---

# tilde-agent
EOF
	run_deploy_no_required_check --source "$src5" --target "$tgt5"
	assert_rc "case26: skills: ~ exits 0" 0 "$RC"
	assert_symlink_live "case26: skills: ~ agent deployed" "$tgt5/agents/tilde-agent.md"

	src6=$(new_dir)
	tgt6=$(new_dir)
	mkdir -p "$src6"
	cat >"$src6/null.md" <<'EOF'
---
name: null-agent
description: agent with an explicit skills: null value
skills: null
---

# null-agent
EOF
	run_deploy_no_required_check --source "$src6" --target "$tgt6"
	assert_rc "case26: skills: null exits 0" 0 "$RC"
	assert_symlink_live "case26: skills: null agent deployed" "$tgt6/agents/null-agent.md"

	# Key-side spellings: a raw 7-char prefix compare would miss these and
	# silently emit zero references; an anchored key match must still catch the
	# unresolved item in each.
	src7=$(new_dir)
	tgt7=$(new_dir)
	mkdir -p "$src7"
	cat >"$src7/space-before-colon.md" <<'EOF'
---
name: space-key-agent
description: agent whose skills key has a space before the colon
skills :
  - bogus-space-key-skill
---

# space-key-agent
EOF
	run_deploy_no_required_check --source "$src7" --target "$tgt7"
	assert_rc "case26: 'skills :' (space before colon) is still caught" 4 "$RC"
	assert_grep "case26: names the unresolved space-key skill" 'bogus-space-key-skill' "$ERR"

	src8=$(new_dir)
	tgt8=$(new_dir)
	mkdir -p "$src8"
	cat >"$src8/quoted-key.md" <<'EOF'
---
name: quoted-key-agent
description: agent whose skills key is double-quoted
"skills":
  - bogus-quoted-key-skill
---

# quoted-key-agent
EOF
	run_deploy_no_required_check --source "$src8" --target "$tgt8"
	assert_rc "case26: quoted \"skills\": key is still caught" 4 "$RC"
	assert_grep "case26: names the unresolved quoted-key skill" 'bogus-quoted-key-skill' "$ERR"

	# An indented "skills:"-looking line (nested under an unrelated key) is NOT a
	# top-level key and must be correctly ignored, not treated as opening the block.
	src9=$(new_dir)
	tgt9=$(new_dir)
	mkdir -p "$src9"
	cat >"$src9/indented-lookalike.md" <<'EOF'
---
name: indented-lookalike-agent
description: agent with an indented skills:-looking line under an unrelated key
nested:
  skills:
    - not-a-real-reference
---

# indented-lookalike-agent
EOF
	run_deploy_no_required_check --source "$src9" --target "$tgt9"
	assert_rc "case26: indented skills:-looking line is ignored, exits 0" 0 "$RC"
	assert_symlink_live "case26: indented-lookalike agent deployed" "$tgt9/agents/indented-lookalike-agent.md"
}

# ===========================================================================
# Case 27: every violation is reported, not just the first (both checks)
# ===========================================================================
case_multiple_violations() {
	printf '\n-- Case 27: multiple violations are ALL reported --\n'

	# Check 1: two different agents each with an unresolved ref, plus one agent with TWO
	# unresolved refs in the same skills: block.
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent_with_skills "$src/one.md" agent-one missing-one
	mk_agent_with_skills "$src/two.md" agent-two missing-two
	mk_agent_with_skills "$src/three.md" agent-three missing-three-a missing-three-b

	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case27: multiple skill-ref violations exits 4" 4 "$RC"
	assert_grep "case27: names missing-one" 'missing-one' "$ERR"
	assert_grep "case27: names missing-two" 'missing-two' "$ERR"
	assert_grep "case27: names missing-three-a" 'missing-three-a' "$ERR"
	assert_grep "case27: names missing-three-b" 'missing-three-b' "$ERR"

	# Check 2: two required agents missing simultaneously.
	src2=$(new_dir)
	tgt2=$(new_dir)
	mk_agent "$src2/a.md" decision-arbiter
	mk_agent "$src2/b.md" software-architect
	run_deploy --required-agents "$FIXTURE_REQUIRED_AGENTS" --source "$src2" --target "$tgt2"
	assert_rc "case27: multiple missing required agents exits 5" 5 "$RC"
	assert_grep "case27: names missing review-arbiter" 'review-arbiter' "$ERR"
	assert_grep "case27: names missing git-operator" 'git-operator' "$ERR"
}

# ===========================================================================
# Case 28: check precedence — collision(3) -> skill-refs(4) -> required-agents(5)
# ===========================================================================
case_check_precedence() {
	printf '\n-- Case 28: check precedence --\n'

	# Collision AND an unresolved skill ref both present -> collision (3) wins.
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent "$src/one/dup.md" dup-agent
	mk_agent "$src/two/dup.md" dup-agent
	mk_agent_with_skills "$src/ref.md" ref-agent nonexistent-skill
	run_deploy_no_required_check --source "$src" --target "$tgt"
	assert_rc "case28: collision takes precedence over unresolved skill ref" 3 "$RC"

	# Unresolved skill ref AND a missing required agent both present -> skill-ref (4) wins.
	src2=$(new_dir)
	tgt2=$(new_dir)
	mk_agent_with_skills "$src2/ref.md" ref-agent-2 nonexistent-skill-2
	mk_agent "$src2/a.md" decision-arbiter
	run_deploy --required-agents "$FIXTURE_REQUIRED_AGENTS" --source "$src2" --target "$tgt2"
	assert_rc "case28: unresolved skill ref takes precedence over missing required agent" 4 "$RC"
}

# ===========================================================================
# Case 29: --only suppresses out-of-scope checks, with a warning
# ===========================================================================
case_only_scoping() {
	printf '\n-- Case 29: --only suppresses out-of-scope checks --\n'

	# --only agents: skills are out of scope, so Check 1 cannot run -> suppressed,
	# warned, and the (would-be) unresolved skill ref does NOT block the run. The grep
	# targets the CHECK-SPECIFIC wording (not the generic word "skipped", which both
	# warnings share and so cannot tell them apart).
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent_with_skills "$src/ref.md" ref-agent nonexistent-skill
	run_deploy_no_required_check --only agents --source "$src" --target "$tgt"
	assert_rc "case29: --only agents suppresses Check 1, exits 0" 0 "$RC"
	assert_grep "case29: Check 1 suppression is warned" \
		"reference check (Check 1) skipped" "$ERR"

	# --only skills: agents are out of scope, so Check 2 cannot run -> suppressed, warned.
	src2=$(new_dir)
	tgt2=$(new_dir)
	mk_skill "$src2/sk" only-skill
	run_deploy --required-agents "$FIXTURE_REQUIRED_AGENTS" --only skills --source "$src2" --target "$tgt2"
	assert_rc "case29: --only skills suppresses Check 2, exits 0" 0 "$RC"
	assert_grep "case29: Check 2 suppression is warned" \
		"required-agents check (Check 2) skipped" "$ERR"
}

# ===========================================================================
# Case 29b: --no-verify-skill-refs explicitly disables Check 1 —
# the documented escape hatch itself had zero coverage.
# ===========================================================================
case_no_verify_skill_refs_flag() {
	printf '\n-- Case 29b: --no-verify-skill-refs disables Check 1 --\n'
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent_with_skills "$src/ref.md" ref-agent nonexistent-skill

	run_deploy_no_required_check --no-verify-skill-refs --source "$src" --target "$tgt"
	assert_rc "case29b: --no-verify-skill-refs disables Check 1, exits 0" 0 "$RC"
	assert_symlink_live "case29b: agent with unresolved ref still deployed" \
		"$tgt/agents/ref-agent.md"
	t_false "case29b: no UNRESOLVED SKILL REFERENCES report on stderr" \
		grep -q 'UNRESOLVED SKILL REFERENCES' "$ERR"
}

# ===========================================================================
# Case 30: both checks are enforced under --dry-run (not gated behind APPLY). Note:
# this case deliberately does NOT assert "$tgt/agents" is absent — under --dry-run
# deploy.sh never mkdirs ANYTHING regardless of whether a check fired (case 7 already
# owns that general "dry-run writes nothing" claim), so such an assertion here cannot
# ever fail and would prove nothing about the checks specifically. What this case must
# prove is that the checks' non-zero exit codes and diagnostics still fire under
# --dry-run — i.e. they are not accidentally gated behind APPLY==1.
# ===========================================================================
case_checks_dry_run() {
	printf '\n-- Case 30: both checks enforced under --dry-run --\n'

	# Check 1 under --dry-run.
	src=$(new_dir)
	tgt=$(new_dir)
	mk_agent_with_skills "$src/ref.md" ref-agent nonexistent-skill
	run_deploy_no_required_check --dry-run --source "$src" --target "$tgt"
	assert_rc "case30: dry-run unresolved skill ref still exits 4" 4 "$RC"
	assert_grep "case30: dry-run names the unresolved skill" 'nonexistent-skill' "$ERR"

	# Check 2 under --dry-run.
	src2=$(new_dir)
	tgt2=$(new_dir)
	mk_agent "$src2/a.md" decision-arbiter
	run_deploy --required-agents "$FIXTURE_REQUIRED_AGENTS" --dry-run --source "$src2" --target "$tgt2"
	assert_rc "case30: dry-run missing required agent still exits 5" 5 "$RC"
	assert_grep "case30: dry-run names the missing agent" 'docs-writer' "$ERR"
}

# ===========================================================================
# Runner
# ===========================================================================

main() {
	case_depths
	case_name_from_frontmatter
	case_root_config
	case_nested_config
	case_duplicate_config
	case_config_source_moved
	case_ignored
	case_collision
	case_idempotent
	case_dry_run
	case_copy_agents
	case_prune
	case_diverged
	case_bundled_scripts
	case_only
	case_usage
	case_relink
	case_unsafe_name
	case_prune_traversal
	case_foreign_protected
	case_crlf
	case_empty_args
	case_target_inside_source
	case_skill_ref_check
	case_required_agents_check
	case_checks_happy_path
	case_real_tree
	case_is_own_tree_enforcement
	case_skill_block_shape
	case_skill_ref_yaml_forms
	case_multiple_violations
	case_check_precedence
	case_only_scoping
	case_no_verify_skill_refs_flag
	case_checks_dry_run

	printf '\n===============================\n'
	printf 'Total: %s  PASS: %s  FAIL: %s\n' "$RUN" "$PASSED" "$FAILED"
	printf '===============================\n'

	[ "$FAILED" -eq 0 ]
}

main "$@"
