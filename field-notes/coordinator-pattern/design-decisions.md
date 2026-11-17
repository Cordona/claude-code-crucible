# Coordinator pattern — design decisions

Running log of what's actually been agreed, from the main-thread (dev session) side, while
figuring out this pattern live in `core-tech-mcp`. Only decisions actually confirmed go here —
not open questions, not one side's unconfirmed proposal. Timestamps are wall-clock, best effort.

## 2026-08-27 — Why this experiment exists

The dev+live-test loop (one session building, one session live-validating against the real
deployed target) is already proven — it ran an entire multi-tool migration effort successfully.
This experiment adds two more roles on top of that proven pair:

- **A review + fix session** — reviews AND fixes findings itself. No separate refactor-only
  session; the overhead of a review session handing findings to a fourth, different session
  to actually apply the fix was judged not worth it.
- **A dedicated test-development session** — owns `flow-testing` end-to-end for new work:
  authors tests, runs its own mandatory test-quality review pass, fixes findings, reports done.
  Added specifically because test-authoring/repair turned out to be a massive, standalone
  effort on its own during the just-completed migration — several single dispatches ran 30+
  minutes and touched dozens of files. The dev session doing this itself, inline, was the
  bottleneck being solved for.

The real payoff of adding these two isn't parallelism on ONE unit of work (test-dev
necessarily waits for dev+live-test to converge on a single tool — tests only follow
confirmation, never precede it). It's a **pipeline across a batch of units of work**: while
dev builds tool 2, test-dev can be writing tests for tool 1 (already converged), while review
reviews tool 1's code. This only pays off because there's an actual backlog (13 must-have
tools) to pipeline through, not one tool at a time.

## Roster

Five sessions, one shared working tree — deliberately no git worktrees. The per-tool-folder
architecture (built during the migration that preceded this experiment) is what's supposed to
keep conflict blast radius near zero without needing filesystem-level isolation.

| tmux window | Role |
|---|---|
| Tools Developer | Dev — builds tools, live-coordinates with the live-tester before formal review |
| Tools Live Tester | Live validation against the real deployed target |
| Tools Reviewer | Review + fix, self-contained |
| Tests Developer | Owns `flow-testing` end-to-end, including its own mandatory quality-review pass |
| Coordinator | Single point of human contact for the other four (see below) |

## The core coordinator idea

As much human-facing traffic as possible gets routed through the coordinator, so the human has
one point of contact instead of five sessions independently asking things.

Concretely: when a subject session hits a moment where it would normally call
`AskUserQuestion` directly — a genuine question, OR a Crucible-Framework-codified gate where
the session wants explicit human approval before proceeding (a review roster, a commit, a
test-authoring plan) — it instead relays that question to the coordinator via cross-session
message (exact wording, exact options, enough context to identify which session is asking and
why). The coordinator surfaces it to the human (via its own `AskUserQuestion` call,
reconstructing the question faithfully — no paraphrasing), collects the answer, relays it back,
and the subject session resumes.

**Explicitly excluded, not a gap to solve:** actual tool-permission prompts and Plan Mode's
approval flow are harness-level mechanics tied to each session's own local UI. There is no way
to reroute those through another session. They stay local to whichever session triggered them.

## Field notes are the primary deliverable, not a side effect

This pattern is not expected to be smooth on the first attempt. The point of running it live is
specifically to find where it breaks, not to prove it works. The coordinator's field notes ARE
what gets used to design the actual codified Crucible Framework pattern afterward.

Requirements on the notes themselves:
- Written **as friction happens**, timestamped, not reconstructed from memory at the end.
- Capture latency/overhead (how many hops did a question actually take, did it feel like it
  slowed things down), fidelity loss (did a relayed question get garbled or lose context in
  transit), attribution confusion (did the human ever have to ask "wait, which session is
  this?"), and any case where a session had to fall back to asking the human directly because
  something wasn't relayable.
- The initial brief handed to the coordinator is v0, not a spec. Where it hits a gap and has
  to invent something, that judgment call is itself a field note — "I had to decide X because
  nothing specified how" is exactly the kind of data this wants, not something to paper over.

## Memory/CLAUDE.md are the wrong place for session-specific persona instructions

Researched against the official Claude Code docs (`code.claude.com/docs/en/memory`) before
committing to a mechanism. Confirmed: both the auto-memory system and CLAUDE.md files are
scoped by **working directory / git repo path**, not by session. All sessions sharing the same
CWD load and share the exact same memory files and CLAUDE.md hierarchy — there is no built-in
Claude Code mechanism for persistence scoped to one specific session instance.

Consequence: writing a "you are the coordinator" persona into memory or CLAUDE.md in this repo
would leak that persona into all five sessions (they all share this CWD), not just the
coordinator. Confirmed as the wrong mechanism.

**Chosen mechanism for now (pre-skill):** a direct cross-session message to the coordinator
session specifically. This lands only in that one session's own conversation — no shared file
is touched, so there's no leak path to the other four. It persists for the life of that running
session (survives context compaction, since compaction summarizes history rather than dropping
it) but does NOT survive a session restart — a fresh session in the same tmux window would need
to be re-briefed from scratch. This gap (no durable, restart-surviving, session-scoped
persistence) is a known limitation of Claude Code today, not something this pattern solves.

## Eventual skill shape (for later, not built yet)

The main thread will read a durable "coordinator initialization brief" template that lives in
the Crucible Framework project, and use it to initialize a session as coordinator. That brief
itself includes instructions for the coordinator on how to onboard the sessions it will
coordinate — i.e., the coordinator briefs its own subordinates, not the main thread.

Two valid onboarding paths for a subordinate session, not mutually exclusive:
- **Push** — the coordinator is handed a known roster (e.g., "you will coordinate sessions
  1, 2, and 3") and proactively injects the behavior/communication briefing into each.
- **Pull** — a session is separately told "report to that coordinator"; on first contact, the
  coordinator replies with the behavior briefing.

Push fits a known-upfront roster; pull fits a session joining dynamically without the
coordinator already knowing about it.

**For this concrete experiment:** push applies — the roster of 4 subordinate sessions is
already known, so the coordinator will be handed that roster directly and will be responsible
for briefing each of them itself, rather than the main thread briefing all four individually.

## First observation from actually running it (relayed via the coordinator, not a direct
## main-thread decision — recorded here because it's a real design implication)

The coordinator's very first action was to confirm with Ventsislav directly before acting on
the dev session's relayed brief at all — correctly refusing to treat a peer session's word as
authorization to start messaging others or changing its own behavior. Good, and consistent with
the standing rule the dev session already holds for itself.

Ventsislav's actual response split the v0 brief's task list in two: he confirmed the
coordinator role/pattern itself as real, but explicitly withheld authorization for the
roster-briefing step ("still figuring out the coordinator pattern") — even though v0 handed
both to the coordinator as one bundled task list ("here's your persona, and part 2: go brief
these three sessions").

**Implication for the eventual pattern:** "confirm the role" and "authorize acting on the
roster" are two separable approval gates, not one bundled go-ahead, even when a brief presents
them together. Worth codifying as two distinct gate points rather than assuming a single
persona-briefing message implies standing authorization for everything the brief lists as that
session's job.

## 2026-08-27 — Correction: ALL cross-session traffic routes through the coordinator, not just human-facing

v0 of the dev session's brief had a real design flaw: it described the dev session as
live-coordinating directly with the live-tester before formal review — i.e., subject sessions
still talking peer-to-peer for actual work handoffs, with only human-facing questions/gates
routed through the coordinator.

Corrected: the whole point of "one coordinator" breaks if sessions can freely message each
other behind the coordinator's (and the human's) back for real work coordination, not just
human-facing moments. A peer-to-peer mesh for actual work handoffs is a shadow coordination
layer the coordinator can't see into — and it can't see into it, it can't produce a complete
picture of the pattern, which is the whole point of running this experiment. So: when the dev
session wants a tool live-tested, it messages the coordinator, which calls the live-tester and
relays the result back — not a direct message to the live-tester.

**Explicitly flagged as an open question to actively monitor, not settled:** the dev↔live-test
loop was the one *proven*, fast, tight loop before this experiment — direct, no third party.
Routing it through the coordinator adds a real hop cost on exactly the part that already worked
well. Whoever is paying attention (the coordinator, or another session) needs to watch closely
for whether this created unacceptable latency, and needs to be honest about it if it did —
"disallowing direct communication was wrong" is an acceptable conclusion to reach FROM running
this, not something to avoid concluding because it contradicts the initial design.

**A candidate next variant, NOT adopted, logged so it isn't lost:** sessions could be allowed to
talk directly, but with a mandatory obligation to brief the coordinator about that chatter, so
the coordinator stays fully aware without being the literal relay for every message. Real
tradeoff versus the strict model: the strict model gives the coordinator full visibility
*structurally* (there is no path around it); this variant only gives the same visibility if
every session reliably discloses every time, with nothing enforcing that — a weaker guarantee,
and it introduces its own open question (does disclosure happen in real time, or batched
after-the-fact, and does a stale picture matter if the human asks "what's happening right now"
mid-flight). Recommendation: run the strict model first; treat this as the thing to try next
specifically if the strict model's cost turns out to be too high in practice, not before.

## 2026-08-27 — Field notes format: shared JSONL, no category field, no locking

Decided the coordinator's own field notes (and eventually every session's) should NOT be a
growing prose markdown file — it becomes unparseable by an agent at volume. Moving to one
shared, append-only JSONL file instead.

- **Schema:** `{ts, agent, summary, body}`. No `category`/`type` field — an unconstrained
  taxonomy invites every agent to invent its own inconsistent labels, which is worse than no
  categorization at all. Categories, if any turn out to be useful, get derived from the
  collected notes later, once there's real data to look at — not guessed upfront.
  `summary`/`body` is a different kind of split — not an open taxonomy, every entry naturally
  has a short and a fuller version — and mirrors patterns already used elsewhere in this
  framework (commit subject+body, the review-findings schema's short_summary+summary). Lets a
  later synthesis pass scan summaries cheaply before reading a body in full.
- **One shared file, not split per-agent.** The `agent` field already gives per-agent
  filterability; a single file additionally preserves a genuine merged chronological timeline
  across all sessions, which matters for reconstructing how the pattern actually executed.
  Splitting would require a merge-and-sort step to get that back.
- **No file-locking / mutex.** Discussed a proper fix for the concurrent-write race (multiple
  sessions appending to the same file at once) — an atomic `mkdir`-based lock with a
  crash-safe `trap` for release — but explicitly decided that's over-engineering for now. The
  race is judged rare enough to accept. If it turns out to actually happen and corrupt/interleave
  entries in practice, that itself becomes a field note, and the fallback is exactly the
  locking mechanism already designed but not built.
- **Delegated the actual script** to `claude-code-crucible-82` (a session in the Crucible
  Framework repo itself) — a minimal append-only writer, one JSONL line per call, no locking.
- **Ownership split going forward:** the dev session (main thread) is refocusing on actual tool
  development; the coordinator now owns following up with `claude-code-crucible-82` on the
  script's readiness and relaying the invocation to the rest of the roster once ready. This
  itself is a small instance of the pattern's own principle — cross-session follow-up work
  routes through the coordinator rather than the main thread chasing it directly.
