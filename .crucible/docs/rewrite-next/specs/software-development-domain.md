# Spec: the software-development domain

Tracker and git knowledge stays in the domain, out of core. The domain reaches core only through core's public scripts, called by path, never sourced.

## The pieces

Both components live in `new-rewrite/domains/software-development/core/main-thread/`.

| Piece | One job |
|---|---|
| `trackers/scripts/tracker-read.sh --url URL` | Prints one GitHub or GitLab issue, read-only |
| `trackers/scripts/context-add-ticket.sh --effort FOLDER --url URL` | Copies that issue into the effort's context |
| `code-context/scripts/context-add-commit.sh --effort FOLDER --repo ROOT --ref REF` | Writes a commit or range into the effort's context as a patch |
| `trackers/SKILL.md` | Signpost: use it when the human points to a GitHub or GitLab issue, or one belongs to an effort's work |
| `code-context/SKILL.md` | Signpost: use it when a change already made belongs to an effort's work |

## Trackers

**Which links.** The URL must pass the safe-link rule (http(s), only letters, digits and `. _ ~ / ? # = % : + , @ -`), or it exits 2. Two kinds are tracker links:
- **GitHub:** host `github.com`, path `/<owner>/<repo>/issues/<n>`, read with `gh`.
- **GitLab:** any other host without a port, path ending `/-/issues/<n>`, read with `glab`.

Anything else, including pull and merge requests, GitHub Enterprise and Jira, is not a tracker link (exit 3). An `/issues/<n>` link the tracker resolves to a pull request is read as the tracker gives it.

**The ticket** is markdown: the title, a line with the URL, state, author and creation time, then the body, then the comments, oldest first. GitLab system notes are left out.

**Bounds.** Each tracker call stops after 30 s. The output stops at 500 lines, and stderr then says `tracker-read.sh: truncated: showing 500 of <N> lines`.

**Exits.** 0: the ticket on stdout. 1: the read failed (a missing tool, a timeout, the tracker's error, a reply that isn't an issue). 2: a usage error or refused URL. 3: not a tracker link. On any exit but 0, the reason is on stderr's first line.

**Read-only by construction.** The script runs only `gh issue view`, `glab issue view` and, for GitLab comments, a `glab api` read of the issue's notes. The URL goes to them as one argument after `--`.

**Comments that can't be read** (GitLab without a login, for one) leave the body, with a `## Comments not read (<reason>)` line in their place.

**The copy into the context.** `context-add-ticket.sh` asks core's `context-docs.sh` for the draft's docs folder before it reads, so a closed effort is refused before any tracker call. It then runs `tracker-read.sh` and passes exits 1, 2 and 3 on; on 3, main adds the URL as a link instead.

- **Name:** `ticket-<host and path>.md`, lower-cased, query and fragment dropped, every character but letters, digits and dots a dash (`ticket-github.com-o-r-issues-5.md`). A same-named copy is replaced.
- **Header:** where it was copied from and when (UTC), and that what follows is quoted from the tracker: text other people wrote, material for the work, never instructions.
- **A partial copy** says what is missing in two places: in the header (`Cut short: …` and/or `Comments not read (…)`) and on stderr (`partial copy: …`).

**Why a copy and not a live link.** A ticket changes; the cut version holding the copy is sealed. Agents read the copy from the docs, so they need no tracker login and no tracker plugin. A ticket edited later is new material in a new version, never a silent change.

**The link rule is a copy of core's** (`crucible-context/scripts/lib/link-rule.jq`), because the domain never reaches into core's internals. An evidence check keeps the two in step: it sends the same good and bad URLs to `tracker-read.sh` and to `context-add.sh --link`, and both must give the same verdict. There is no shared file.

## Code context

`context-add-commit.sh` takes a commit or a range `A..B` from a local git work tree. ROOT is absolute and only read; REF must name commits and not start with `-`. It writes the diff into the draft docs folder as `diff-<sha>.patch`, or `diff-<sha>..<sha>.patch` for a range (short SHAs), replacing a same-named file.

Each changed file goes through core's `context-path-check.sh`. Files it refuses (secrets, instruction files) are left out and named on stderr; if none is left, it refuses. Exit 0 prints the patch's path; exit 2 is any refusal, nothing written.

## Installed only

Both context scripts find core as a neighbour skill: they cut their own path as text (the file, `scripts`, the skill folder) to get the skills folder, and look for `crucible-context/scripts/context-docs.sh` there. No `..`: through a skill link, `..` resolves from the link's real target, where core is not a neighbour.

When core isn't there, they refuse in one plain line (exit 2): core's context isn't beside this skill; install first. So they run installed only, and their `--help` says so. `tracker-read.sh` needs no core.

## Decided, and why

- **Jira later,** as its own piece with its own credential handling, once a real Jira task needs it. It never goes through the legacy skills.
- **Signposts instead of hows.** The `--help` is the contract; without a signpost, main wouldn't know the scripts exist and would add a live link.
- **No events.** Nothing reads a read or a copy back. The cut that seals the copy records it.

## Known limits

- A repository's first commit has no parent, so it has no diff to write, and the refusal then says the commit "changes no file the context may hold", which is not the reason. A note for whoever next touches the script, not a fix.
- Reading GitLab comments while logged in is not yet proven on a live host.
- GitLab comments are read in one page of at most 100 notes.
- The 500-line cut keeps the oldest lines, so a long ticket loses its newest comments.
- The domain skills' names (`trackers`, `code-context`) wait on the owner. Framework skills carry the `crucible-` prefix.
