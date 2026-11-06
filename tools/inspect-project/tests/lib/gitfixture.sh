# shellcheck shell=sh
#
# gitfixture.sh — real git repositories, built on the HARNESS side (real PATH,
#                 real git), for the tests that verify inspect-project's index
#                 save/restore dance.
#
# WHY REAL GIT AND NOT A STUB. The dance under test is `status --porcelain -z
# --no-renames --untracked-files=all` -> `add -A -- <pathspec>` -> `reset -q --
# <pathspec>` -> `add -A -- <path>` per snapshot line. What makes it correct or
# broken is git's own semantics: which pathspec base an `add` resolves against,
# whether `reset` returns an untracked file to untracked, whether a staged
# deletion re-stages as a deletion. A stub would encode this author's belief about
# those semantics and then verify that belief instead of the tool.
#
# CONFIG ISOLATION. Every fixture command pins identity inline and neutralizes the
# developer's global/system gitconfig, so a machine-level `status.renames`,
# `commit.gpgsign` or `core.hooksPath` cannot change what these tests observe. The
# script under test gets the same isolation for free: it runs under `env -i` with
# an empty HOME, so it finds no global config either.
#
# Sourced by the test suites — never executed directly.

# git_fix DIR ARGS... — git in DIR with a pinned identity and no inherited config.
#
# `--literal-pathspecs` for the same reason git_status_of carries it: this is the
# FIXTURE BUILDER's git, never the git under test. Every path it is handed is an
# exact name the test just created, so a `:leading-colon.txt` read as pathspec
# magic would fail the SETUP rather than reveal anything about the tool. The
# pathspec semantics the tests are about are lib/gitscope.sh's, asserted from the
# recorded argv and from the porcelain status.
git_fix() {
	gf_dir=$1
	shift
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
		git -C "$gf_dir" --literal-pathspecs \
		-c user.name=inspect-tests \
		-c user.email=inspect-tests@example.invalid \
		-c commit.gpgsign=false \
		"$@"
}

# git_init_repo DIR — an initialized repository with one commit, because
# `--scope changed-only` refuses an unborn HEAD and every fixture needs something
# to diff against.
git_init_repo() {
	gir_dir=$1
	mkdir -p "$gir_dir"
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
		git -C "$gir_dir" init -q -b main
	printf 'baseline\n' >"$gir_dir/BASELINE.md"
	git_fix "$gir_dir" add -A
	git_fix "$gir_dir" commit -q -m 'baseline'
}

# git_status_snapshot DIR -> the porcelain status a user would see, with every
# untracked file spelled out.
#
# `-uall` rather than the default: the default collapses an untracked directory to
# a single `dir/` entry, which would hide exactly the per-file difference a
# botched restore produces.
git_status_snapshot() {
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
		git -C "$1" status --porcelain -uall
}

# GIT_SEEDED_CHANGE_COUNT — how many paths git reports as changed per
# git_seed_mixed_changes call. Named rather than spelled as a literal at each
# assertion, so adding a change kind to the fixture cannot leave a stale count
# behind in a suite that reads it.
GIT_SEEDED_CHANGE_COUNT=7

# git_seed_mixed_changes DIR PREFIX — the SIX change kinds `--scope changed-only`
# has to survive, all under DIR/PREFIX (PREFIX empty for the repository root).
# All six together, because restoring any one of them correctly while mangling
# another is exactly the failure a single-change fixture cannot see:
#
#   tracked.rs             an UNSTAGED modification to a tracked file
#   staged.rs              a STAGED new file
#   untracked.rs           an UNTRACKED new file
#   staged with space.rs   a STAGED new file whose path contains a SPACE. This is
#                          what `git status --porcelain`'s `-z` earns its place
#                          for: verified, the non-`-z` form C-QUOTES this path as
#                          `"staged with space.rs"`, which matches nothing Sonar
#                          or the filesystem reports — a silent drop from the
#                          changed-file list, i.e. a FALSE CLEAN.
#   newdir/nested.rs       TWO untracked files inside a NEWLY-CREATED untracked
#   newdir/deeper/also.rs  directory, which is what `--untracked-files=all` earns
#                          ITS place for: the default collapses the whole
#                          directory to ONE `newdir/` entry and never names either
#                          file. Two rather than one deliberately — with a single
#                          nested file the collapsed form is also one entry, so the
#                          changed-file COUNT cannot tell the two modes apart and
#                          dropping the flag stays invisible. Established by
#                          mutation, not by reading the flag's documentation.
#   doomed.rs              a STAGED DELETION of a committed path — the case the
#                          restore's `add -A -- PATH` exists for, since it has to
#                          come back as a staged deletion rather than as an
#                          unstaged one.
git_seed_mixed_changes() {
	gsmc_dir=$1
	gsmc_prefix=$2
	[ -z "$gsmc_prefix" ] || mkdir -p "$gsmc_dir/$gsmc_prefix"
	# The baseline commits are PARTIAL commits of exactly the named paths. A plain
	# `add -A` + `commit` would sweep up the pending changes an earlier call to
	# this function had already seeded elsewhere in the repository, silently
	# emptying the very diff a monorepo fixture is built to have.
	printf 'committed\n' >"$gsmc_dir/${gsmc_prefix}tracked.rs"
	printf 'doomed\n' >"$gsmc_dir/${gsmc_prefix}doomed.rs"
	git_fix "$gsmc_dir" add -- "${gsmc_prefix}tracked.rs" "${gsmc_prefix}doomed.rs"
	git_fix "$gsmc_dir" commit -q -m "seed ${gsmc_prefix}" -- \
		"${gsmc_prefix}tracked.rs" "${gsmc_prefix}doomed.rs"

	printf 'modified\n' >>"$gsmc_dir/${gsmc_prefix}tracked.rs"
	printf 'staged\n' >"$gsmc_dir/${gsmc_prefix}staged.rs"
	printf 'staged\n' >"$gsmc_dir/${gsmc_prefix}staged with space.rs"
	git_fix "$gsmc_dir" add -- "${gsmc_prefix}staged.rs" "${gsmc_prefix}staged with space.rs"
	# `git rm` (not `rm --cached`) so the path leaves the index AND the worktree in
	# one step, which is what makes it a plain `D ` staged deletion rather than a
	# staged deletion plus a fresh untracked file of the same name.
	git_fix "$gsmc_dir" rm -q -- "${gsmc_prefix}doomed.rs"
	printf 'untracked\n' >"$gsmc_dir/${gsmc_prefix}untracked.rs"
	mkdir -p "$gsmc_dir/${gsmc_prefix}newdir/deeper"
	printf 'nested\n' >"$gsmc_dir/${gsmc_prefix}newdir/nested.rs"
	printf 'nested\n' >"$gsmc_dir/${gsmc_prefix}newdir/deeper/also.rs"
}

# git_seed_glob_metachar_names DIR — the same three change kinds again, but every
# path is an ORDINARY filename that git's default pathspec parser reads as a
# PATTERN rather than as a name. Each pair below is deliberate: a hostile path
# plus a DECOY the pattern would match instead, so the failure is a WRONG file
# being staged and not merely a missing one.
#
#   app/[slug]/page.tsx   a real Next.js/Nuxt dynamic-route directory. Verified
#                         against git 2.50: `git add -A -- 'app/[slug]/page.tsx'`
#                         without --literal-pathspecs stages the decoy
#                         `app/s/page.tsx` TOO, because `[slug]` is a one-of-four
#                         character class.
#   weird?name*.ts        `?` and `*` are wildmatch. Verified: the decoy
#                         `weirdXnameY.ts` is staged alongside it.
#   :leading-colon.txt    a LEADING COLON is pathspec MAGIC, not a character.
#                         Verified: `git add -A -- ':leading-colon.txt'` fails
#                         outright with "did not match any files", so the restore
#                         cannot re-stage it at all.
#
# The fixture's own staging uses --literal-pathspecs for exactly the reason under
# test: naming these files to git is impossible without it.
git_seed_glob_metachar_names() {
	gsgmn_dir=$1
	mkdir -p "$gsgmn_dir/app/[slug]" "$gsgmn_dir/app/s"

	# Staged new files — these are what the restore's snapshot has to re-stage.
	printf 'route\n' >"$gsgmn_dir/app/[slug]/page.tsx"
	printf 'ts\n' >"$gsgmn_dir/weird?name*.ts"
	printf 'colon\n' >"$gsgmn_dir/:leading-colon.txt"
	git_fix "$gsgmn_dir" add -- \
		'app/[slug]/page.tsx' 'weird?name*.ts' ':leading-colon.txt'

	# The decoys each hostile pattern would match instead, left UNTRACKED so a
	# wildmatched `add` promoting one to staged is visible in the porcelain status.
	printf 'decoy\n' >"$gsgmn_dir/app/s/page.tsx"
	printf 'decoy\n' >"$gsgmn_dir/weirdXnameY.ts"
}

# git_plant_hostile_exec_config DIR HOOKS_DIR MARKER_DIR — attach code to git's
# two CONFIG-DRIVEN EXEC POINTS in DIR's own `.git/config`, each writing a
# detectable marker file into MARKER_DIR.
#
# WHAT THIS REPRODUCES. `.git/config` is not part of a repository's tracked
# content, so nobody reviews it by reading the code, and a `.git` directory can
# arrive with a downloaded tarball or as a nested/vendored foreign checkout.
# `core.hooksPath` relocates the hook directory (from which `post-index-change`
# runs on an index write) and `core.fsmonitor` names a command git runs to
# enumerate changes — so both fire out of a repository's own config, as the
# invoking user, from an ordinary `git status`. Verified against git 2.50: each
# marker below is created by a plain `git status --porcelain` alone, before any
# `add` or `reset`.
#
# BOTH MARKERS LAND OUTSIDE THE REPOSITORY, deliberately: a marker written inside
# it would itself become an untracked change and move the porcelain status the
# surrounding tests compare byte-for-byte.
#
# The fsmonitor command answers `/` + NUL, which is the "assume everything is
# dirty" reply git accepts from the hook protocol — enough for git to accept it as
# a working fsmonitor rather than erroring out, which is what keeps the marker's
# absence in a hardened run attributable to the hardening and not to a broken hook.
git_plant_hostile_exec_config() {
	gphec_dir=$1
	gphec_hooks=$2
	gphec_markers=$3
	mkdir -p "$gphec_hooks" "$gphec_markers"

	cat >"$gphec_hooks/post-index-change" <<HOSTILE_HOOK
#!/usr/bin/env sh
: >"$gphec_markers/hook-fired"
exit 0
HOSTILE_HOOK
	cat >"$gphec_hooks/fsmonitor" <<HOSTILE_FSMONITOR
#!/usr/bin/env sh
: >"$gphec_markers/fsmonitor-fired"
printf '/\0'
HOSTILE_FSMONITOR
	chmod +x "$gphec_hooks/post-index-change" "$gphec_hooks/fsmonitor"

	git_fix "$gphec_dir" config core.hooksPath "$gphec_hooks"
	git_fix "$gphec_dir" config core.fsmonitor "$gphec_hooks/fsmonitor"
}

# git_hostile_markers_present MARKER_DIR -> `fired` when either marker planted by
# git_plant_hostile_exec_config exists, `silent` when neither does. A single
# comparable word, so the positive control and the negative control are asserted
# with the same `equals` against opposite expectations instead of with two
# differently-shaped assertions a reader has to line up by hand.
git_hostile_markers_present() {
	if [ -e "$1/hook-fired" ] || [ -e "$1/fsmonitor-fired" ]; then
		printf 'fired'
	else
		printf 'silent'
	fi
}

# git_run_unhardened DIR ARGS... — git in DIR WITHOUT lib/gitscope.sh's
# git_hardened options, i.e. with the repository's own `core.hooksPath` and
# `core.fsmonitor` left in force.
#
# THIS IS THE NEGATIVE CONTROL, and the test that uses it is worthless without one:
# a "no marker was created" assertion passes just as well against an INERT fixture
# that could never have created one, so the fixture has to be shown firing first.
# Deliberately NOT git_fix — that helper carries `--literal-pathspecs` only, but a
# future edit adding hardening there would silently disarm this control.
git_run_unhardened() {
	gruh_dir=$1
	shift
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
		git -C "$gruh_dir" "$@"
}

# git_recorded_call TOKEN LOG -> the full argv of the FIRST recorded git call that
# contains TOKEN as an exact token, joined by single spaces.
#
# Exists so a test can assert the EXACT command, pathspec included. "the index was
# unchanged afterwards" cannot distinguish a whole-repository `add -A` that was
# perfectly undone from a correctly scoped one — and that distinction IS the
# monorepo fix (see lib/gitscope.sh's stage_all_changes).
git_recorded_call() {
	awk -v want="$1" '
		/^GIT_CALL_BEGIN$/ { n = 0; hit = 0; split("", a); next }
		/^GIT_CALL_END$/ {
			if (hit) {
				s = ""
				for (i = 1; i <= n; i++) s = s (i > 1 ? " " : "") a[i]
				print s
				exit
			}
			next
		}
		{ a[++n] = $0; if ($0 == want) hit = 1 }
	' "$2"
}

# git_status_of DIR PATH -> the two porcelain status columns for one path, or the
# empty string when git reports nothing for it.
#
# Exists so a test can name the ONE path whose state it is claiming something
# about ("the file outside the inspected subtree is still untracked") instead of
# leaving that claim implicit inside a whole-repository byte comparison.
#
# `--literal-pathspecs` because PATH here is an OBSERVATION target, never the
# thing under test: this helper's whole job is to name one exact file, and a
# `weird?name*.ts` read as a pattern would report a decoy's status as that file's.
# The pathspec semantics the tests are actually about are lib/gitscope.sh's, and
# they are asserted from the recorded argv (git_recorded_call), not from here.
git_status_of() {
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
		git -C "$1" --literal-pathspecs status --porcelain -uall -- "$2" \
		| sed -n '1s/^\(..\).*/\1/p'
}
