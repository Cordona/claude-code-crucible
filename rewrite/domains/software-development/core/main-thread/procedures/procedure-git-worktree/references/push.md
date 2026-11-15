# Push

Read on the human's ask to push a worktree's branch ("push worktree alpha": the seat whose worktree is `<effort folder>/worktrees/alpha`) or every one ("push the effort's branches": every seat), whatever the effort's auto-push.

1. **The seats:** each seat with a worktree, and that worktree, is a line `list=$(sh "<seat scripts>/seats/seats.sh" list --effort '<effort folder>') && printf '%s\n' "$list" | jq -r '.seats[] | select(.status != "chosen") | [.seat, .worktree] | @tsv' | sort -u` prints. A read that exits non-zero failed: show its output, and push nothing.
2. **Push:** per seat asked for, `sh "<scripts>/push/push.sh" --worktree '<worktree>' --remote origin --effort '<effort folder>' --seat '<seat>' --card`, so the push is recorded as the seat's and said by the line `pushed`. A refused push stops only that worktree's.
