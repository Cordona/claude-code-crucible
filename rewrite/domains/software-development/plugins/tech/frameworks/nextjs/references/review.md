# Next.js: review

Apply with `SKILL.md`'s rules when judging Next.js code, beside the language plugin's review rules: review correctness first, by Correctness below, then judge the change by every rule in `SKILL.md`, grading by Severity. This file holds how to judge a finding and how to grade it; it sets no category vocabulary.

## Correctness

- **The tech lens owns correctness, and with this plugin loaded it judges Next.js correctness too.** Check for:
  - none of its own: the language plugin's Correctness list applies.

## How to judge

- **This lens grades every rule in `SKILL.md`, its security and accessibility forms included:** a tech-lens review loads no standard plugin, so no other file grades them here.
- **A reasoned suppression never excuses the defect its rule would catch:** judge that defect on its own.
- **Verify a Next.js API or version-specific behaviour against its current docs**, caching above all, before filing a finding that turns on it, never from memory alone.

## Severity

Where a Next.js defect usually lands on the four levels. Start here, then judge the case in front of you. It places Next.js defects, its security and accessibility forms included; the language plugin's Severity grades the language rules, and the React plugin's grades React's.

- **CRITICAL:**
  - a transaction split across Server Action or route handler round-trips: a non-atomic multi-write with no compensation.
- **HIGH:**
  - a correctness defect from Correctness above;
  - a Server Action or route handler that doesn't authorize its caller, or leaves it to middleware alone;
  - identity, role or tenant taken from caller-supplied input.
- **MEDIUM:**
  - a mutation that leaves cached data stale where the next read must see it;
  - hand-rolled route-level code splitting;
  - a heavy client component loaded eagerly;
  - a `@next/eslint-plugin-next` rule turned off or down in the project's lint config.
- **LOW:** none of its own.

**Overrides:** none.

**What moves a level:**
- A correctness defect rises to CRITICAL when its failure loses data or can't be undone.
