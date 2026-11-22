# The constitution

The core values of the next Crucible framework, from the 2026-11-19/20 conversation. Every design choice, script and line of prose is judged against them. When a choice breaks one, the choice changes, not the value.

## 1. Pieces, not pipelines

The framework gives the model deterministic pieces: scripts, each with one job and a narrow contract. The model assembles them into whatever pipeline the situation needs. The framework never tries to predict every scenario, in prose or in code. Scenarios are unbounded; pieces are not.

## 2. Scripts for determinism, the model for judgment

What must be exact goes in a script: state, numbers, keys, rendering, rules that must never be forgotten. What needs judgment stays with the model: reading the situation, choosing the next step, talking with the human. Nothing in between is written as a decision tree.

## 3. Invariants live in code, and they refuse

The few rules that must always hold are enforced by scripts and hooks, never by prose. Examples: who owns what, one agent per worktree, a gate before dispatch, no commit unasked, a plan sealed once implemented. A script refuses with a plain reason. It never steers: choosing the path is the model's job.

## 4. Events are facts

What happened is written once, by a script, as an event: a fact that is never edited, passed by reference, and survives compactions and restarts. Every event says, with no doubt, what belongs to whom. Events are what let the pieces work together without knowing each other.

## 5. Hows, not flows

What the framework knows about doing work is written as small, loose "hows": how we grill, how we do discovery, how we draft a spec, how we review. Each is one short reference that stands alone and isn't over-instructive. No how says what comes before or after it: hows can be combined in any order. A typical order (discovery, then grill) is a suggestion, not a rule. Where a goal has a "flow" at all, it reads: here are the hows; agree with the human how to reach the goal (§14). The deterministic pieces underneath stay: the scripts that write the events, lock a version, render a gate.

## 6. Thin prose

Prose gives guidelines: how to build context, how to dispatch agents, how to review. It doesn't give step trees. Every rule names the failure it prevents, or it goes. The model is capable: don't bury it in rules, and don't micromanage it. Programmatic complexity is acceptable; prose complexity is not.

## 7. The human decides, and keeps thinking

At a decision point the model computes the question from the situation, and a script renders it deterministically. The recommended option comes first, with the facts behind every option, and the human can always answer in their own words. A gate informs the human's thinking; it never replaces it.

## 8. Fast decisions across parallel contexts

Humans move between many contexts. Compact cards say where things stand and what is recommended: totals and a path, with details on request. What removes or refuses something is always visible. The goal is a right decision in seconds, then on to the next context.

## 9. Token efficiency

Script output is compact. Files are passed by path, never pasted. The model reads only what it needs, and spends its tokens on judgment, not on bookkeeping.

## 10. Once acted on, sealed

A record that work was done from is never amended: an approved plan once its tests are written, an event once written. A change is a new record. Mixing old and new is the costliest confusion there is.

## 11. Reuse before adding, one home per thing

Before a new script or rule, find the existing piece that does the job, and extend it. Each piece lives with its owner: shared machinery in the shared place, flow-specific logic in its flow. Abstract only after real repetition, never in advance.

## 12. Small, sufficient, then learn

Build the smallest version that does real work. Run it on real tasks, learn from what actually happens, and grow only from that. No edge-case hunting. Real evidence beats prediction: verify by running the pieces, check blind, and ask the people who did the work.

## 13. Safe by default

Never commit or push unasked. Never disturb what the human is using (the legacy framework stays untouched until they move). Never deploy into the human's own setup without their go.

## 14. The agreed pipeline

The way to reach a goal is agreed, not prescribed. When work needs several steps, such as building an effort's context, main proposes the steps at a gate, and the human accepts, changes or replaces them. The agreed steps are written as JSON, in an event, and main follows that JSON, not prose. Main bases a proposal on past pipelines that worked, or invents new steps when the situation calls for it. When the plan has to change, main and the human agree again, and the new pipeline is a new event; the old one stays as it was.

## 15. Prose pieces stand alone

A piece of prose never depends on another piece of prose. It doesn't name another file's sections, restate another file's rules, or rely on the reader having read something else. What pieces share comes from scripts and events, never from cross-references between documents. A change to one piece touches one piece: no blast radius, no cascade.

## 16. Weight follows frequency and stakes

How much machinery something gets depends on how often it happens and what a mistake costs. Something rare and cheap to undo gets a line of prose or nothing. Something frequent or costly to get wrong gets a script, a refusal or a gate. Nothing gets ceremony just because it exists.

## 17. Small scripts, one job each

Every script is small and does one thing. A script that grows several jobs is split, the way `effort.sh` would be split into start, close, reopen and status. Each script stands alone: it's callable on its own, its `--help` is its whole contract, and it works without its siblings. Where a group of scripts is used together, a thin hub may route to them. The hub only dispatches and holds no logic, and each script stays callable directly.
