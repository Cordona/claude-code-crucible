# Chains

Read after a seat's new commit (an `idle` result in `flow-code-build`) when a seat of the effort has `base_seats`, and when `mount-status.sh` gives a non-empty `parents_moved`.

`<show.sh>` is `sh "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/human-view/scripts/show.sh"`, and `<views>` is `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-git-worktree/views"`.

1. **Check:** `list=$(sh "<seat scripts>/seats/seats.sh" list --effort '<effort folder>') && printf '%s\n' "$list" | jq -r '.seats[] | select(.status != "chosen" and ((.base_seats // []) | length) > 0) | [.seat, .status] | @tsv'`, the seat that just committed included; per seat, `sh "<scripts>/merge/chain.sh" --effort '<effort folder>' --seat '<seat>'`. `moved: false`: nothing to do. A read that exits non-zero failed: show its output, and offer nothing.
2. **Offer,** one moved seat at a time: for a moved seat that is `idle`, load `procedure-approval-gate` with the Skill tool and follow its steps, with these inputs:
   - **The plan file:** its generator is `sh "<scripts>/merge/chain.sh" --effort '<effort folder>' --seat '<seat>' > '<the plan file>'`.
   - **The renderer:** `<show.sh> render --views <views> --name sync-offer < '<the plan file>'`.
   - **The gate's label:** `chain-sync`, with `--effort '<effort folder>'`.
   - **Above the gate:** the cards shown this turn, such as the seat's work card.
   - **On "now ask":** Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-git-worktree/references/sync-question.json` and pass its `questions` to one AskUserQuestion as written.
   - **The answer:** `Sync now (Recommended)` → step 3; `Not now` → nothing, offered again at the next commit. A typed answer: open the gate again.
   - **The gate can't be shown or asked:** show the human what failed, and sync nothing.

   A moved seat that is `working`: offer once its result is shown. A moved seat that is `open` or `gave-up`: offer nothing; the next check offers it once it is `idle`. The next moved seat's gate opens once this one's question is answered.
3. **Sync:** `sh "<scripts>/merge/chain-sync.sh" --effort '<effort folder>' --seat '<seat>'`. `synced: false`: nothing moved, say nothing. `synced: true`: write its `message` into the seat's todo item as its sync line: `procedure-seat-run`'s Changes sends it first in the next change to that seat. Then run `sh "<scripts>/mount/mount-status.sh" --repo '<repo>'`, `<repo>` the seat's `repo` that `sh "<seat scripts>/seats/seats.sh" get --effort '<effort folder>' --seat '<seat>'` prints; a read that exits non-zero: show its output, and offer no remount. When its `seats` holds that seat, open the remount gate as step 2 does, with these inputs:
   - **The plan file:** `{"seat": "<seat>", "repo": "<repo>"}`, written with the Write tool.
   - **The renderer:** `<show.sh> render --views <views> --name remount-offer < '<the plan file>'`.
   - **The gate's label:** `remount`, with `--effort '<effort folder>'`.
   - **Above the gate:** `chain-sync.sh`'s card.
   - **On "now ask":** Read `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/procedure-git-worktree/references/remount-question.json` and pass its `questions` to one AskUserQuestion as written.
   - **The answer:** `Remount (Recommended)` → `sh "<scripts>/mount/unmount.sh" --repo '<repo>'`, then `sh "<scripts>/mount/mount.sh" --effort '<effort folder>'` with one `--seat '<seat>'` per seat in `mount-status.sh`'s `seats`; `Leave it` → nothing. A typed answer: open the gate again.
   - **The gate can't be shown or asked:** show the human what failed, and remount nothing.
