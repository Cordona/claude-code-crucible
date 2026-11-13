# Mount

Read on the human's ask to see or run seats' work in their checkout, to unmount, or to see what is mounted. One mount per checkout, all its seats in that repository, `<repo>` the seat's `repo` that `sh "<scripts>/seats/seats.sh" get --effort '<effort folder>' --seat '<seat>'` prints:

- **Mount:** `sh "<scripts>/mount/mount.sh" --effort '<effort folder>' --seat '<seat>'`, one `--seat` per seat asked for; a seat in a chain brings the work it was cut from.
- **Mounted:** on exit 0, show its `line` as a fixed line.
- **Unmount:** `sh "<scripts>/mount/unmount.sh" --repo '<repo>'`. On exit 0, show its `line` as a fixed line.
- **What is mounted:** `sh "<scripts>/mount/mount-status.sh" --repo '<repo>'`; show its `line` as a fixed line.
- **A remount** at a seat's new work: an unmount, then a mount.
