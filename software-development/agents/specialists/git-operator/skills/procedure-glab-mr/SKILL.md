---
name: procedure-glab-mr
description: The procedure the git-operator runs to find, open, and edit GitLab merge requests without ever hand-authoring shell. It wraps three highly-portable, deterministic scripts — scripts/find-mr.sh (READ-ONLY: is there already an open MR for this source branch?), scripts/create-mr.sh (OUTWARD WRITE: opens an MR, description ALWAYS handed over as a FILE, and refuses to create a duplicate — it runs the same open-MR check first and fails rather than opening a second MR for the same source branch, and it additionally requires --repo-dir, the target project's LOCAL checkout, because glab mr create has no --hostname/host-selection flag at all and resolves the GitLab host purely from the invoking directory's git remotes — a constraint find-mr.sh and update-mr.sh do not share), and scripts/update-mr.sh (OUTWARD WRITE: edits title/description/target-branch/labels/assignees/reviewers — the description is changed ONLY if --description-file is given, never clobbered otherwise, mirroring update-pr.sh's non-clobber mechanism exactly). Same injection-safety RULE as procedure-gh-pr but a different MECHANISM, because glab has no --description-file flag: the caller still always hands over a FILE, which the script reads into one variable (trailing-newline-preserving sentinel read) and passes as ONE argv token to glab's --description; nothing is ever built in a string/heredoc/$() and no script here ever eval's anything. It also uses a GitLab-appropriate project-path validator that accepts nested subgroups (group/subgroup/project), which GitHub's exactly-one-slash OWNER/REPO validator would wrongly reject. It does NOT define the artifact's craft/content (standard-git-pr, reused as-is for MR bodies) or the GitLab-account confirmation gate (procedure-gitlab-auth — a separate, MANDATORY precondition run by the caller before any of these scripts write).
---

# Procedure: GitLab Merge Requests (`glab` wrapper scripts)

The **one** way the `git-operator` talks to `glab` for MR discovery, creation, and editing. This is a **procedure, not a rubric**: call the right script with the right flags; never hand-author a `glab mr create`/`glab mr update` invocation, and never build an MR description in shell. Sibling to `procedure-gh-pr` — same conventions, same injection-safety rule, same test-harness style; the GitLab-specific divergences are called out explicitly below and nowhere else.

**MR body craft is `standard-git-pr`, unchanged.** There is deliberately no `standard-git-mr`: What / Why / How-to-test / risk / linked issue is tech-agnostic, and a second copy of it would only drift.

## Why this exists (read this before calling anything)

An MR description built via `--description "$(cat <<'EOF' … EOF)"` is the same **command-injection sink** `procedure-gh-pr` exists to eliminate: a description commonly pulls in real repo content (a diff summary, commit messages, linked issue text), and a lone line matching the heredoc's closing delimiter ends it early and executes what follows as shell.

**The rule is identical to `procedure-gh-pr`'s; the mechanism is not, and this is the single most important thing to understand here.** `gh` has `--body-file`, so its scripts pass a *path*. **`glab mr create` / `glab mr update` have NO `--description-file` flag** — only `-d/--description <string>`, and passing literally `-` opens an **interactive editor** (verified against glab 1.112.0's own `--help`). So:

- **The caller-facing contract is unchanged: the description is ALWAYS a file** (`--description-file PATH`). Neither script has a `--description` passthrough. The agent `Write`s the drafted description to a file first, then hands the path over.
- **Inside** the script, that file is read into ONE shell variable and passed as **ONE double-quoted argv token** to glab's `--description`, with the whole command built from POSIX **positional parameters** (`set -- glab mr create … --description "$content"`). This is injection-safe for exactly the reason `create-pr.sh`'s `--title` is safe: the bytes are **never re-interpreted by a shell** — no heredoc, no `eval`, no `sh -c`, no string-concatenated command line — so `$(…)`, backticks, quotes and newlines travel into `execve` as inert data.
- The read uses the **sentinel idiom** — `content=$(cat "$f" && printf x); content=${content%x}` — because a plain `$(cat "$f")` strips **all** trailing newlines, not just one. **The `&&`, not a `;`, is load-bearing**: with `;` the substitution's exit status comes from `printf` regardless of whether `cat` actually succeeded, so a read failure partway through would be invisible under `set -e` and could ship a silently truncated description. With `&&`, a `cat` failure fails the assignment and the script catches it. The description GitLab stores is byte-identical to what the caller drafted, trailing blank lines included.
- **A description of exactly `-` (or an empty one) is a usage error**, not something passed through: `-d -` would open glab's editor and hang a non-interactive caller.

**The MR title is not subject to the file rule** — it travels as a single argv token (`--title "$OPT_TITLE"`), safe for the same reason, and the same way `create-pr.sh`'s title already works.

**Accepted limitation, stated plainly: argv is INJECTION-safe here, but it is not DISCLOSURE-safe.** `gh`'s `--body-file` keeps the description's bytes out of the process's argv entirely; this mechanism, by necessity (`glab` has no such flag), puts the full description on the command line — readable by any other process on the same machine at the same privilege boundary (`/proc/<pid>/cmdline` on Linux, `ps -ww` for the same user on macOS) for as long as the process runs. On a single-user development machine this is no different from any other short-lived local command; on a shared/multi-tenant host it is a real, if narrow, exposure window. **Never put a credential, token, or other secret in an MR description** — this was already true, but it is now enforced by locality rather than by the argv boundary alone.

## Host pinning: `--confirmed-host` is REQUIRED on `find-mr.sh` and `update-mr.sh`

`procedure-gitlab-auth`'s gate confirms an **(account, HOST)** pair with the user before any write — but that confirmation used to bind to **nothing** in the scripts that have no local checkout to anchor them. `glab` resolved its target **instance** from ambient state (the cwd's git remotes, an inherited `$GITLAB_HOST`, glab's own config, its `gitlab.com` default). On a machine with **two GitLab instances configured** — exactly the case `procedure-gitlab-auth` exists to disambiguate — the gate could confirm host A while the actual query or edit silently landed on **host B**, whenever the same `--repo` project path resolves on both. A live tracker write is unretractable, and there was no error to notice.

So `find-mr.sh` and `update-mr.sh` now take **`--confirmed-host HOST`, and it is REQUIRED** — a usage error (exit `2`) when missing. Required, not optional: an "optional but you really should pass it" middle state leaves exactly the silent-wrong-host path open.

- **What to pass:** the host `procedure-gitlab-auth` already confirmed — literally the `GLAB_HOST=` value `glab-auth-status.sh` emitted. A **bare hostname with an optional `:port` and NO scheme** (`gitlab.com`, `gitlab.example.com`, `gitlab.example.com:8443`). A scheme-qualified value (`https://gitlab.com`) is **rejected**: glab accepts both spellings, so allowing both here would let two different strings name one host.
- **What it does:** the script exports it as **`GITLAB_HOST`** for its own process before invoking `glab`. That is glab's own documented per-invocation instance selector (glab's README: *"you can declare one for the current command with the `GITLAB_HOST` environment variable"*; `glab auth status --help`: the instance is *"determined by your current context (`git remote`, `GITLAB_HOST` environment variable, or configuration)"*). It is **not** forwarded as a glab flag — glab has no such flag. Nothing outside the script's own process is touched.
- **It fails closed either way:** pinning removes ambient config and glab's default from the decision, and when the cwd happens to be a checkout of a *different* instance glab refuses outright (*"none of the git remotes … correspond to the `GITLAB_HOST` environment variable"*) instead of acting on the wrong server.
- **This flag does NOT re-run the account gate.** It receives the ALREADY-confirmed host as a plain string and enforces that the operation targets it. Running the gate stays the caller's job, upstream (see "The gates the CALLER must clear").

**`create-mr.sh` deliberately has NO `--confirmed-host`, and must not gain one.** Its required `--repo-dir` already pins the host *deterministically* — to a local git checkout whose remote **is** the host, which glab itself verifies. That is a stronger guarantee than a host string, and adding a second, redundant host input could only introduce a way for the two to disagree.

**One thing a stub cannot settle, stated plainly:** the mechanism is documented, not guessed (both glab sources are quoted above), and the test suite proves `GITLAB_HOST` is what these scripts set. What has **not** been observed live here is the **precedence** when a cwd git remote disagrees with it. glab carries a *"none of the git remotes configured for this repository correspond to the `GITLAB_HOST` environment variable"* error, which suggests a mismatch is refused outright — fail closed, the desired outcome — but confirm it by running one `update-mr.sh` from a checkout of a *different* instance and checking it refuses rather than proceeding.

Example:

```
$HOME/.claude/skills/procedure-glab-mr/scripts/find-mr.sh \
  --repo group/subgroup/project --source-branch feat/export \
  --confirmed-host gitlab.com
```

## The other GitLab divergence: the project-path validator

GitHub slugs are always exactly `OWNER/REPO`, and `procedure-gh-pr`'s `is_valid_repo_slug` hard-rejects a second `/`. **GitLab supports nested groups**, so a real project path can be `group/subgroup/project` or deeper. These scripts therefore use `is_valid_gitlab_project_path`, which allows **one or more** `/`-separated segments (letters, digits, `.`, `_`, `-` per segment) and still rejects an empty segment, a leading/trailing `/`, any `.`/`..` path segment, and anything outside the character allow-list. **A lone segment with no `/` at all is rejected** — a bare project name is never a valid full path. Reusing the GitHub validator here would make every subgroup project unreachable.

## The three scripts (`$HOME/.claude/skills/procedure-glab-mr/scripts/` — all portable & deterministic)

**Invoke each by its deployed absolute path — `$HOME/.claude/skills/procedure-glab-mr/scripts/<name>`.** Never a bare `scripts/<name>` (that resolves against the repo cwd, where the script does not exist), and never `${CLAUDE_SKILL_DIR}/…` from an agent's Bash — that placeholder is substituted only inside a skill's own `SKILL.md` content at invocation, NOT in the shell the calling agent runs, so it will not resolve there. All three are POSIX `sh`, run on any machine (macOS BSD / Bash 3.2 + Linux), `shellcheck`-clean, self-contained (no external library sourcing, and no sourcing of `procedure-gh-pr` either — small helpers like the path validator are duplicated, not shared), and deterministic.

All three also pin glab's own chattiness out of the way (`GLAB_NO_PROMPT`, `GLAB_CHECK_UPDATE`, `GLAB_SHOW_WHATS_NEW`) so stdout stays machine-parseable and **no script can ever block on a prompt**; both write scripts additionally pass glab's `--yes`, which is mandatory, not optional — without it `glab mr create`/`update` asks for confirmation and would hang.

**GitLab's MR number is the `iid`.** Every `PM_MR_NUMBER` emitted here is the per-project `iid` — the `!123` number a human sees, and the tail of the MR's URL — never the globally unique `id` field, which is useless to a caller.

### `find-mr.sh` — READ-ONLY (the only ungated script)

```
$HOME/.claude/skills/procedure-glab-mr/scripts/find-mr.sh \
  --repo PATH --source-branch BRANCH --confirmed-host HOST [-h|--help]
```

- Runs `glab mr list --repo PATH --source-branch BRANCH --output json --jq …` and never writes anything. **No state flag is passed:** `glab mr list` "Defaults to open merge requests" (its own `--help`), unlike `gh pr list`, which needs `--state open` spelled out — and glab offers no explicit "open" flag to be more emphatic with.
- **`--confirmed-host` is required** — see "Host pinning" above.
- **`--source-branch` is GitLab's "head"** (and `--target-branch`, on the write scripts, is its "base"). The caller-facing flags use GitLab's own vocabulary on purpose: a GitLab skill speaking GitHub's would invite mistranslation at every call site.
- Prints `PM_MR_COUNT=<n>` on exit 0 (a clean query — count may legitimately be 0); NOT printed on exit 1, since those paths return before any query result exists. `PM_MR_NUMBER=<iid>` and `PM_MR_URL=<url>` are printed **only when the count is exactly 1** — an ambiguous multi-match or a zero-match never fabricates a number/URL.
- **When the count is 2 or more, every matching `iid`/URL row is listed on stderr.** This is not a corner case on GitLab, which allows several open MRs from **one** source branch to **different** targets (a backport fanning out to release branches), where GitHub permits one open PR per head branch — so the state is reachable in normal use and the caller needs the rows to name an iid explicitly next time, not just a bare count.
- Exit `0` on any clean query — **a count of 0 is success, not failure** · `1` glab/awk absent/unauthenticated/the query itself failed · `2` usage error.

### `create-mr.sh` — OUTWARD WRITE, refuses to duplicate

```
$HOME/.claude/skills/procedure-glab-mr/scripts/create-mr.sh \
  --repo PATH --repo-dir /path/to/local/checkout \
  --source-branch BRANCH --target-branch BRANCH --title "STR" \
  --description-file /path/to/description.md \
  [--draft] [--reviewer LOGIN]... [--label NAME]... [--assignee LOGIN]... [-h|--help]
```

- **`--repo-dir` is required, and `--repo` is not a substitute for it.** `glab mr create` has **no `--hostname` flag and no other host-selection flag at all** (probed directly: `--hostname` → `ERROR: Unknown flag`). It resolves **which GitLab host** to talk to purely from the **git remotes of the directory it is invoked in**, so from an unrelated repo's cwd it fails outright — *"None of the git remotes configured for this repository point to a known GitLab host … Configured remotes: github.com."* — even with a perfectly valid `--repo`. So the caller passes the **local working tree the source branch was pushed from**, and the script runs `glab mr create` from inside it. `--repo-dir` is validated cheaply (exists · is a directory · is a git working tree, else exit `2`); whether its remotes point at the *right* host is left to glab's own check, not duplicated here. **This flag exists only on `create-mr.sh`** — `glab mr list` and `glab mr update` resolve the host from `--repo` alone (verified live), so `find-mr.sh` and `update-mr.sh` have no such dependency and no such flag.
- **`--description-file` is required; there is no `--description` flag.** See "Why this exists" for how the file's bytes reach glab safely, and why a description of exactly `-` is refused.
- **Idempotency pre-check, before anything is created:** runs the exact same `glab mr list --source-branch …` query `find-mr.sh` runs. If an open MR already exists for `--source-branch`, this **fails (exit 1)** naming **every** matching MR's `iid` and URL and pointing at `update-mr.sh` — it never opens a duplicate. All rows, not just the first: GitLab genuinely allows several open MRs from one source branch to different targets, so naming only one would hide MRs the operator has to choose between.
- **No `--confirmed-host`, on purpose** — `--repo-dir` already pins the host deterministically. See "Host pinning" above.
- **`--label` is NOT pre-checked for existence** — an unknown label surfaces as a plain `glab mr create` failure.
- On success, prints `PM_MR_NUMBER=<iid>` and `PM_MR_URL=<url>`. `glab mr create` supports **no `--output json`**, so the URL is located in its printed output **by shape** (`https://…/merge_requests/<digits>`, scanned in both captured streams because glab's decoration is not a documented contract) and the iid is that URL's trailing segment. If no such URL can be found, the script fails (exit 1) and says the MR **may nonetheless exist** — verify with `find-mr.sh` before retrying. **If MORE THAN ONE distinct candidate URL is found** (e.g. a spoofed or coincidentally URL-shaped title alongside the genuine one) the script ALSO fails (exit 1) rather than guessing — neither `PM_MR_NUMBER` nor `PM_MR_URL` is ever emitted on that path.
- Exit `0` created · `1` glab/awk/git absent/unauthenticated/an open MR already exists for `--source-branch`/the pre-check query failed/`glab mr create` failed/no MR URL found/**more than one distinct candidate URL found (ambiguous — never guessed)**/`--repo-dir` became unreachable after validation (glab never ran) · `2` usage error (including a missing `--repo-dir`, or one that is not a git working tree).

### `update-mr.sh` — OUTWARD WRITE — the non-clobber contract

```
$HOME/.claude/skills/procedure-glab-mr/scripts/update-mr.sh \
  --repo PATH --mr N --confirmed-host HOST \
  [--title STR] [--description-file PATH] [--target-branch BRANCH] \
  [--add-label NAME]... [--remove-label NAME]... \
  [--add-assignee LOGIN]... [--remove-assignee LOGIN]... \
  [--add-reviewer LOGIN]... [--remove-reviewer LOGIN]... [-h|--help]
```

- **CRITICAL: the description is changed ONLY if `--description-file` is given** — mirrors `update-pr.sh`'s non-clobber mechanism exactly. When it is omitted, this script passes **nothing** description-related to `glab mr update`; there is no code path here that ever reads an MR's current description, so there is nothing to accidentally overwrite. This is structural (one guard in the argv-building code), not a "fetch and put back" step.
- **`--mr N` is forwarded POSITIONALLY.** `glab mr update` takes `[<id>|<branch>]` as a positional argument and has no `--mr`-style flag; the caller-facing spelling stays a flag for symmetry with `update-pr.sh --pr N`.
- **`--confirmed-host` is required** — see "Host pinning" above. Example:
  ```
  $HOME/.claude/skills/procedure-glab-mr/scripts/update-mr.sh \
    --repo group/subgroup/project --mr 42 --confirmed-host gitlab.com \
    --title "Fix the export encoding" --add-label bug
  ```
- **One more divergence, in the other direction: `--add-assignee`/`--remove-assignee` exist here but NOT on `update-pr.sh`.** `gh pr edit` has no assignee-remove flag at all (only `create-pr.sh` can set assignees, at creation time), while `glab mr update` supports assignee add/remove natively — so this script exposes it rather than dropping a capability `glab` genuinely has. This is a caller-facing surface GitLab's MR editing has and GitHub's PR editing (as wrapped here) does not; it is not a bug in either script.
- **glab's label flags are not symmetric, and the assignee/reviewer flags REPLACE by default** — this script normalizes both so a caller never has to think about it:
  - `--add-label` → glab `--label` · `--remove-label` → glab **`--unlabel`** (glab has no `--add-label`/`--remove-label` pair).
  - `--add-assignee`/`--add-reviewer` → glab `--assignee`/`--reviewer` with a **`+` prefix**; `--remove-*` → the same flags with a **`!` prefix**. Without a prefix glab **replaces the whole set**, so an unprefixed value would silently wipe the other assignees. `!` is used for removal rather than glab's alternative `-` prefix because a value starting with `-` looks like a flag to glab's own argument parser.
- **At least one field flag is required** — a bare `--repo`/`--mr` with nothing to change is a usage error (exit `2`), not a silent no-op.
- **`--add-label` is NOT pre-checked for existence** — glab errors on an unknown one; same posture as `create-mr.sh`.
- Prints `PM_MR_URL=<url>` **if EXACTLY ONE candidate URL is found in glab's output AND its trailing iid matches `--mr`** — same soft "courtesy, not proof of success" contract as `update-pr.sh`: a successful edit that returns no URL, or an ambiguous one (2+ distinct candidates), or one whose iid doesn't match `--mr`, still exits `0` with this key left **empty** (with a `warn` naming which case it was) rather than ever relaying a guessed or mismatched value.
- Exit `0` updated · `1` glab/awk absent/unauthenticated/`glab mr update` itself failed · `2` usage error.

## The gates the CALLER (git-operator) must clear before invoking a WRITE

`create-mr.sh` and `update-mr.sh` write to a live, notifying, hard-to-retract tracker. **`find-mr.sh` is the only read-only, ungated script.** Before calling either write script:

1. **Explicit user creation-consent for THIS write** — per the git-operator's own commit-plan-style gate (see its agent body, and `flow-git-operations`'s Merge-Request Path): drafting/planning is free, writing is not; a relayed "open it"/"update it" is never sufficient on its own.
2. **The `procedure-gitlab-auth` account gate** — run `glab-auth-status.sh`, present the active account, and get the user's confirmation it's the correct login, **before** calling `create-mr.sh` or `update-mr.sh`. This skill does **not** perform that check itself (each script only fails fast if glab is not authenticated *at all*) — the account *confirmation* is a separate, upstream precondition the calling agent owns.
3. **Carry the confirmed HOST into the call** — pass the gate's `GLAB_HOST` value as `--confirmed-host` to `find-mr.sh`/`update-mr.sh` (see "Host pinning"). Clearing gate 2 and then letting glab pick its own instance is the failure this flag exists to close: a confirmation that binds to nothing.

## Constraints (NEVER violate)

- Never pass an MR description as a caller-supplied string, a heredoc, or a `$(...)` — the caller ALWAYS hands over a file via `--description-file`, full stop. Inside the script that file becomes ONE argv token; it must never become part of a command *string*. The title is the one value passed directly (a plain argv token), never the description.
- Never `eval` anything, and never build a `glab` command by string-concatenating untrusted values — arguments are built as POSIX positional parameters (`set -- ...`), the sh equivalent of an array.
- Never drop `--yes` from a write invocation, and never remove the `GLAB_NO_PROMPT` pin — either omission lets glab block on an interactive prompt with no human present.
- Never pass a description of exactly `-` through to glab — it opens an interactive editor and hangs.
- Never let `create-mr.sh` open an MR without first checking for an existing open MR on the same source branch — the pre-check is not optional and cannot be skipped by a flag.
- Never call `create-mr.sh` without `--repo-dir`, and never point it at a directory that is not the target project's local checkout — `glab mr create` has no host flag and reads the GitLab host from that directory's git remotes. Equally, never add a `--repo-dir` to `find-mr.sh`/`update-mr.sh`: they do not need one, and inventing the dependency would make them fail from cwds where they currently work.
- Never let `update-mr.sh` touch the description unless `--description-file` was explicitly given — no code path may read-then-rewrite the current description "to be safe."
- Never call `find-mr.sh` or `update-mr.sh` without `--confirmed-host`, and never pass a host the account gate did not actually confirm — the flag is what binds the gate's answer to the operation. Never make it optional "for convenience", never accept a scheme-qualified value, and never add it to `create-mr.sh` (whose `--repo-dir` pins the host more strongly).
- Never reuse `procedure-gh-pr`'s `is_valid_repo_slug` here — it rejects every GitLab subgroup path.
- Never call `create-mr.sh` or `update-mr.sh` without both gates above already cleared.
- Never assume `glab` is installed or authenticated — every script checks and fails fast, cleanly, before any precondition query or write.
- Never create a real GitLab MR or edit while developing/testing this skill — the test suite is fully stubbed (`tests/run-tests.sh`) and must stay that way; no real `glab`, no network.

---
*Procedure Version: 1.0 — the GitLab-MR discovery/creation/editing wrapper. Bound by the git-operator, which now handles BOTH GitHub PRs and GitLab MRs. The account-confirmation gate is the separate `procedure-gitlab-auth`; artifact craft/content is `standard-git-pr` (reused as-is — there is no `standard-git-mr`). Sibling to `procedure-gh-pr` (same conventions and safety rule; different CLI, so a different description mechanism and a subgroup-aware path validator). Wraps `$HOME/.claude/skills/procedure-glab-mr/scripts/`find-mr.sh, create-mr.sh, update-mr.sh — all portable POSIX, shellcheck-clean, self-contained.*
