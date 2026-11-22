# Spec: crucible-context

The context is what agents work from besides their task: the approved spec, short notes written for the work, and references to outside files, folders and links, each with a one-line why. Main gathers it as a draft; a sealed version is cut when agents are sent, and an agent reads that one version.

## The pieces

| Piece | Its one job |
|---|---|
| `context-docs.sh` | Prints the draft docs folder, creating it |
| `context-add.sh` | Adds one outside path or link, with its why, to the pending entries |
| `context-drop.sh` | Takes a pending entry out, or retires one of the latest version's, with the human's reason |
| `context-status.sh` | Prints the latest version, its event's path, and whether anything is pending |
| `context-fingerprint.sh` | Builds the version a cut would write now and prints its fingerprint; writes nothing |
| `context-cut.sh` | Cuts a version when the context still gives the fingerprint the approved plan pinned |
| `context-verify.sh` | A sender's check that a version is intact and the newest, before an agent gets it |
| `context-path-check.sh` | Checks one path's text against the path rule; opens nothing |
| `lib/context.sh` | The locations, the refusal line, the open-effort check, the context lock, the latest version |
| `lib/path-rule.sh` | The path rule, in one home |
| `lib/link-rule.jq` | The link rule, shared by `context-add.sh` and the event rule |
| `lib/body.sh` | Builds the would-be version's body, so what a plan pins and what a cut writes are the same |
| `events/context.cut.jq` | The rule for the one event |

## The layout and lifecycle

- **Draft:** `<effort>/context/draft/` holds `docs/` (the next version's files) and `entries.json` (pending `paths`, `links` and `retire` entries).
- **Fingerprint:** a plan pins the sha256 of the would-be body. With nothing new, it is the latest version's own body.
- **Cut:** after the human approves sending agents, seated or spun off, the sender runs the cut with the pinned fingerprint. When the context still gives it, the cut moves `draft/docs` to `<effort>/context/v<N>/`, makes its files read-only, writes the `context.cut` event and clears the pending entries. With nothing new, it prints the latest version and writes nothing. If the event write fails, the docs move back.
- **Sealed:** a version never changes. Later adds and drops go into the next version.

Add, drop and cut take the context lock.

## The event

`context.cut` body: `{version, paths, links?, spec}`. Each version is a complete copy, so an agent reads one file.

| Field | Holds | Read by |
|---|---|---|
| `version` | The next number: one more than the earlier `context.cut` events | The rule; the cut's nothing-new check; `context-status.sh`; `context-add.sh` ("already in v<N>") |
| `paths` | `{path, why}` outside entries, and `{path, sha256}` docs folders, every one up to this version | The body builder (carried forward); `context-drop.sh` (retire); `context-verify.sh` (digests); agents |
| `links` | `{url, why}` entries; left out when empty | The body builder; add and drop; agents |
| `spec` | The `spec.md` of one of the version's docs folders: the newest one, or the earlier version's | The rule; `context-verify.sh` (it exists); the approval check when the draft has no `spec.md`; agents |

A docs folder's digest is the sha256 of its sorted `<sha256>  <name>` lines. The event is at most 65536 bytes.

## Rules the scripts enforce

- **Path rule** (text only, any letter case). Refused:
  - not absolute; a quote, control character or `..` segment: unsafe on a command line or escapes its place;
  - keys, credentials and secrets (`.env*`, `*.pem`, `*.key`, `id_*`, `credentials*`, `.netrc`, `.npmrc`, `.docker/config.json` and the like), anything under `.git` or `.ssh`: every agent sent after would read them;
  - instruction files (`CLAUDE.md`, `SKILL.md`, the skills and agents in the Claude folder): an agent may follow them as instructions;
  - personal settings (`settings.local.json` anywhere, `settings.json` in the Claude folder): private, and may hold secrets.
  - A project's own `.claude/settings.json` is allowed.
- **Add** also refuses a symlink, a path that doesn't exist or can't be read, and one inside the effort's `context/`. The why must be one non-empty line.
- **Link rule:** an http(s) URL of shell-safe characters only.
- **Docs folder:** only `spec.md`, `<name>.md` and `diff-<sha>.patch`, each a regular file passing the path rule, at most 1048576 bytes together (`DOCS-NAME`, `DOCS-SIZE`).
- **Drop** never takes out a docs folder, and refuses an entry that is neither pending nor in the latest version.
- **The approved spec:** fingerprint and cut refuse without a `spec.md` (`NO-SPEC`), and unless `spec.md`'s sha256 equals the newest `spec.approved` event's `sha256` (`NOT-APPROVED`). They refuse an empty context (`CONTEXT-NONE`). The cut also refuses a changed context (`CONTEXT-CHANGED`: show the plan again).
- **Open effort:** docs, add, drop and cut refuse unless `effort-state.sh` says `open`. Status, fingerprint and verify only read.
- **Verify** checks that the file is one of the effort's `context.cut` events (`NOT-CONTEXT`), a plain file of at most 65536 bytes that passes the event rule against the events before it (`SHAPE`), with its spec in place (`NO-SPEC`), every docs folder still giving its digest (`CONTEXT-CHANGED`), and the newest version (`STALE`).

## The one accepted pair

The context reads the spec's `spec.approved` event, through the shared event reader, and `spec-approve.sh` writes `spec.md` into the context's draft docs folder through `context-docs.sh`. That couples the two components in both directions, by event and by one public script. It is deliberate: the cut is the one place an unapproved spec can be stopped before it reaches a plan or an agent. It is the one such pair, not a pattern to copy.

## Decided, and why

- **References, not copies:** a copy goes stale and costs every agent its tokens.
- **A complete copy per version:** an agent reads one file, and a sent version needs nothing else.
- **Sealed versions:** a sent dispatch pinned the version; changing it would mix old and new.
- **One body builder for fingerprint and cut:** what the human approved is exactly what is sealed.
- **The approval check in the body builder:** an unapproved spec never reaches a plan, not only the cut.
- **Pending entries are one mutable draft file:** nothing acts on them until the cut, which is the fact.
- **Senders call the public scripts:** they never source the context's internals.

## Known limits

- The path rule reads the text only; a secret inside a note or a referenced file is not caught.
- Outside paths and links are not pinned: only docs folders carry a digest, so a referenced file can change after the cut.
- A drop's reason lives only in the draft; the sealed version does not keep it.
- The path rule's name lists are fixed; a sensitive file named otherwise passes.
