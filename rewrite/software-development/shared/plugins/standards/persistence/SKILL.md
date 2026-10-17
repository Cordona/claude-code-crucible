---
name: standard-persistence
description: The correctness rubric for code in any language, tests included, that touches a durable store or its schema — store guarantees, integrity, atomicity, concurrency, queries, migrations, durability, connections, value types. Injected into the prompt when a brief's `PLUGIN` names it. Writes nothing. Not for injection or erasure policy (standard-security), scaling cost (standard-performance), telemetry (standard-observability), test-only rules (standard-testing) or ORM mechanics (its tech plugin).
disable-model-invocation: true
user-invocable: false
metadata:
  label: Persistence
---

# Standard: Persistence

What a correct data layer holds, for any durable store. The developer builds to these rules, then follows `references/development.md`; a reviewer (once `code-reviewer` exists) judges by the same rules, then follows `references/review.md`. Both receive this file in their prompt (or by Read, implementing directly), with their role's reference file right after it.

It assumes fluent SQL and NoSQL, so it holds only the non-default priorities and the easy-to-miss correctness traps, never a store tutorial.

## Scope

- **In:** code the developer writes or changes, test code included, that reads or writes a durable store, or changes its schema or migrations. A change that touches no durable store is out. Also in:
  - **Store choice:** which durable store a need goes to.
  - **Aggregate sizing:** the size of an aggregate and of its transaction boundary.
  - **Cache coherence:** an application or read-model cache kept in step with its store.
  - **A migration's consumer axis:** who outside the change breaks.
  - **Backup and DR:** backup, restore and disaster recovery of the store's data.
- **Any store:** Postgres, MongoDB, DynamoDB, Cassandra or Redis alike. Each rule's goal is fixed; what meets it depends on what the store guarantees. Never assume SQL.
- **Project conventions:** follow the project's persistence patterns: its repository or DAO layer, its migration tool, its id strategy, its transaction boundaries and its read and write concern defaults. New code never bypasses an existing safe pattern. A convention never excuses a data-integrity or lost-update bug: it is a defect even where the project does the same.

## Store guarantees

- **Match behaviour to the store's real guarantees, no stronger and no weaker:** a guarantee assumed but absent corrupts data; one denied but present forces needless machinery, such as a saga where a transaction exists.

Do this first, for each piece of code that touches a store.

- **Write the one-liner:** the store, then the guarantees that matter here. Example: `DynamoDB: single-item atomic by default; multi-item only through a bounded transaction API; eventual reads by default; conditional writes for concurrency.`
- **Headline capabilities: trust general knowledge,** with no lookup. Postgres is ACID; Redis is single-node atomic through `MULTI` or Lua; DynamoDB is single-item atomic by default; Cassandra is eventually consistent.
- **Version- or edition-conditional nuance: verify it (`mcp__context7` or WebFetch), and only then.** The traps live there: Mongo multi-document transactions need a replica set or sharded cluster and are discouraged on a hot path; Postgres isolation is configurable; a driver's default read and write concern varies. Never lean on a stale headline where the answer is "yes, but only under X".
- **Verify whenever the one-liner would deny a capability, not only when it asserts one:** stores gain multi-item transactions, consistency modes and index types over time.

Establish each axis for the target store; each changes what a rule requires:

| Axis | The question | What it decides |
|---|---|---|
| Transaction scope | Multi-item atomic writes, single-item only, or none? | All-or-nothing by transaction or by saga (§2) |
| Consistency model | Strong, read-your-writes or eventual; tunable? | Whether a just-written value reads back (§3) |
| Constraint enforcement | Native uniqueness, references, required fields and ranges, or app-only? | Where integrity rules live (§1) |
| Concurrency control | Version, conditional write, locks, or none? | How lost updates are prevented (§3) |
| Query and index model | Secondary indexes, joins or scans; what a scan costs? | Which access patterns are safe and which hide a full scan (§4) |
| Durability and ack level | Fire-and-forget, single node, quorum or journal fsync; tunable? | When a write counts as committed (§6) |

## 1. Data integrity and consistency

- **Integrity rules live at one authoritative layer:** where the store enforces constraints natively (uniqueness, references, required fields, ranges), use them, not an app-only copy. Where it doesn't (schemaless, key-value), enforce them at one write layer, such as the repository, never scattered or implicit.
- **No orphaned or contradictory state:** a dangling reference, a denormalized copy out of sync or a broken required invariant is a defect on any store.
- **Validate before persisting:** reject invalid domain state at the write boundary; never rely on a later read to notice corruption.
- **Exclude tombstones (records deleted logically, a soft-delete or a status flag, and kept in the store) structurally:** every live read path excludes them through a partial or filtered index, a generated uniqueness key or a mandatory repository predicate, never a hand-remembered `WHERE`.
- **Make uniqueness, reference and cascade rules account for tombstones:** one that collides with a unique key, leaks into a live query or bypasses a cascade is a correctness defect.
- **Keep prior state the domain needs to reconstruct:** where correctness depends on it (a ledger, an event-sourced aggregate, bitemporal validity, legally required history), stay append-only or versioned. An in-place update or hard delete that erases it is data loss.

## 2. Atomicity and transactions

- **Make all-or-nothing work atomic by the store's actual mechanism:** one transaction where multi-item atomic writes exist; otherwise idempotent steps with a compensation or saga path. Never assume atomicity the store doesn't give.
- **Keep transactions short:** never hold one open across a network call, an external API or user think-time. It starves the pool and widens lock windows; on an MVCC store a long transaction, even a read-only one, blocks vacuum.
- **No cross-store dual-write:** two systems (a store and a cache, search index or broker) share no transaction, so "commit here, then write there" loses the second write on a crash between them. Default to a transactional outbox written in the same atomic unit (a transaction where the store has multi-item atomic writes, otherwise one item) and relayed after commit; use change-data capture where the project already streams the store's log; otherwise require an explicit reconcile.
- **Coordinate steps across services by saga:** avoid distributed two-phase commit, which blocks on its coordinator.
- **A bulk or batch write is no transaction unless the store says so:** an ordered bulk write can stop mid-way with the prefix applied, a multi-partition unlogged batch is non-atomic, and a batch API can return unprocessed items. Handle partial completion: retry the remainder idempotently, or compensate.

## 3. Concurrency and isolation

- **Guard every read-modify-write against lost updates** with the store's real primitive: a version or etag, a conditional write, or a lock. A plain read-then-write under concurrency drops one update silently.
- **Claim a unit of work in one atomic step:** `SELECT … FOR UPDATE SKIP LOCKED`, a conditional status update, or a leased lock with a visibility timeout. Never read then update, which lets two workers process the same item.
- **Take multiple locks in one global order** on every code path, such as by primary key or parent before child, so no circular wait forms: ordering is the deadlock fix, and §6's bounded retry only the backstop. On a single-item-atomic store this doesn't arise.
- **Bound every lock and statement wait** with a timeout, so a blocked write fails fast instead of holding a connection.
- **Never assume stronger isolation than configured:** code that assumes serializable behaviour on a read-committed or eventually consistent store is wrong.
- **Prevent write-skew and phantoms:** two transactions that each read a multi-row predicate, pass a check and write break a cross-row invariant per-row versioning never sees. Default to serializable isolation; use a predicate or range lock where the store lacks serializable or its retries are too costly; on a single-item-atomic store, a serialized owner or a saga.
- **No blind writes where writers can collide on a last-write-wins store:** one of two concurrent writes is lost with no error. Default to a conditional (compare-and-set) write; use a CRDT or explicit version reconciliation only where both concurrent writes must survive, such as multi-region active-active.
- **Read your writes:** under eventual consistency, a value read right after its write is visible only through a strong read. Choose the consistency, or read and write concern, per operation where the store tunes it; never accept the default blindly.
- **A read that must see a just-committed write goes to the primary,** pinned for the lag window, or waits on a replication token; never assume an async replica has caught up.

## 4. Access-pattern correctness

- **On a join-less store, derive the model from the read patterns:** denormalize, or add per-query tables or materialized views. A required query with no supporting index, table or view is a design defect, not a tuning gap.
- **Serve a hot-path filter or sort from an index, never a full scan:** on a relational store through joins and indexes, on a join-less one through the modelled access pattern.
- **Hold every result set within a memory bound:** an unbounded collection loaded into memory fails once the data grows; cap it, stream it or page it.
- **Page stably:** on large or changing data, page by key (keyset or cursor): offset paging skips or duplicates rows when rows are inserted or deleted mid-traversal. Offset stays correct for a small bounded set, or when a jump to page N or a cheap total count is a hard requirement keyset can't serve.
- **Fetch only the fields needed:** pulling huge or unbounded columns (BLOBs, large documents) into memory breaks the memory bound above.

## 5. Schema evolution and migrations

- **Old and new readers and writers coexist through every transition:** never a big-bang change that assumes all code and data flip at once.
- **On a store with DDL:** migrations are versioned, ordered and applied by the migration tool, never hand-edited against a live schema, each with a down step or a documented forward-fix.
- **Change a relational shape by expand-contract, across releases:** add the new shape (nullable, no forced rewrite); backfill in bounded batches, never one long transaction; write both shapes during the transition, so rows written mid-backfill converge; switch the code; drop the old shape. Never one migration that renames or drops a column running code still uses.
- **On a schemaless store, evolve in the app:** a `schemaVersion` field, readers that accept the old and new shapes, and lazy migration on read or a throttled background rewrite. Never an unthrottled full-collection rewrite: it is the schemaless table lock.
- **Never assume a schema change is cheap:** one that looks metadata-only may take an exclusive lock or rewrite the dataset. Establish its lock and rewrite cost; default to the store's online form, and use a maintenance window only where the store has none.
- **Keep the schema change, the backfill and the deploy as separate steps,** each revertible on its own.
- **Every intermediate shape serves both app versions of a rolling deploy:** a new required field gets a default or a backfill. Judge a default's cost by the store's actual lock and rewrite behaviour, not by folklore.

## 6. Reliability and durability

- **Report success only at the durability the operation needs:** low acks (`w:0`, `acks=1`) lose a write on failover, async local commit (`synchronous_commit=off`) on a crash. Where loss is unacceptable, wait for a local fsync or journal ack, plus quorum replication as the topology needs. Where every ack is durable, this doesn't arise.
- **Make writes idempotent under retry:** a retried create never double-inserts. Dedupe with an atomic store primitive committed with the effect (a unique key or conditional put on the dedupe key), never check-then-write, which two retries can both pass. Persist the first outcome for replay.
- **An upsert is idempotent only when it sets absolute state,** never when it increments or appends.
- **Aim for exactly-once effects, not delivery:** exactly-once delivery across a network can't be had, and at-least-once delivery plus a non-idempotent write means duplicates. Never trust a broker's "exactly-once" claim blindly.
- **Make an at-least-once consumer idempotent:** record the message id in the same atomic unit as its effect, and let an order-dependent effect tolerate out-of-order and duplicate delivery.
- **Guard destructive operations:** an unpredicated `DELETE` or `UPDATE`, a `TRUNCATE`, `DROP` or drop-and-repopulate in a migration, or an unbounded rewrite is predicate-guarded and has a recovery path (a checkpoint, backup or PITR boundary, or documented forward-fix) before it runs.
- **Retry transient data-layer errors (deadlock, timeout, throttling) a bounded number of times, with jittered backoff:** never an unbounded tight loop.
- **Never swallow a write error and report success.**
- **Treat TTL expiry as best-effort where the store says so:** deletion can lag expiry by hours. Never depend on exact expiry timing, and never let a TTL reap a required record.
- **Define what a non-atomic multi-step flow does when a middle step fails:** default to compensating the completed steps; retry from the failure point where every remaining step is idempotent; fail the flow and roll back what a transaction can where neither applies. Left undefined, a partial write becomes permanent inconsistent state.

## 7. Connections and resources

- **Use a connection pool sized to the store's limits:** never a connection per call, and never an unbounded pool that exhausts the server.
- **Release every connection, cursor, statement and transaction, on the error path too,** with the language's scoped construct (`try`-with-resources, `defer`, `using`).
- **Stream a large read, or use a server-side cursor:** never hold the whole set in memory. Bounding the result set itself is §4.

## 8. Value representation and equality

- **Store values with the equality the code relies on:** collation and case, Unicode normalization (NFC or NFD), and null vs absent vs sentinel each change what the store calls equal. A uniqueness or lookup rule that assumes another equality is a defect, such as case folding that collides distinct keys, or a sparse unique index that treats missing, `null` and `""` as three values.
- **Persist money and precise decimals as an exact type:** an exact decimal, integer minor units or a string, never a binary float or a bare JSON number, which lose precision at rest.
- **Persist instants unambiguously:** UTC or an offset-aware type, never a naive local wall-clock value; ordering and time-window queries otherwise corrupt across DST and differently configured nodes.
- **Never change a key other records reference:** it orphans them.
- **Fit the id shape to the store's partition and index model:** the better of monotonic and random ids, UUID-vs-sequence throughput included, inverts between a single B-tree and a distributed partitioned store.
- **Never let a generated key exhaust its value domain:** a 32-bit sequence overflows at about 2.1 billion, and then every insert fails. Default to a 64-bit or UUID key; with a bounded sequence, monitor its headroom and widen it by expand-contract (§5) before exhaustion.
- **Evolve a persisted serialized value compatibly:** an enum, a polymorphic type or a JSON, Avro or Protobuf blob still reads under new code, and old readers don't break mid-rollout. A removed variant that crashes on an old record is a defect.
