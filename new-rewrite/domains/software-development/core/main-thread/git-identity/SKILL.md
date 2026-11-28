---
name: git-identity
description: Has the human pick, from this machine's signing identities, the one an effort's commits in a repository are signed as, and records it. Use before the first commit an agent makes in a repository that has no identity in the effort yet, or when the human asks to change one. Writes only identity.set events, through its scripts; never changes git config.
---

# Git identity

The human picks the identity; you never type, rank or recommend one, since a wrong default is easy to pick by mistake.

First check `identity-get.sh`: an identity already set for the repository needs nothing more. Otherwise:
1. save `identity-list.sh`'s output to a file;
2. show `identity-card.sh`'s card for that list and repository at a recorded choice gate, the record and subject as `identity-set.sh --help` sets;
3. ask the question `identity-card.sh --question` prints, as it is;
4. run `identity-set.sh` with the same list.

When no identity can sign in the repository, tell the human to set up a signing key, and stop.

The scripts you run are in this skill's `scripts/main/` folder; each one's `--help` is its contract.
