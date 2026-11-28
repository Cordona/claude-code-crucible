# Git identity as a floating piece: design

The owner asked for this design on 2026-11-22: small, single-job scripts, and an identity gate that is truly deterministic. Fable reviews it, and nothing is built before the owner's go.

## 1. What it is for

Every commit an agent makes in a worktree is authored, committed and signed as one identity: name, email, and a signing key this machine can actually use. The human picks that identity once per effort and repository, from the machine's own list. Main never types, ranks or recommends one. The pick becomes a fact, `identity.set`, which later pieces (the commit after an agent's run) read.

The piece writes a fact and nothing else: it never touches git config. The later commit piece applies the identity to each commit.

**"Repository" means one thing:** the repository a path belongs to, taken from git's common directory (`git rev-parse --git-common-dir`, made absolute) and named by its top folder. The setter and the getter both resolve `--repo` to it, so an identity set from the checkout is found from any worktree of it.

It is a step candidate: `git-identity/set-identity`, in the software-development domain's `setup` stage, ended by `identity.set`.

## 2. Where it lives

`new-rewrite/domains/software-development/core/main-thread/git-identity/`, a domain component beside the others. It reaches core only through core's public scripts: the event writer and reader, and the gate.

| File | Its one job |
|---|---|
| `SKILL.md` | The how: when to set an identity, and the order of the four calls |
| `flow-step.json` | One step: `set-identity` |
| `scripts/identity-list.sh` | Lists the signing identities this machine can use, as JSON. Reads only. |
| `scripts/identity-card.sh` | Prints the gate's card and question from a saved list. Reads only. |
| `scripts/identity-check.sh` | Says whether one name, email and key can sign in one repository. Reads only. |
| `scripts/identity-set.sh` | On the human's recorded pick, writes `identity.set` |
| `scripts/identity-get.sh` | Prints the effort's identity for one repository, from its newest `identity.set`. Reads only. |
| `events/identity.set.jq` | The event's rule |

There are five scripts with one job each, and no hub. Auto-push, which the old `settings.sh` mixed in, is not part of this piece: it becomes its own piece when pushes are built.

## 3. The scripts

**`identity-list.sh`**
- It ports the old `list-identities.sh` logic nearly as it is: battle-tested, read-only, and already solving the hard part, which is listing an SSH key only when this machine can sign with it (the agent holds it, or its private key sits beside the `.pub`).
- What changes: one JSON array on stdout instead of numbered `IDENTITY_<n>_` lines, and the key's comment dropped from the name, as `identity-candidates.sh` did.
- Each entry: `{label, name, email, signing: {format: openpgp|ssh, key}, fingerprint}`.
- `label` is made by the script, unique and stable: `<name> <email> · <format> <short fingerprint>`.
- Its order is the order the key ring and the agent give. Nothing ranks the entries.
- With no signing identity it prints `[]`, exit 0. On a missing tool it prints `[]`, with that tool named on stderr.

**`identity-card.sh --list FILE --repo DIR`**
- It reads a list `identity-list.sh` wrote to FILE, and runs `identity-check.sh` for each identity in the repository first.
- Only identities that can sign there become options. The ones left out are named below them, each with its reason ("not usable here: …"), so the human never picks a dead option and sees why a key is missing.
- It prints the card: one numbered line per identity, with its label, its key's fingerprint in full, and the line "Pick the identity this effort's commits in <repo> are signed as."
- `--question` prints the AskUserQuestion JSON instead: one single-select question, one option per identity, its label as the option label and its fingerprint as the description. No option is marked recommended.
- After that filter, more than 4 usable identities is refused with a plain message, because the question tool holds at most 4. That is a known limit until a real case shows up.

**`identity-check.sh --repo DIR --name N --email E --format F --key K`**
- It is `resolve-identity.sh`'s check, cut to its one job: can this key sign as this email in this repository? For SSH, git's allowed-signers file must map the email to the key; for OpenPGP, a key ID must carry the email.
- It prints `SIGNS: yes`, or names why not. It reads only and uses no network.

**`identity-set.sh --effort DIR --repo DIR --list FILE`**
1. Runs `identity-list.sh` again and refuses unless it matches FILE: the machine's identities changed since the card was shown.
2. Asks the gate's reader for the newest answer to record `set-identity` with subject `<repo>:<sha256 of FILE>`, as a choice (see 4).
3. Takes the answer only when it is exactly one of FILE's labels. A typed answer that isn't a label is refused. See 7.3.
4. Runs `identity-check.sh` for that identity and repository, and refuses when it can't sign.
5. Writes `identity.set` with the answer's seq.

**`identity-get.sh --effort DIR --repo DIR`**
- It prints the newest `identity.set` for that repository as one JSON object: `{repo, name, email, signing: {format, key}, fingerprint}`.
- Exit 5 when the effort has none for that repository.
- Its main reader comes later: the commit after an agent's run. It is built now because this piece's own evidence needs it, to show that an identity set from the checkout is found from a worktree. It is small, and the commit piece may reshape it when it arrives.

**`identity.set`**
- The body is `{repo, name, email, signing: {format, key}, fingerprint, answer}`.
- The rule checks the shape, that `answer` is a number, and that no earlier `identity.set` used the same answer. One pick sets one identity.
- A newer `identity.set` for the same repository replaces the older one, which is how the human changes the identity.

## 4. The deterministic gate: a recorded choice

Today a recorded gate has one yes label (`--accept`), and the shape hook requires a recommended first option. An identity pick is neither: it is a choice among real options, and the old rule "never recommend an identity" still holds, because a wrong default is easy to pick by mistake.

So core's gate gains a choice form. It is small and general, and the worktree base choice will need it too.

| Piece | Change |
|---|---|
| `show-card.sh` | `--choice` in place of `--accept` for a recorded gate. It is refused together with `--accept`. |
| hold hook, recorded-gate step | For a choice card: exactly one single-select question. Its options are not checked against anything, since the piece that reads the answer checks it against its own list. |
| hold hook, shape step | For a choice card it runs `check-question-shape.sh --choice`, which skips only the two recommendation rules. Every other shape rule holds. |
| `record-gate-answer.sh` | Writes no `accept` or `accepted` for a choice card |
| `gate.answered.jq` | A recorded answer has both `accept` and `accepted`, or neither. Neither means a choice. No new field. |
| `gate-answer.sh` | `--choice` prints `ANSWER_SEQ: <seq>` and `ANSWER: <text>` for the newest answer, exit 0, or exit 1 when there is none. `--choice` refuses a record that has `accept`, and the plain form refuses one that lacks it, so the two forms never mix. |

Why this is deterministic:
- The options come from the machine's own list, printed by a script.
- What the human answers is recorded by the hook, not by main.
- The subject pins the exact list the human saw.
- `identity-set.sh` accepts only an exact label from that list, re-checked against the machine, then checks that the key can sign.
- Main's only part is to run the scripts and relay the card.

## 5. The how, `SKILL.md`

The skill covers, in a few sentences:
- When: before the first agent's commit in a repository, when `identity-get.sh` has nothing for it, or when the human asks to change the identity.
- How:
  - write the list with `identity-list.sh` to a file;
  - show `identity-card.sh`'s card as a recorded choice gate, with record `set-identity` and subject `<repo>:<sha256 of the list>`;
  - ask `identity-card.sh --question`'s question;
  - run `identity-set.sh`.
- With no identity listed, tell the human to set up a signing key, and stop.
- The prose holds only that order and the stop case, never flags; each script's `--help` is its contract.

**Shared card rules:** the HANDOFF's trigger, "a second script-printed card", is met, since this is the second after the flow card. They wait for the dispatch card. The two cards share only "a script prints it and main relays it", which the gate skill already says, so there is nothing yet to share. The dispatch card is the first with several blocks and inputs, and it will show what a rule must say.

**A flow over two repositories** holds the identity step twice, each ended by its own `identity.set`.

## 6. Evidence

Each run starts from `/` with every path taken from stdout. A scratch GnuPG home, SSH agent and HOME hold test keys, so nothing in the run reads the owner's real agent, key ring or `~/.ssh`.

The cases:
- **The list:**
  - a GPG key and an SSH key the agent holds;
  - a `.pub` file with no private key, which is not listed;
  - no keys at all.
- **The card:**
  - stable labels;
  - a key that can't sign in this repository is listed as not usable, with its reason, and offered as no option;
  - more than 4 usable identities, refused.
- **The gate:**
  - a choice card's question with no recommended option passes;
  - a choice card's question with two questions is refused;
  - an accept-form question is unchanged;
  - `gate-answer.sh --choice` returns the newest pick, and refuses an accept record.
- **Repository:** an identity set from the checkout is found by `identity-get.sh` from a worktree of it.
- **Setting:**
  - a pick sets the identity;
  - a typed answer is refused;
  - a list that changed since the card was shown is refused;
  - a key that can't sign as the email is refused;
  - the same answer used twice is refused;
  - a second pick replaces the first;
  - `identity-get.sh` returns the newest identity, and exit 5 for an unknown repository.
- **Installed:**
  - `flow-candidates.sh --stage setup` lists `git-identity/set-identity`;
  - a flow with it is agreed, and the step is ended by `identity.set`.
- **Every other evidence run, unchanged,** apart from gate-answers, which gains the choice cases.

## 7. Fable's review (2026-11-22)

Sound, with fixes A–E, now written in:
- A: "repository" resolved from git's common directory;
- B: only usable identities offered, the rest named with a reason;
- C: `identity-get.sh` prints JSON;
- D: `identity-get.sh` kept, with the reason;
- E: shared card rules wait for the dispatch card.

Also written in, from Fable's answers:
- no `choice` field: a recorded answer has `accept` and `accepted`, or neither;
- a typed answer is refused;
- per effort and repository;
- the repository goes in the subject.

**Not built, with its trigger:** an identity with no signing key, for unsigned commits. The trigger is the first human who doesn't sign commits. Today the piece stops such a human, which suits the owner but not a general framework.

## 8. Beta's questions to Fable

1. **Is the recorded choice the right change to core's gate,** or is there a smaller one?
2. **More than 4 identities:** refuse, or filter (for example by an email the human gives) at the cost of one more question?
3. **A typed answer** such as a name and email with no key, meaning unsigned commits, was allowed by the old setup. Refuse it here, which keeps the pick deterministic, or add an unsigned path?
4. **Per effort and repository, or per effort only?**
5. **The subject `<repo>:<sha>`:** is pinning the repository in the subject right?
