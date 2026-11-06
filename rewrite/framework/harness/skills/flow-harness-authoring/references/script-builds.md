# Script builds

How a script the author specified is built and fixed, read at Skill flow step 3 when the author's report holds a script spec, and at Merging step 5 on a chosen script finding.

1. Each script spec in `skill-author`'s report (§3) must name its live-validation targets, the real files to run it against. One that names none goes back to `skill-author` (FIX); when that reply returns, repeat this check on the new report before step 2. A spec that still names none is a loop with no progress (`SKILL.md` Always).
2. Dispatch `shell-script-developer` once per script spec, all in one message; each builds its script and live-validates it against real files, with no tests and no review. Save each reply to `scripts/<script>-r<n>.md` with `save-reply.sh --whole`.
3. A Validation field showing a failed or skipped live run, or a chosen script finding (`SKILL.md` Merging step 5 lists which IDs count): copy the script and its last report to `pre-fix/script-<script>-r<n>/`, then send it back to `shell-script-developer` in a fix round with that report, or with the chosen IDs and the merged report.
4. The round cap and the no-progress stop of `SKILL.md` Always apply to this loop; on either, send its `SKILL.md` Gates notice (`Stopped, no progress` or `Stopped, round cap`) with the last reports' paths.
