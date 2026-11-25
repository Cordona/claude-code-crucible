# logkeep

Small POSIX `sh` tools for the backup host.

- `bin/prune-backups.sh DIR [KEEP]`: keeps the newest KEEP backups in DIR.

## Checks

- Tests: `sh tests/run.sh` (end to end, from the project root).
- Lint: `shellcheck -x -o all bin/*.sh tests/*.sh`.
