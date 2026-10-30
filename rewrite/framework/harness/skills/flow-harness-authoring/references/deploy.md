# Deploy

The link checks and commands behind G4, read before asking G4. Never and Always in `SKILL.md` decide whether G4 is reached at all.

1. **Run-path check:** the Grep `SKILL.md` Always sets for G4, before anything below.
2. **Link path:** `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/<name>` (skill) or `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents/<name>.md` (agent), with `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` expanded, so every command and the G4 view get the whole absolute path. Run `ls -ld <link path>` and, if it exists, `readlink <link path>`. When `readlink` prints the target path, record `Deploy: done` in `state.md` and send the `Already deployed` notice instead of asking G4.
3. **Deploy now:** `ln -s <target dir or agent file> <link path>`, never with `-f`.
4. **Replace the link:** `rm <link path>`; a non-zero exit fails closed, with no `ln -s`. Otherwise the `ln -s` of item 3.
5. **After `ln -s`:** run `readlink <link path>`; it must print the source path, else fail closed. Then record `Deploy: done` in `state.md`.
