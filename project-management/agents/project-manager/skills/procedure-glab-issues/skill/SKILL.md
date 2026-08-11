---
name: procedure-glab-issues
description: The procedure the project-manager runs to create, query, comment on, edit, and close GitLab issues via deterministic `glab` wrapper scripts, never hand-authored shell or string-built bodies (command-injection safety). Requires the project-manager's own creation-consent gate plus `--confirmed-host` from the `procedure-gitlab-auth` gate before any write — this skill does not perform either confirmation itself. It does NOT define artifact craft/content (`standard-backlog-artifacts`). GitLab counterpart to `procedure-gh-issues` — the two do not share gates.
---

# Procedure: GitLab Issues (`glab` wrapper scripts)

The **one** way the `project-manager` talks to `glab` for issue creation, duplicate-checking, epic/child linking, label management, commenting, editing, and closing. This is a **procedure, not a rubric**: call the right script with the right flags; never hand-author a `glab issue create`/`update`/`note`/`close` invocation, and never build an issue/comment body in shell.

Sibling to **`procedure-gh-issues`** — same seven scripts, same flag names on the caller-facing side, same exit-code contract, same test-harness style. The GitLab-specific divergences are called out explicitly below and nowhere else. **Artifact craft is `standard-backlog-artifacts`, unchanged** — there is deliberately no GitLab-specific craft skill, because what makes a good story/epic/bug is tracker-agnostic and a second copy would only drift.

## Why these scripts exist (read this before calling anything)

The artifacts this agent authors are agent-audience-capable and pull in real repo content (file paths, code snippets, existing issue text). A body built via `--description "$(cat <<'EOF' … EOF)"` is a **command-injection sink**: if any line in that body happens to equal the heredoc's closing delimiter, the heredoc ends early and every line after it is executed as shell — not written into the issue. Renaming the delimiter or quoting it does **not** fix this; it is inherent to constructing the body in shell at all.

**The rule is identical to `procedure-gh-issues`'s; the mechanism is not, and this is the single most important thing to understand here.** `gh` has `--body-file`, so its scripts pass a *path*. **`glab issue create` / `glab issue update` have NO `--description-file` flag, and `glab issue note` has no `--message-file` flag** — only `-d/--description <string>` and `-m/--message <string>`, and setting a description to literally `-` opens an **interactive editor** (all verified against glab 1.112.0's own `--help`). So:

- **The caller-facing contract is unchanged: the body is ALWAYS a file** (`--body-file PATH`, or `--comment-file PATH` on `close-issue.sh`). No script has a `--body`/`--description`/`--message` passthrough. The agent `Write`s the drafted content to a file first, then hands the path over.
- **Inside** the script, that file is read into ONE shell variable and passed as **ONE double-quoted argv token**, with the whole command built from POSIX **positional parameters** (`set -- glab issue create … --description "$content"`). This is injection-safe for exactly the reason `--title` is safe: the bytes are **never re-interpreted by a shell** — no heredoc, no `eval`, no `sh -c`, no string-concatenated command line — so `$(…)`, backticks, quotes and newlines travel into `execve` as inert data.
- The read uses the **sentinel idiom** — `content=$(cat "$f" && printf x); content=${content%x}` — because a plain `$(cat "$f")` strips **all** trailing newlines, not just one. **The `&&`, not a `;`, is load-bearing**: with `;` the substitution's exit status comes from `printf` regardless of whether `cat` actually succeeded, so a read failure partway through would be invisible under `set -e` and could ship a silently truncated body. With `&&`, a `cat` failure fails the assignment and the script catches it. What GitLab stores is byte-identical to what the caller drafted, trailing blank lines included.
- **A body of exactly `-` (or an empty one) is a usage error**, not something passed through: `-d -` would open glab's editor and hang a non-interactive caller.

**Accepted limitation, stated plainly: argv is INJECTION-safe here, but it is not DISCLOSURE-safe.** `gh`'s `--body-file` keeps a body's bytes out of the process's argv entirely; this mechanism, by necessity (`glab` has no such flag on these subcommands), puts the full body/comment on the command line — readable by any other process on the same machine at the same privilege boundary (`/proc/<pid>/cmdline` on Linux, `ps -ww` for the same user on macOS) for as long as the process runs. On a single-user development machine this is no different from any other short-lived local command; on a shared/multi-tenant host it is a real, if narrow, exposure window. **Never put a credential, token, or other secret in an issue body or comment** — this was already true, but it is now enforced by locality rather than by the argv boundary alone.

**The `--body-file`-only rule is upheld everywhere it applied on the GitHub side:**

- `create-issue.sh` and `comment.sh` refuse a `--body`/`--description`/`--message` flag entirely (there isn't one).
- `update-issue.sh` emits a description flag **only when the caller explicitly gave `--body-file`** — omitting it emits NO description-related flag at all, so `glab issue update` leaves the existing description untouched. There is no code path that reads the current description to "preserve" it; non-clobber is **structural**, not a preservation step.
- `link-children.sh`, which must *modify* an existing (untrusted) description, reads it **straight to a temp file**, and every inspection and splice runs as **awk on files**. Only the FINAL spliced file enters a shell variable, purely to become that one argv token — because glab offers no file flag. It never appends anything derived from the description it just read; the new checklist lines are built only from `--child` values already validated as plain positive integers.
- `close-issue.sh`'s optional closing comment is posted via a **separate `glab issue note --message` call before the close** — and here that is not just this skill's rule but the only option glab offers: `glab issue close` has no comment flag at all.

## Host pinning: `--confirmed-host` is REQUIRED on ALL SEVEN scripts

`procedure-gitlab-auth`'s gate confirms an **(account, HOST)** pair with the user before any write — but that confirmation used to bind to **nothing** here. `glab` resolved its target **instance** from ambient state (the cwd's git remotes, an inherited `$GITLAB_HOST`, glab's own config, its `gitlab.com` default). On a machine with **two GitLab instances configured** — exactly the case `procedure-gitlab-auth` exists to disambiguate — the gate could confirm host A while the actual write silently landed on **host B**, whenever the same `--repo` project path resolves on both. A live tracker write is unretractable, and there was no error to notice.

So every script here takes **`--confirmed-host HOST`, and it is REQUIRED** — a usage error (exit `2`) when missing. Required, not optional: an "optional but you really should pass it" middle state leaves exactly the silent-wrong-host path open. **Read-only `find-duplicate.sh` is included** on purpose: it writes nothing, but its answer *gates* a write, and a "no duplicate" verdict read off the wrong instance is precisely how a duplicate gets created.

- **What to pass:** the host `procedure-gitlab-auth` already confirmed — literally the `GLAB_HOST=` value `glab-auth-status.sh` emitted. A **bare hostname with an optional `:port` and NO scheme** (`gitlab.com`, `gitlab.example.com`, `gitlab.example.com:8443`). A scheme-qualified value (`https://gitlab.com`) is **rejected**: glab accepts both spellings, so allowing both here would let two different strings name one host.
- **What it does:** the script exports it as **`GITLAB_HOST`** for its own process before invoking `glab`. That is glab's own documented per-invocation instance selector (glab's README: *"you can declare one for the current command with the `GITLAB_HOST` environment variable"*; `glab auth status --help`: the instance is *"determined by your current context (`git remote`, `GITLAB_HOST` environment variable, or configuration)"*). It is **not** forwarded as a glab flag — glab has no such flag. Nothing outside the script's own process is touched.
- **It fails closed either way:** pinning removes ambient config and glab's default from the decision, and when the cwd happens to be a checkout of a *different* instance glab refuses outright (*"none of the git remotes … correspond to the `GITLAB_HOST` environment variable"*) instead of writing to the wrong server.
- **It also keeps multi-step scripts on ONE instance.** `link-children.sh` reads a description, splices it, and writes it back; `ensure-labels.sh` looks a label up and then creates it; `close-issue.sh` posts a note and then closes. A read and a write that resolved to different instances would overwrite one epic with another's content, or create a label that was only "missing" somewhere else.
- **This flag does NOT re-run the account gate.** It receives the ALREADY-confirmed host as a plain string and enforces that the operation targets it. Running the gate stays the caller's job, upstream (see "The gates the CALLER must clear").

Example:

```
$HOME/.claude/skills/procedure-glab-issues/scripts/create-issue.sh \
  --repo group/subgroup/project --title "Export to CSV" \
  --body-file /tmp/story.md --confirmed-host gitlab.com --label type:story
```

## The other GitLab divergences

**1. The project-path validator.** GitHub slugs are always exactly `OWNER/REPO`, and `procedure-gh-issues`'s `is_valid_repo_slug` hard-rejects a second `/`. **GitLab supports nested groups**, so a real project path can be `group/subgroup/project` or deeper. These scripts therefore use `is_valid_gitlab_project_path`, which allows **one or more** `/`-separated segments (letters, digits, `.`, `_`, `-` per segment) and still rejects an empty segment, a leading/trailing `/`, any `.`/`..` path segment, and anything outside the character allow-list. **A lone segment with no `/` at all is rejected** — a bare project name is never a valid full path. Reusing the GitHub validator here would make every subgroup project unreachable.

**2. `--yes` is not universal, and passing it where it doesn't exist is fatal.** All seven scripts pin glab's chattiness out of the way (`GLAB_NO_PROMPT`, `GLAB_CHECK_UPDATE`, `GLAB_SHOW_WHATS_NEW`) so stdout stays machine-parseable and **no script can ever block on a prompt**. But glab's `--yes` exists on **`glab issue create` only** — `issue update`, `issue note`, `issue close`, and `label create` have no such flag, and passing it would make glab reject the whole invocation as an unknown flag. So `create-issue.sh` passes `--yes` (mandatory — without it glab prompts for submission confirmation and would hang) and **no other script does**. For `note`, always passing `--message` is what keeps glab out of its editor.

**3. The label lookup is PAGE-WALKED.** `gh api … --paginate` has no glab equivalent: `glab label list` pages at **30 by default** and offers no all-pages flag. A single bare call would silently miss every label past the first page — making `create-issue.sh` refuse a legitimate create over a "missing" label that exists, and `ensure-labels.sh` try to re-create one. Both scripts therefore walk pages explicitly at `--per-page 100`, stopping when a short page proves the last page was reached (bounded at 50 pages / 5000 labels, with a warning if that bound is ever hit).

**4. GitLab's issue number is the `iid`.** Every `PM_ISSUE_NUMBER` emitted here is the per-project `iid` — the `#123` number a human sees, and the tail of the issue's URL — never the globally unique `id` field, which is useless to a caller.

**5. Two `gh` features have NO GitLab mirror, and are deliberately absent rather than faked:**
- **`gh issue close --reason completed|not_planned`** — `glab issue close` takes only the id positionally plus `-R/--repo`; GitLab exposes no close reason through the CLI. `close-issue.sh` has **no `--reason` flag** and does not simulate one with a label or a note.
- **`gh issue create/edit --project`** — no equivalent is exposed here.

## The seven scripts (`$HOME/.claude/skills/procedure-glab-issues/scripts/` — all portable & deterministic)

**Invoke each by its deployed absolute path — `$HOME/.claude/skills/procedure-glab-issues/scripts/<name>`.** Never a bare `scripts/<name>` (that resolves against the repo cwd, where the script does not exist), and never `${CLAUDE_SKILL_DIR}/…` from an agent's Bash — that placeholder is substituted only inside a skill's own `SKILL.md` content at invocation, NOT in the shell the calling agent runs, so it will not resolve there. All seven are POSIX `sh`, run on any machine (macOS BSD / Bash 3.2 + Linux), `shellcheck`-clean, deterministic, and depend on nothing outside this skill directory — they source only this skill's OWN `lib/` (see below), never `procedure-gh-issues` or `procedure-glab-mr`; small helpers like the path validator are duplicated, not shared.

### The shared library (`lib/`)

All seven scripts **source this skill's own `lib/`**, resolved from the script's own `$0` by shell parameter expansion (never `dirname`/`readlink`/`realpath`/`basename`, none of which may be assumed present):

| File | Holds |
|------|-------|
| `lib/pm-diag.sh` | the `LC_ALL`/`PROG` pins, `warn`/`error`/`need_arg`, `init_tmp_err PREFIX`/`emit_captured_stderr`, and the two generic text helpers `count_lines`/`pm_strip_jq_quotes` |
| `lib/pm-glab-env.sh` | the `GLAB_NO_PROMPT`/`GLAB_CHECK_UPDATE`/`GLAB_SHOW_WHATS_NEW` pins + `pm_pin_gitlab_host HOST` |
| `lib/pm-validate.sh` | pure predicates: `is_positive_int`, `is_valid_gitlab_project_path`, `is_valid_confirmed_host`, `is_valid_hex_color` |
| `lib/pm-glab-preconditions.sh` | `require_glab_cli`, `require_awk REASON`, `require_glab_auth` — three SEPARATE functions, because six commands interleave the awk check BETWEEN the glab-present and glab-authenticated checks, and `close-issue.sh` needs no awk at all |
| `lib/pm-glab-labels.sh` | the page-size constants + `list_all_labels REPO` |
| `lib/pm-glab-url.sh` | the TWO url extractors + `pm_url_iid`/`pm_url_matching_iid` |
| `lib/pm-lists.sh` | `split_csv_list`, `csv_accumulate` (comma-splits), `append_line` (does NOT) |

**`extract_issue_url_candidates` and `extract_note_url_candidates` are deliberately TWO functions, not one with a mode flag.** They differ by exactly one regex anchor — the optional `#note_<id>` suffix — and it is load-bearing in opposite directions: `comment.sh` MUST accept a note anchor, while `create-issue.sh`/`update-issue.sh` MUST reject one. Both take `TEXT REPO HOST` and require the candidate's **authority component to equal the confirmed host whole** — ASCII case folded away (host names are case-insensitive), the port still compared literally — so a same-path/same-iid URL on another server is not a candidate at all. Only the candidate EXTRACTION is shared; the policy for 0/1/2+ candidates stays per-call-site (create exits 1 on ambiguity because its URL is load-bearing; update/comment only empty their courtesy key and warn). `pm_url_matching_iid` is the shared cross-check `comment.sh` and `update-issue.sh` both run on their one surviving candidate.

Each script keeps its own `usage()`, its argument parsing and error strings, and — necessarily — its own `glab` argv builder: a `set --` inside a function rebinds only that function's positional parameters, so building a command's argv cannot be centralized even in principle. The `TMP_ERR` temp file and its traps are NOT per-script any more: `init_tmp_err PREFIX` owns them, and `link-children.sh`, which mktemps three more files, re-arms both of its own traps with the full list after each.

**This is the ONE library, and its scope is exactly this skill.** Nothing here sources `procedure-gh-issues`, even though `pm-diag.sh` and `pm-lists.sh` are near-identical to that skill's copies. The two skills deploy to the hub **independently**, so a cross-skill source would resolve to a path that may simply not be there — and it would fail at *runtime*, invisibly past a green test suite, for anyone who installs one skill without the other. Those helpers are **duplicated on purpose**; when you change one, change both.

### `create-issue.sh` — OUTWARD WRITE

```
$HOME/.claude/skills/procedure-glab-issues/scripts/create-issue.sh \
  --repo PATH --title "STR" --body-file /path/to/body.md \
  --confirmed-host HOST \
  [--label NAME]... [--milestone STR] [--assignee LOGIN]... [-h|--help]
```

- **`--confirmed-host` is required** — see "Host pinning" above.
- **`--body-file` is required; there is no `--body`/`--description` flag.** The path must exist, be readable, be non-empty, and not be the single character `-`, or the script fails with exit `2` before touching `glab` at all.
- **Preconditions checked BEFORE creating anything** — an unknown label or milestone makes `glab issue create` fail after everything else validated, wasting the round-trip with a raw glab error:
  - **Labels:** queried via the page walk described above and matched exactly. Fails with a precise `label(s) not found in project 'X': A, B` naming exactly what's missing — **never auto-creates one**; run `ensure-labels.sh` first, or drop the flag.
  - **Milestone:** queried via `glab milestone list --repo … --title "…"`, which filters **server-side on the exact title**, so this needs no page walk. **Deliberate contract narrowing:** raw glab also accepts a numeric *global milestone id*, which this title-only check would reject — that mirrors the GitHub sibling's `--milestone STR = title` contract, keeps the check exact, and fails **closed** with a clear message. Pass the title.
- **No `--epic` flag is exposed**, even though `glab issue create` has one. Epic linking is `link-children.sh`'s job (see below for why), and a native epic wired at create time could never be re-wired afterwards, because `glab issue update` has no `--epic` flag at all.
- On success, prints `PM_ISSUE_NUMBER=<iid>` and `PM_ISSUE_URL=<url>`. `glab issue create` supports **no `--output json`**, so the URL is located in its printed output **by shape** (`https://…/work_items/<digits>` **or** the classic `https://…/issues/<digits>` — GitLab migrated issue URLs to the work-items path, and both shapes are accepted so an older self-managed instance still works; scanned in both captured streams because glab's decoration is not a documented contract) and the iid is that URL's trailing segment. If no such URL can be found, the script fails (exit 1) and says the issue **may nonetheless exist** — verify with `find-duplicate.sh` before retrying. **If MORE THAN ONE distinct candidate URL is found** (e.g. a spoofed or coincidentally URL-shaped title alongside the genuine one) the script ALSO fails (exit 1) rather than guessing — neither `PM_ISSUE_NUMBER` nor `PM_ISSUE_URL` is ever emitted on that path.
- Exit `0` created · `1` glab/awk absent/unauthenticated/unknown label-or-milestone/a precondition lookup failed/`glab issue create` failed/no issue URL found/**more than one distinct candidate URL found (ambiguous — never guessed)** · `2` usage error.

### `find-duplicate.sh` — READ-ONLY (the only ungated script)

```
$HOME/.claude/skills/procedure-glab-issues/scripts/find-duplicate.sh \
  --repo PATH (--title "STR" | --search "QUERY") --confirmed-host HOST [-h|--help]
```

- **`--confirmed-host` is required even though this script writes nothing** — its verdict gates a write, and a "no duplicate" answer read off the wrong instance is how a duplicate gets created. See "Host pinning" above.
- Runs `glab issue list --repo … --search "<text>" --in title --all --output json --jq '.[].web_url'` and never writes anything — safe to call speculatively before drafting, to steer the "is this really new work" judgment call.
- **The scope lives in FLAGS, not in the query text.** `gh` needs `in:title` inside the search string and `--state all`; glab has `--in title` (its default is `title,description`) and `--all` (it lists only OPEN issues by default, and offers no `--state`). So the caller's text is passed to `--search` **verbatim, with nothing appended**. **Matches issues whose title CONTAINS the given text — a GitLab search is tokenized/fuzzy, never an exact-string match** — so treat a hit as "worth a human look," not proof of an identical title.
- Prints `PM_DUPLICATE_COUNT=<n>` and `PM_DUPLICATE_URLS=<url[,url...]>` on exit 0 (empty `URLS` when count is 0); neither key is printed on exit 1, since those paths return before any query result exists.
- **The count is a FLOOR, not necessarily a total.** This is a single-page query (`--per-page 100`; glab's own default is only 30 and it has no `--paginate`), so a count that lands exactly on the page size may be truncated — the script **warns on stderr** in that case, the same way this skill's label lookups warn on their own page cap. Never treat a warned count as a complete set: narrow the query instead.
- Exit `0` on any clean query — **a count of 0 is success, not failure** · `1` glab/awk absent/unauthenticated/the query itself failed · `2` usage error.

### `link-children.sh` — OUTWARD WRITE (kept thin)

```
$HOME/.claude/skills/procedure-glab-issues/scripts/link-children.sh \
  --repo PATH --epic-issue N --child N [--child N ...] \
  --confirmed-host HOST [-h|--help]
```

- **`--confirmed-host` is required** — and it matters most here: this script READS a description, splices it, and WRITES it back, so a read and a write on different instances would overwrite one epic with another's content. See "Host pinning" above.
- **The parent flag is `--epic-issue`, NOT `--epic`, and that naming is load-bearing.** GitLab's native epics are **group-level** objects and a **paid-tier feature** that may not exist at all on the target account, and **`glab issue update` has no `--epic` flag** — so there is no plain-glab way to link an already-existing child to an already-existing epic. This script therefore treats a **plain issue** as the epic and appends `- [ ] #<child>` lines to its description, exactly the mechanism the GitHub sibling uses; GitLab renders that as a progress checklist and turns each `#N` into a live cross-link. `--epic` would wrongly imply the native feature, so it is rejected as an unknown option.
- **Injection safety:** the epic issue's *existing* description is untrusted repo content, so it is read straight to a temp file (`glab issue view N --repo … --output json --jq '.description // ""'` → file) and every inspection/splice is awk on files. Only the final spliced file becomes one argv token for `--description` (see "Why these scripts exist").
- **Idempotent, regardless of checkbox state, hand-editing, or duplicate arguments:** a child already present — as `- [ ] #N` OR a checked `- [x]`/`- [X] #N`, **with any surrounding whitespace, any indentation, and either LF or CRLF line endings** — is detected and skipped, never re-appended or recounted; a child requested more than once in a single run (e.g. `--child 11 --child 11`) is linked at most once. New lines are inserted right after the heading's own last checklist item (not blindly at end-of-file), so a `## Linked children` heading that isn't the last section never gets orphaned new lines below whatever follows it.
- Prints `PM_LINKED=<n>` — the count of **new** links actually appended this run (0 is a valid, successful no-op when every requested child is already linked; no write is attempted in that case).
- Exit `0` updated (or already fully linked) · `1` glab/awk absent/unauthenticated/the epic issue could not be read/the update itself failed · `2` usage error.

### `ensure-labels.sh` — OUTWARD WRITE, PERSISTENT — extra caution

```
$HOME/.claude/skills/procedure-glab-issues/scripts/ensure-labels.sh \
  --repo PATH --label NAME [--label NAME]... --confirmed-host HOST \
  [--color HEX] [--description STR] [-h|--help]
```

- **`--confirmed-host` is required** — it also keeps the existence LOOKUP and the CREATE on one instance, so a label can never be reported "missing" from host A and then created on host B. See "Host pinning" above.
- **This is THE opt-in "create missing labels" step** — `create-issue.sh`/`update-issue.sh` deliberately never auto-create a label. Run this FIRST, only when the user has explicitly opted in, before a create/update that needs a not-yet-existing label.
- **Creates PERSISTENT, project-wide, visible state** — a label isn't scoped to one issue; it appears in the project's label picker for everyone. Treat this with the same caution as any other outward write, not as a harmless side-step of the label pre-check.
- **Idempotent:** every requested label is checked against the project's actual labels first (via the page walk), and an already-existing one is skipped — never re-created, never an error. A label requested more than once (repeated `--label`, a comma-list, or both) is created at most once.
- **Best-effort, not all-or-nothing:** if one `glab label create` call fails (e.g. a bad `--color`), the labels that succeeded before or after it are still created and reported; the script still exits `1` so the caller knows something needs attention.
- **`--color` accepts 6 hex digits with or without a leading `#`** (glab's own default is written `#428BCA`). glab additionally accepts a plain colour *name*; this wrapper deliberately does not, so the value is unambiguous. The label name goes behind glab's own `--name` flag, so — unlike the GitHub sibling, where it is positional and needs a literal `--` in front — a name beginning with `-` cannot be misparsed here.
- Prints `PM_LABELS_CREATED=<name[,name...]>` and `PM_LABELS_EXISTING=<name[,name...]>` (either may be empty).
- Exit `0` every requested label exists · `1` glab/awk absent/unauthenticated/the lookup failed/at least one create call failed · `2` usage error.

### `comment.sh` — OUTWARD WRITE

```
$HOME/.claude/skills/procedure-glab-issues/scripts/comment.sh \
  --repo PATH --issue N --body-file /path/to/comment.md \
  --confirmed-host HOST [-h|--help]
```

- **`--confirmed-host` is required** — see "Host pinning" above.
- Same injection-safety rule as `create-issue.sh`: **`--body-file` is required; there is no `--body`/`--message` flag.** GitLab's comment is a **note** (`glab issue note`), and the iid is forwarded **positionally** (`glab issue note <issue-id>`); the caller-facing spelling stays `--issue N` for symmetry with the GitHub sibling.
- Prints `PM_COMMENT_URL=<url>` **if EXACTLY ONE candidate note URL is found in glab's output AND its issue-iid segment matches `--issue`** (located by shape, `https://…/{work_items|issues}/<digits>[#note_<digits>]` — both path shapes accepted, see `create-issue.sh` above) — a successful post that returns no URL, or an ambiguous one, or one naming a different issue, still exits `0` with this key left **empty** (with a `warn` naming which case it was); the URL is a courtesy, glab's own exit code is the proof of success.
- Exit `0` posted · `1` glab/awk absent/unauthenticated/`glab issue note` itself failed · `2` usage error.

### `update-issue.sh` — OUTWARD WRITE — the non-clobber contract

```
$HOME/.claude/skills/procedure-glab-issues/scripts/update-issue.sh \
  --repo PATH --issue N --confirmed-host HOST \
  [--title STR] [--body-file PATH] \
  [--add-label NAME]... [--remove-label NAME]... \
  [--add-assignee LOGIN]... [--remove-assignee LOGIN]... \
  [--milestone STR] [-h|--help]
```

- **CRITICAL: the body is changed ONLY if `--body-file` is given.** When it is omitted, this script passes **nothing** description-related to `glab issue update` — no `--description`, no `--body` — so glab leaves the existing description exactly as it was. This is structural (a single guard in the argv-building code), not a "read the old body and put it back" step — there is no code path here that ever reads an issue's current description.
- **`--confirmed-host` is required** — see "Host pinning" above.
- **`--issue N` is forwarded POSITIONALLY.** `glab issue update` takes `<id>` positionally and has no `--issue`-style flag; the caller-facing spelling stays a flag for symmetry with the GitHub sibling.
- **glab's label flags are not symmetric, and the assignee flag REPLACES by default** — this script normalizes both so a caller never has to think about it:
  - `--add-label` → glab `--label` · `--remove-label` → glab **`--unlabel`** (glab has no `--add-label`/`--remove-label` pair).
  - `--add-assignee` → glab `--assignee` with a **`+` prefix**; `--remove-assignee` → the same flag with a **`!` prefix**. Without a prefix glab **replaces the whole set**, so an unprefixed value would silently unassign everyone else. glab's own help documents **both `!` and `-`** for removal; this script uses **`!` only**, because a value starting with `-` looks like a flag to an argument parser, and `!` is inert in a non-interactive shell. Same choice as `procedure-glab-mr`'s `update-mr.sh`.
- **At least one field flag is required** — a bare `--repo`/`--issue` with nothing to change is a usage error (exit `2`), not a silent no-op.
- **`--add-label` is NOT pre-checked for existence** here — glab errors on an unknown one; run `ensure-labels.sh` first if the caller wants it created. `--milestone` is not pre-checked either (unlike at create time); **pass `0` to UNASSIGN** the milestone (glab's documented unassign value, and the only way to unassign through this wrapper, since an empty flag value is rejected as a missing argument).
- Prints `PM_ISSUE_URL=<url>` **if EXACTLY ONE candidate URL is found in glab's output AND its trailing iid matches `--issue`** — a successful edit that returns no URL, or an ambiguous one (2+ distinct candidates), or one naming a different issue, still exits `0` with this key left **empty** (with a `warn` naming which case it was). **This diverges from the GitHub sibling on purpose:** `gh issue edit` documents its URL output and that script treats a missing URL as a hard failure, whereas `glab issue update` supports no `--output json` and its decoration is not a documented contract, so demanding a URL would turn a successful edit into a false failure. Same soft contract as `update-mr.sh`.
- Exit `0` updated · `1` glab/awk absent/unauthenticated/`glab issue update` itself failed · `2` usage error.

### `close-issue.sh` — OUTWARD WRITE

```
$HOME/.claude/skills/procedure-glab-issues/scripts/close-issue.sh \
  --repo PATH --issue N --confirmed-host HOST [--comment-file PATH] [-h|--help]
```

- **`--confirmed-host` is required** — it also keeps the optional closing NOTE and the CLOSE on one instance, so the two halves of this two-step operation can never land on different servers. See "Host pinning" above.
- **There is NO `--reason` flag, and inventing one is forbidden.** `glab issue close` takes the id positionally and has `-R/--repo` as its only other option; GitLab exposes no close reason through the CLI. `gh issue close --reason completed|not_planned` is a **documented GitHub-only feature with no GitLab mirror** — do not simulate it with a label or a note.
- **Mechanism for `--comment-file`:** an optional closing comment is posted via a **separate `glab issue note --message` call BEFORE `glab issue close` runs**. On the GitHub side that was a rule-driven choice; here it is also the only option glab offers. If the comment post fails, the close is **never attempted** — no partial "commented but didn't close" surprise. If the *close* fails after the comment already posted, the script says so explicitly so a retry drops `--comment-file` rather than double-posting.
- No `PM_*` output key on success beyond the exit code — `glab issue close` doesn't return a URL worth relaying, same as the GitHub sibling.
- Exit `0` closed (and the closing comment, if any, was posted first) · `1` glab absent/unauthenticated/the comment post failed/`glab issue close` itself failed · `2` usage error.

## The gates the CALLER (project-manager) must clear before invoking a WRITE

Six of these seven scripts write to a live, notifying, hard-to-retract tracker — everything except `find-duplicate.sh`. **`find-duplicate.sh` is the only read-only, ungated one.** Before calling `create-issue.sh`, `link-children.sh`, `ensure-labels.sh`, `comment.sh`, `update-issue.sh`, or `close-issue.sh`:

1. **Explicit user creation-consent for THIS write** — per the project-manager's own creation gate (see its agent body): drafting is free, writing is not; a relayed "do it" is never sufficient on its own. This applies just as much to a comment, an edit, a close, or a label creation as it does to creating the issue itself.
2. **The `procedure-gitlab-auth` account gate** — run `glab-auth-status.sh`, present the active account **and host** (a user commonly works across gitlab.com plus one or more self-managed instances), and get the user's confirmation it's the correct login, **before** calling any write script. This skill does **not** perform that check itself — each script only fails fast if glab is not authenticated *at all* — it is a separate, upstream precondition the calling agent owns. **This is `procedure-gitlab-auth`, not `procedure-github-auth`**; the two are separate gates for separate CLIs, and glab additionally keeps one credential per instance (there is no `glab auth switch`), so the host matters as much as the login.

3. **Carry the confirmed HOST into every call** — pass the gate's `GLAB_HOST` value as `--confirmed-host` to every script, `find-duplicate.sh` included (see "Host pinning"). Clearing gate 2 and then letting glab pick its own instance is the failure that flag exists to close: a confirmation that binds to nothing.

**`ensure-labels.sh` warrants particular care** — a label is project-wide and persistent (unlike a single issue's field), so its consent should be as explicit as any other outward write, never inferred from "the user wanted the issue created."

## Known live-verification items (two still genuinely open; the rest settled by live testing below)

Stated plainly so nobody mistakes stub-green for field-proven. The whole test suite is stubbed by design (see Constraints); these were the specific contracts a stub could not settle on its own:

**Genuinely open (introduced by the `--confirmed-host` hardening — not yet live-verified):**

1. **Does `GITLAB_HOST` fully pin `glab issue …`'s target instance, including when `--repo` is given from inside an unrelated git checkout?** The MECHANISM is documented, not guessed — glab's own README lists `GITLAB_HOST` as the way to "declare one for the current command", and `glab auth status --help` names it as one of the three host-resolution inputs — and every script now exports it from `--confirmed-host`. What a stub cannot settle is the PRECEDENCE when a cwd git remote disagrees with it: glab carries a "none of the git remotes configured for this repository correspond to the `GITLAB_HOST` environment variable" error, which suggests a mismatch is refused outright (fail closed, the desired outcome), but that has not been observed live here. **Confirm by running one write from a checkout of a DIFFERENT instance and checking it refuses rather than proceeding.**

2. **Does the URL `glab` prints on a SELF-MANAGED instance carry an authority that actually equals the confirmed host?** The extractors accept a candidate only when its authority equals `--confirmed-host` whole (ASCII case folded, port compared literally — see `lib/pm-glab-url.sh`). On gitlab.com that always holds and is live-proven. On a self-managed instance the printed URL comes from the server's own `external_url`, which the client never sees and a stub cannot simulate: if it disagrees with how the caller reaches the instance — classically a port-qualified `--confirmed-host` (`gitlab.example.com:8443`) against an `external_url` that omits the port, or the reverse — then EVERY candidate is rejected, and `create-issue.sh` exits 1 with "printed no issue URL" **for an issue it genuinely created**. The failure is loud and safe (never a wrong URL), but it is a false failure on an unretractable write. **Confirm by running one `create-issue.sh` against each self-managed instance in use and checking it reports a URL rather than the no-URL abort; if it aborts, compare the URL `glab` printed with the host the account gate confirmed — the fix belongs in the extractors' authority compare, never in loosening it to a suffix or substring test.**

**Settled by live testing (kept here as a record, not a live open question):**

3. **~~Does `glab`'s own `--jq` render a STRING result raw or JSON-quoted?~~ — SETTLED.** A real `link-children.sh` run against a real epic issue read its description via `--jq '.description // ""'`, spliced a checklist into it, and wrote it back correctly (verified by re-reading the issue afterward) — a JSON-quoted-with-`\n`-escapes rendering would have written a mangled single-line blob back, which did not happen. `find-duplicate.sh` was independently confirmed against both renderings by its own stub tests, unaffected either way (it reads `web_url` from `--output json`, not a raw string field).
4. **~~Do `glab issue list`'s `--all`, `--search`, and `--in` compose the way `find-duplicate.sh` assumes?~~ — SETTLED.** A real `find-duplicate.sh` run correctly found a match by title across BOTH an open and a since-closed issue in the same query — proving `--all` (state) and `--search`+`--in title` (scope) compose exactly as assumed.
5. **~~The exact printed output shape of `glab issue create` / `update` / `note`~~ — SETTLED.** All three print a `https://…/-/work_items/<iid>` URL (the `note` form with a `#note_<id>` anchor), **not** the classic `/-/issues/<iid>` path: GitLab migrated issue URLs to the work-items path. The original shape match accepted only `/issues/`, which made `create-issue.sh` abort with "reported success but printed no issue URL" on issues it had genuinely created, and left `update-issue.sh`/`comment.sh`'s courtesy URL empty. All three matchers now accept **either** segment — the classic shape is kept, not replaced, for older self-managed instances. `find-duplicate.sh` was never affected: it reads `web_url` from `--output json`, not by shape.

## Constraints (NEVER violate)

- Never pass an issue/comment body as a caller-supplied string, a heredoc, or a `$(...)` — the caller ALWAYS hands over a file via `--body-file`/`--comment-file`, full stop, including for a closing comment. Inside the script that file becomes ONE argv token; it must never become part of a command *string*. The title is the one value passed directly (a plain argv token), never the body.
- Never `eval` anything, and never build a `glab` command by string-concatenating untrusted values — arguments are built as POSIX positional parameters (`set -- ...`), the sh equivalent of an array.
- Never pass a body/description of exactly `-` through to glab — it opens an interactive editor and hangs.
- Never drop `--yes` from `create-issue.sh`, and never ADD it to any other script — `glab issue update`/`note`/`close` and `glab label create` have no such flag and would reject the whole invocation. Never remove the `GLAB_NO_PROMPT` pin from any of them.
- Never auto-create a missing label or milestone from `create-issue.sh`/`update-issue.sh` — report it and stop; `ensure-labels.sh` is the separate, explicit, opt-in step for labels; a missing milestone is never auto-created at all.
- Never let `update-issue.sh` touch the description unless `--body-file` was explicitly given — no code path may read-then-rewrite the current description "to be safe."
- Never replace `link-children.sh`'s task-list mechanism with a native GitLab epic, and never rename `--epic-issue` to `--epic` — native epics are group-level and paid-tier, and `glab issue update` cannot link one at all.
- Never add a `--reason` flag to `close-issue.sh`, and never emulate GitHub's close reasons with a label or a note.
- Never collapse the label lookup back to a single `glab label list` call — it pages at 30 and would misreport real labels as missing.
- Never call any of these scripts without `--confirmed-host`, and never pass a host the account gate did not actually confirm — the flag is what binds the gate's answer to the operation. Never make it optional "for convenience", never accept a scheme-qualified value, and never exempt read-only `find-duplicate.sh` (its verdict gates a write).
- Never reuse `procedure-gh-issues`' `is_valid_repo_slug` here — it rejects every GitLab subgroup path.
- Never call any OUTWARD-WRITE script without both gates above already cleared, and never substitute `procedure-github-auth` for `procedure-gitlab-auth`.
- Never assume `glab` is installed or authenticated — every script checks and fails fast, cleanly, before any precondition query or write.
- Never create a real GitLab issue, label, note, edit, or close while developing/testing this skill — the test suite is fully stubbed (`tests/run-tests.sh`) and must stay that way; no real `glab`, no network.

---
*Procedure Version: 1.1 — the GitLab-issue creation/duplicate-check/linking/labeling/commenting/editing/closing wrapper. Bound by the project-manager, which now handles GitHub Issues, GitLab Issues, and Jira. The account-confirmation gate is the separate `procedure-gitlab-auth`; artifact craft/content is `standard-backlog-artifacts` (reused as-is). Sibling to `procedure-gh-issues` (same conventions and safety rule; different CLI, so a different body mechanism, a subgroup-aware path validator, a paged label lookup, and no --reason/--project/native-epic support). Wraps `$HOME/.claude/skills/procedure-glab-issues/scripts/`create-issue.sh, find-duplicate.sh, link-children.sh, ensure-labels.sh, comment.sh, update-issue.sh, close-issue.sh — all portable POSIX and shellcheck-clean, over this skill's own `lib/`. **1.1 decomposes the seven script monoliths onto that skill-local `lib/`** (`pm-diag`, `pm-glab-env`, `pm-validate`, `pm-glab-preconditions`, `pm-glab-labels`, `pm-glab-url`, `pm-lists`) and moves `SKILL.md`+`scripts/` under `skill/` — behavior-identical, proven by running the ORIGINAL pre-refactor scripts and the refactored ones through the same harness and diffing the full transcripts byte-for-byte, plus new note-anchor and predicate-truth-table coverage — and corrects this file's former "self-contained" claim, which the split made false.*
