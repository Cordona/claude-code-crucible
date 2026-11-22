# Spec: crucible-context

The context is the outside material the work needs: references to outside files, folders and links, each with a one-line why, and draft docs written or copied for the work (notes, ticket copies, patches). It never holds the spec or a grill. Main gathers it as a draft; when the human says it is done, it is cut into a sealed version, and an agent reads that one version.

## The pieces

| Piece | Its one job |
|---|---|
| `context-docs.sh` | Prints the draft docs folder, creating it |
| `context-add.sh` | Adds one outside path or link, with its why, to the pending entries |
| `context-drop.sh` | Takes a pending entry out, or retires one of the latest version's, with the human's reason |
| `context-status.sh` | Prints the latest version, its event's path, and whether anything is pending |
| `context-fingerprint.sh` | Builds the version a cut would write now and prints its fingerprint, the subject of the human's `context-done` gate; writes nothing |
| `context-cut.sh` | Cuts a version once the human's newest answer at the `context-done` gate on its fingerprint is a yes |
| `context-verify.sh` | A sender's check that a version is intact and the newest, before an agent gets it |
| `context-path-check.sh` | Checks one path's text against the path rule; opens nothing |
| `lib/context.sh` | The locations, the refusal line, the open-effort check, the context lock, the latest version |
| `lib/path-rule.sh` | The path rule, in one home |
| `lib/link-rule.jq` | The link rule, shared by `context-add.sh` and the event rule |
| `lib/body.sh` | Builds the would-be version's body, so what the human said yes to and what a cut writes are the same |
| `events/context.cut.jq` | The rule for the one event |

## The layout and lifecycle

- **Draft:** `<effort>/context/draft/` holds `docs/` (the next version's files) and `entries.json` (pending `paths`, `links` and `retire` entries).
- **Fingerprint:** the sha256 of the would-be body. With nothing new, it is the latest version's own body; with nothing at all, an empty first version's (`paths: []`).
- **Done gate:** main reads every entry, then asks the human at a recorded gate with the record `context-done` and the fingerprint as its subject. The card is main's own, with the draft's path on it.
- **Cut:** `context-cut.sh --effort` builds the body, takes its fingerprint and asks the gate (`gate-answer.sh --record context-done --subject <fingerprint>`). Unless the human's newest answer there is the yes, it exits 1 (`NOT-CONFIRMED`) and writes nothing. A draft changed since the yes has another fingerprint, so the human is asked again. With the yes, the cut moves `draft/docs` to `<effort>/context/v<N>/`, makes its files read-only, writes the `context.cut` event and clears the pending entries. An empty context is cut as a version with `paths: []`. With nothing new since the latest version, it prints that version and writes nothing. If the event write fails, the docs move back.
- **Sealed:** a version never changes. Later adds and drops go into the next version, after another done gate.

Add, drop and cut take the context lock.

## The event

`context.cut` body: `{version, paths, links?}`. Each version is a complete copy, so an agent reads one file.

| Field | Holds | Read by |
|---|---|---|
| `version` | The next number: one more than the earlier `context.cut` events | The rule; the cut's nothing-new check; `context-status.sh`; `context-add.sh` ("already in v<N>") |
| `paths` | `{path, why}` outside entries, and `{path, sha256}` docs folders, every one up to this version | The body builder (carried forward); `context-drop.sh` (retire); `context-verify.sh` (digests); agents |
| `links` | `{url, why}` entries; left out when empty | The body builder; add and drop; agents |

A docs folder's digest is the sha256 of its sorted `<sha256>  <name>` lines. The event is at most 65536 bytes.

## Rules the scripts enforce

- **Path rule** (text only, any letter case). Refused:
  - not absolute; a quote, control character or `..` segment: unsafe on a command line or escapes its place;
  - keys, credentials and secrets (`.env*`, `*.pem`, `*.key`, `id_*`, `credentials*`, `.netrc`, `.npmrc`, `.docker/config.json` and the like), anything under `.git` or `.ssh`: every agent sent after would read them;
  - instruction files (`CLAUDE.md`, `SKILL.md`, the skills and agents in the Claude folder): an agent may follow them as instructions;
  - personal settings (`settings.local.json` anywhere, `settings.json` in the Claude folder): private, and may hold secrets.
  - A project's own `.claude/settings.json` is allowed.
- **Add** also refuses a symlink, a path that doesn't exist or can't be read, and any path inside the effort's own folder: the effort's own facts reach agents through the sender, never as a reference. The why must be one non-empty line.
- **Link rule:** an http(s) URL of shell-safe characters only.
- **Docs folder:** only `<name>.md` and `diff-<sha>.patch`, each a regular file passing the path rule, at most 1048576 bytes together (`DOCS-NAME`, `DOCS-SIZE`). `spec.md` is refused: the spec lives in the effort's `spec/` folder.
- **Drop** never takes out a docs folder, and refuses an entry that is neither pending nor in the latest version.
- **The human's yes:** the cut refuses unless the human's newest answer at the `context-done` gate on the current fingerprint is the yes (`NOT-CONFIRMED`, exit 1).
- **Open effort:** docs, add, drop and cut refuse unless `effort-state.sh` says `open`. Status, fingerprint and verify only read.
- **Verify** checks that the file is one of the effort's `context.cut` events (`NOT-CONTEXT`), a plain file of at most 65536 bytes that passes the event rule against the events before it (`SHAPE`), every docs folder still giving its digest (`CONTEXT-CHANGED`), and the newest version (`STALE`).

## Decided, and why

- **The context, the grill and the spec are three independent facts:** each ends in its own event (`context.cut`, `grill.ended`, `spec.approved`) and none reads the others; the sender gathers them for an agent.
- **The cut is on the human's "done":** the inputs are sealed before any send, so a dispatch plan pins a finished version.
- **An empty context may be cut:** the facts may have lived in the conversation; only the human judges whether something is missing.
- **Cards stay free-form, written by main; the fingerprint is the guarantee:** the cut refuses if the draft changed since the yes, so what is sealed is exactly what the human said yes to.
- **References, not copies:** a copy goes stale and costs every agent its tokens.
- **A complete copy per version:** an agent reads one file, and a sent version needs nothing else.
- **Sealed versions:** a sent dispatch pinned the version; changing it would mix old and new.
- **One body builder for fingerprint and cut:** the fingerprint the human said yes to and the version sealed come from the same code.
- **Pending entries are one mutable draft file:** nothing acts on them until the cut, which is the fact.
- **Senders call the public scripts:** they never source the context's internals.

## Known limits

- The path rule reads the text only; a secret inside a note or a referenced file is not caught.
- Outside paths and links are not pinned: only docs folders carry a digest, so a referenced file can change after the cut.
- A drop's reason lives only in the draft; the sealed version does not keep it.
- The path rule's name lists are fixed; a sensitive file named otherwise passes.
