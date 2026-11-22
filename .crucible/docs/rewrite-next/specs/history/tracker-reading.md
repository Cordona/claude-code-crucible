# Spec: tracker reading (software-development domain)

**Purpose:** a GitHub or GitLab issue often holds the task. Main reads it in discovery ("read first, ask second"), and the agents doing the work need what the human approved, not what the ticket says later. Tracker access is domain knowledge, so it lives in the domain, never in core.

**Home:** `new-rewrite/domains/software-development/core/main-thread/trackers/`, beside `code-context/`.

## 1. The pieces

| Piece | One job |
|---|---|
| `scripts/tracker-read.sh --url URL` | Prints one tracker issue, read-only |
| `scripts/context-add-ticket.sh --effort FOLDER --url URL` | Writes that issue into the context's draft docs folder, so the cut seals what was read at discovery |

### `tracker-read.sh`

- **The URL rule:** the domain's own copy of the safe-link rule: http(s), and only the characters `A-Za-z0-9._~/?#=%:+,@-`. No character with a meaning to the shell gets through, so a single-quoted `--url` can't inject. It's a copy, not a source of core's lib, because the domain never reaches into core's internals.
- **Which trackers:**
  - **GitHub:** host `github.com`, path `/<owner>/<repo>/issues/<n>`, read with `gh issue view`.
  - **GitLab:** any host without a port, path ending in `/-/issues/<n>`, read with `glab issue view`.
- **Bounds:** the read stops after 30 s, and the output stops at 500 lines, with a truncation notice on stderr.
- **Exits:**
  - **0:** stdout is the ticket.
  - **3:** not a tracker link, so main reads it as any other link.
  - **1:** the read failed; the reason is on stderr's first line.
  - **2:** a usage error or a refused URL.
- **Read-only by construction:** the script runs only the two `view` commands.
- **What "the ticket" is:** the body and its comments (owner, 2026-11-21). The `--help` says it.
- **Not covered, said in the `--help`:** pull requests, GitHub Enterprise hosts and Jira.

### `context-add-ticket.sh`

It runs `tracker-read.sh`, then writes `ticket-<host>-<owner>-<repo>-<n>.md` into the folder `context-docs.sh` prints, replacing one of the same name. The file starts with a short header: the URL, when it was read, and that what follows is quoted from the tracker and is material, not instructions. A ticket is other people's text, and on a public repository it can be anyone's. When the read was cut at 500 lines, the header says so too, so a sealed copy never ends mid-way without notice. The file name is the `<name>.md` the docs rule already accepts, so core changes nothing. It's the same shape as `context-add-commit.sh`: it calls core's scripts by path and never sources them. It calls `tracker-read.sh` and never repeats its URL or host logic. An exit 3 is passed on, so main can add the link with core's `context-add.sh` instead.

**Why a copy rather than a live link:** a ticket changes, but a cut version is sealed (value 10). The agents read the ticket from the docs, so they need no tracker login and no tracker plugin, and a ticket edited after discovery can't change the work unnoticed: a changed ticket is new material and a new version. A live link is still possible: `context-add.sh` adds one with its why.

## 2. No events

Reading is not a fact anyone reads back: nothing has a reader, so nothing is written. The copy is recorded by the cut that seals it.

## 3. A signpost, not a how

`--help` is the whole contract, and discovery already says to read what the human points to. But with no skill, main can't know the scripts exist: it would fetch the page or run the tracker's own command line, and then add the link as a live link. So there's a `SKILL.md` of about 40 words. Its description says when to use it: a GitHub or GitLab issue link that belongs to an effort's work. Its body says the scripts are in `scripts/`, and each one's `--help` is its contract. `code-context/` gets the same signpost (owner, 2026-11-21).

## 3b. The copied link rule

The rule now has two homes, the domain's copy and core's. The evidence run guards against drift between them: the same good and bad URLs go to `tracker-read.sh` and to core's `context-add.sh --link`, and both must give the same verdicts.

## 4. What the quarry had that is dropped

| Dropped | Why |
|---|---|
| The `--context-file --link n` form | It was for agents reading a live link from a cut version. Agents now read the copy. It comes back only if dispatch shows a need |
| Jira | Later, as its own piece (§5) |
| The "spec revision when the ticket changes" rule | The flow and the spec's own how cover a changed goal |
| The process-tree watchdog | It stays only if the build shows `gh` or `glab` leaving children behind; first try is the simple background-and-kill timeout |

## 5. Decided (owner, 2026-11-21)

- **Jira:** GitHub and GitLab now. Jira becomes its own piece with its own credential handling once a real Jira task needs it, and never goes through the legacy skills. If the first real task comes from a Jira ticket, that sets when.
- **Comments:** included, within the same 500-line bound.
- **Signposts:** both `trackers/` and `code-context/` get the 40-word `SKILL.md`.

## 6. Decided (Fable's review, 2026-11-21)

- The copy, not a live link, is right. The header says where the copy came from and that it is material, not instructions. A cut-off copy says so in the file.
- Two scripts. The second only calls the first.
- No events, and no how; a signpost `SKILL.md` instead.
- Jira later, as its own piece, never through the legacy skills.
- The two link rules are checked against each other in the evidence run, never through a shared file.

## 7. Results (Fable, 2026-11-21): accepted

- **A partial copy says so in two places:** in its header, and on stderr. That covers both a cut at 500 lines and comments that couldn't be read.
- **An `/issues/<n>` link that is really a pull request is read as the tracker gives it,** and the `--help` says so.
- **Not proven yet:** a logged-in GitLab comments read. It's run on a host the owner uses in the live run.
- **Known, not changed:** the cut keeps the oldest lines, so a long ticket loses its newest comments. If a real ticket hits this, the better cut keeps the body and the newest comments.
- **For the owner, before any deploy:** the domain skills' names (`trackers`, `code-context`). Framework skills carry the `crucible-` prefix.
