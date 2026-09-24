# review-aggregates.jq — the ONE definition of flow-review's verdict
# arithmetic: the open-by-severity tally, the summary block built from it, and
# the overall verdict derived from that summary.
#
# Read as jq source text (never sourced as shell) by review-create.sh,
# review-add-round.sh, review-update-status.sh and render-md.sh, so the three
# writers and the renderer can never disagree about what counts as blocking.
# Each caller prepends this text to its own jq program; nothing here touches a
# file, takes a $-argument, or has a side effect.
#
# WHY an out-of-domain severity is COUNTED AS CRITICAL rather than dropped:
# the tally is keyed by `.severity | ascii_downcase`, so a value outside
# CRITICAL/HIGH/MEDIUM/LOW would add a FIFTH key and produce a summary that
# finding-summary.schema.json rejects (its `open` object is closed) — it
# cannot be tallied verbatim. But silently EXCLUDING it would let a tampered
# or corrupt severity on an OPEN finding vanish from the count, so a recompute
# could still report APPROVED while that finding is genuinely open. Folding it
# into the highest bucket keeps the summary schema-valid and makes the failure
# mode fail-CLOSED: an unrecognized severity can only ever raise the verdict,
# never lower it. A missing/non-string severity lands here for the same reason.

def severity_bucket:
  if (type == "string") and (ascii_downcase | IN("critical", "high", "medium", "low"))
  then ascii_downcase
  else "critical"
  end;

# WHY a finding leaves the open tally ONLY on an explicitly CLOSED status
# (RESOLVED or ACK), rather than entering it only on NEW/OPEN/REGRESSED: the
# same fail-CLOSED principle as severity_bucket above. Selecting by the open
# statuses would let a tampered or corrupt status on an OPEN finding (an array,
# null, a misspelling, a missing key) drop it out of every bucket, so a
# recompute could report APPROVED while that finding is genuinely open.
# Selecting by the closed statuses means an unrecognized status can only ever
# raise the verdict, never lower it. The resolved/new/ack counts in summary
# stay exact-match: none of them gates the verdict.
def open_counts(findings):
  reduce (findings[]
          | select(.status | IN("RESOLVED", "ACK") | not)
         ) as $f
    ({critical: 0, high: 0, medium: 0, low: 0}; .[$f.severity | severity_bucket] += 1);

def summary(findings):
  { open: open_counts(findings),
    resolved: ([findings[] | select(.status == "RESOLVED")] | length),
    new: ([findings[] | select(.status == "NEW")] | length),
    ack: ([findings[] | select(.status == "ACK")] | length)
  };

def verdict($s):
  if ($s.open.critical > 0 or $s.open.high > 0) then "CHANGES_REQUIRED"
  elif ($s.open.medium > 0 or $s.open.low > 0) then "APPROVED_WITH_FOLLOWUPS"
  else "APPROVED" end;
