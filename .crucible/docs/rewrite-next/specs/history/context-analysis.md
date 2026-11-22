# The context: what it is today, and a proposal

## 1. What the context is

An effort's context is what its work starts from:

- **the spec:** the human-approved contract, covering the what and why in five sections, never the how;
- **docs:** short notes written for the work (research, design notes), each ended grill's answers, and diff patches;
- **references:** outside paths and links, each with a one-line why, naming what already exists instead of copying it.

### Its lifecycle

1. **Draft:** `<effort>/drafts/main-thread/context/` holds `docs/` (the next version's material) and `entries.json` (the pending paths and links).
2. **Cut:** when the human approves a dispatch plan, the dispatch scripts cut a version, provided the fingerprint the plan pinned still matches.
   - The version becomes a `context.cut` event: a complete copy, so an agent reads one file.
   - Its docs move to `files/context/v<N>/` and become read-only.
3. **Sealed:** a cut version never changes, because a sent dispatch pinned it by digest. New material goes into the next version (value 10).

### Who reads it

- **The dispatch scripts:** they fingerprint it, cut it, and pin it into the agent prompt.
- **The seat-run changes:** these use it.
- **The build and test flows:** they read it.
- **Agents:** they read it by `agent-context-rules.md`. The spec is the contract and everything else is a reference; a later folder wins; a conflict that changes the outcome is a blocker.

## 2. What `procedure-context` does today

There are about 7,000 words of prose: `SKILL.md` has 3,232, and eight references hold the rest. On the script side there is a 10,331-word `context.sh` with seven commands, two renderers, three validators and four views.

| Concern | Where it lives today | What kind of thing it is |
|---|---|---|
| The store: docs folder, pending entries, versions, cut, fingerprint | `context.sh` | Deterministic: a piece |
| Discovery: talk until the goal and what must not break are known, add entries, read every entry | SKILL.md steps 1–2 | Judgment: a how |
| Settling contradictions: one question each, only the human settles | step 3, `settling-contradictions.md`, `conflicting-human-instructions.md` | Judgment and the human: a how plus gates |
| The spec: draft it with the human, approval gate, revisions, left drafts | The spec, `settle-spec.md` (1,113 words of branches), `standard-spec`, `render-spec-gate.sh` | A how (drafting), a gate, and a piece (recording the approved spec) |
| "What next?" | step 7, `render-what-next.sh`, a fixed question | A fixed flow step |
| Extending after approval | step 5, `extend.md` | The same pieces again |
| Entry kinds: commits, task ids, Jira, GitHub and GitLab links | `entry-kinds.md`, `tracker-links.md`, `read-link.sh` | Software-development specifics |
| How agents read the context | `agent-context-rules.md` | The agent's side, not main's |
| Resume | Resume, `resume.md` | A status piece plus one line |

## 3. Where it breaks the constitution

- **One skill, seven concerns** (values 1, 11, 17). The store, discovery, contradictions, the spec, what-next, domain entry kinds and the agent rules are all knotted together.
- **A fixed flow** (values 5, 14). Discovery, then contradictions, then spec, then what-next is prescribed in steps. Under the constitution it's the first dynamic flow, agreed with the human.
- **Prose decision trees** (value 6). `settle-spec.md` is 1,113 words of branches for typed answers, left drafts, failed gates and re-ask counts.
- **Fixed questions and renderers** (value 7). The what-next question and the spec gate renderer duplicate what the generic gate now does.
- **Cross-references** (value 15). "As step 8 sets", "`references/settle-spec.md` step 4", "SKILL.md Always".
- **Domain in core** (value 11). Commits, Jira and GitHub are software-development concepts.
- **The agent's rules in main's skill** (value 11). How an agent reads its context belongs to the dispatch side.

## 4. Proposal

### The skills

| Skill | Kind | Holds |
|---|---|---|
| `crucible-context` | pieces plus thin prose | The store scripts, the `context.cut` event rule, and about 200 words: what the context is, references not copies, no secrets or instruction files, every entry read before the spec is approved, changes go to the next version |
| `crucible-discovery` | how | How we find out what the work must achieve and must not break, and how contradictions are settled with the human (one question each, only the human settles) |
| `crucible-spec` | how plus one piece | What a spec is (today's `standard-spec`, trimmed), how to draft it with the human, and approval through a normal gate. `spec-approve.sh` records the approved draft as `spec.md` |
| `crucible-grill` | how | Later, as planned |

"What next?" is dropped. The agreed flow decides the next step.

The agent's reading rules move to the dispatch side when agents arrive. Entry kinds and tracker reading move to the software-development domain.

### The pieces in `crucible-context`

Each is small, does one job and is callable alone:

- `context-docs.sh`: prints the draft docs folder, creating it.
- `context-add.sh`: adds an outside path or link, with its why.
- `context-drop.sh`: takes one out, with the human's reason.
- `context-status.sh`: the latest version, and whether anything is pending (used for resume too).
- `context-fingerprint.sh`: the would-be version's fingerprint, which a plan pins.
- `context-cut.sh`: cuts a version, only when the fingerprint still matches. Only the dispatch side runs it.
- `crucible-context/events/context.cut.jq`: the rule for the one event.

### Open questions for the owner

1. **The name:** `crucible-context`?
2. **The spec as its own how** (`crucible-spec`), separate from the context store?
3. **Pending entries:** keep them as a mutable draft file until the cut, as today, or make each add and drop an event?
4. **The cut:** keep the fingerprint and cut machinery as it is (proven), just split into the two scripts above?

## 5. Final design for the context scripts (proposed 2026-11-21)

### What the review confirmed about today

- **The `context.cut` body is `{version, paths, links, spec}`.**
  - Each `paths` entry is either `{path, why}` (an outside file or folder) or `{path, sha256}` (a docs folder, `files/context/v<N>`).
  - Each `links` entry is `{url, why}`.
  - `spec` is the `spec.md` of one of the version's docs folders.
  - Each version is a complete copy: it lists every docs folder up to it, so an agent reads one file.
- **The path safety rule:** a path must be absolute, with no quotes or `..`. It must not be a sensitive file (`.env*`, keys, certificates, `.netrc` and so on, or a `.git` or `.ssh` component), and not an instruction file (`CLAUDE.md`, `SKILL.md`, skills, agents, Claude settings).
- **What a docs folder may hold:** only `spec.md`, `grill-<N>.json`, `<name>.md` and `diff-<sha>.patch`, at most 1 MB together. The event itself is at most 64 KB.
- **The cut** happens only when the fingerprint the plan pinned still matches. It needs a spec. The docs are moved and made read-only, and the pending entries are cleared. A repeat with nothing new returns the latest version.
- **Reader checks before a version goes to an agent:** where the file is, its size, its shape, that the spec exists, that the docs digests are intact, and that it's the newest version.
- **`drop`** can also retire an entry of the latest version.
- **Every write** refuses unless the effort is open.

### The pieces

```
crucible-context/
  scripts/
    context-docs.sh          print the draft docs folder, creating it
    context-add.sh           add an outside path or link, with its why
    context-drop.sh          take out a pending entry, or retire one of the latest version's, with the human's reason
    context-status.sh        the latest version (path and sha256), and whether anything is pending
    context-fingerprint.sh   the fingerprint of the would-be version; writes nothing
    context-cut.sh           cut a version when the fingerprint still matches (any sender: dispatch or spin-off)
    context-verify.sh        a sender's check that a version is intact and the newest, before an agent gets it
    lib/path-rule.sh         the path safety rule, in one home
    lib/link-rule.jq         the safe-link rule
    lib/body.sh              builds the would-be body, shared by fingerprint and cut
  events/
    context.cut.jq           the body's shape, and the next version number
```

- **One addition elsewhere:** `crucible-effort/scripts/effort-state.sh`, which prints `open`, `paused` or `closed`, so other components can check the state without parsing a human line. Context writes refuse unless the state is open.
- **The spec moves to `crucible-spec`:** `spec-approve.sh` writes the approved draft as `spec.md` into the docs folder. It refuses without the human's recorded gate answer for that exact draft, so the gate's answer events must come first.
- **Dropped:**
  - `--docs-of` and `--docs-of-file`;
  - `latest --line`;
  - `render-spec-gate.sh`, `render-what-next.sh` and `views/`;
  - "what next?".
- **Moves to the software-development domain:** `diff` (a commit as a patch) and tracker reading. The domain keeps its own copy of the link rule, or calls `context-add.sh`.
- **Decoupled:** senders call `context-fingerprint.sh`, `context-cut.sh` and `context-verify.sh`, and never source the context's internals.
- **The `context.cut` body stays as today.** Every field has a reader: agents, and the senders' checks.

### Build order

1. The gate answer events: the answer hook, plus `record` on a gate.
2. `effort-state.sh`.
3. The `crucible-context` pieces.
4. `crucible-spec`.
