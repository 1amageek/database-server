# Database Server

## Purpose and Scope

`database-server` is the standalone native DatabaseWire executable. This
package owns request admission, operation dispatch, durable server state, and
the native host boundary. It composes `database-framework` execution with a
host-selected `StorageEngine`; it does not reimplement query planning,
transaction semantics, index behavior, or application schema meaning.

This document is the package-level design authority for the internal
`DatabaseServerRuntime` and `DatabaseServerHost` targets. The package has one
supported public artifact, the `database-server` executable. Internal targets
are source and test boundaries, not reusable package products.

Parent: the workspace system design at [`../DESIGN.md`](../DESIGN.md), which
indexes this package; the workspace `AGENTS.md` defines the package dependency
direction and shared contracts.
Children: [DatabaseServerRuntime](Sources/DatabaseServerRuntime/DESIGN.md) owns
the internal operation-runtime design. `DatabaseServerHost` remains the
internal native composition boundary represented by its source directory.

## Responsibilities and Boundaries

`DatabaseServerRuntime` owns:

- canonical DatabaseWire frame decoding, admission, dispatch, and response
  encoding;
- remote query, graph, mutation, schema, maintenance, command, and job
  orchestration;
- durable continuation and result state;
- server request limits, authorization admission, typed remote errors, and
  runtime capability selection.

`DatabaseServerHost` owns:

- native listener and private stdio lifecycle;
- TLS, credentials, routing validation, process signals, backend startup, and
  authoritative shutdown;
- composition of a `DBContainer` with the selected storage engine and runtime.

The server does not own:

- query plans, index scans, graph algorithms, model materialization, or
  database transactions (the framework owns these);
- storage keys, retries, conflicts, backend protocol behavior, or engine
  lifecycle internals (StorageKit owns these);
- client profiles, shell behavior, or application schemas.

The server dependency direction is one-way:

```text
DatabaseWire request
        |
        v
DatabaseServerRuntime -- consumes --> DatabaseFramework execution contract
        |
        v
DatabaseServerHost -- composes --> DBContainer + StorageEngine + native host
```

The runtime may ask the framework for a bounded retained result or a
transaction-scoped page, but it may not reach into framework storage or
reconstruct a transaction. The host may select and shut down an engine, but it
may not reinterpret an operation payload.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`database-framework/DESIGN.md`](../database-framework/DESIGN.md) | depends on | Framework execution, read-snapshot, retained-result, and Composition contracts | Provides in-process query and graph semantics. | A server result must use an API available at the selected revision; obsolete Lease names and raw retained-value escapes are not contracts. |
| [`database-framework/Sources/DatabaseEngine/QueryExecution/DESIGN.md`](../database-framework/Sources/DatabaseEngine/QueryExecution/DESIGN.md) | depends on | retained ownership, bounded materialization, and transaction-scoped borrowing | Defines ownership and lifetime rules for query results. | A borrowing closure does not make a Copyable value durable; server staging must retain an admitted owner. |
| [`database-kit/DESIGN.md`](../database-kit/DESIGN.md) | depends on | DatabaseWire operation and response model | Defines canonical wire semantics consumed by dispatch. | The server maps and transports the model; it does not define query meaning. |
| [`storage-kit/DESIGN.md`](../storage-kit/DESIGN.md) | depends on | StorageEngine transaction and shutdown contracts | Provides control-storage and host-selected backend behavior. | Server control transactions begin only after every producing Framework data transaction closes, as required by SPEC.md. |

## Architecture

The runtime has two independent transaction domains for durable paging:

```text
wire request
   |
   v
admit + authorize
   |
   +--> framework data read
   |       |
   |       +--> SQL / graph page or bounded retained result
   |       +--> data transaction closes
   |
   +--> server control storage
           |
           +--> reserve slot and page identifiers
           +--> write staged page owners
           +--> publish manifest atomically
           +--> release active slot only at terminal transition
```

Composition preserves the same data-closure boundary as ordinary SQL. Memory
is admitted and bounded while Framework collects; exceeding that bound is a
typed failure. Server spooling cannot weaken the closure requirement:

```text
Composition source read -> Framework collecting owner + exact claims
  -> close every producing transaction, cursor, and member operation
  -> consume into ready owner
  -> admitted page transfer -> Server publication owner
  -> control transaction: spool pages and publish manifest
  -> release publication claims -> wire response
```

The four supported result modes have the same lifecycle vocabulary:

| Mode | Data-read state | Staging state | Control-publication state | Terminal state |
|---|---|---|---|---|
| SQL | framework snapshot executes the query | Framework retains admitted payload and exact claims until data closure; Server receives only a ready result | page chunks and manifest are committed after the data snapshot closes | final response has no successor; active slot is released and replay state is non-active |
| Graph | graph executor produces a bounded page or graph result | graph rows/quads remain in an admitted owner until encoding finishes | graph page descriptor/chunks and manifest commit in control storage | terminal graph page releases the slot without deleting required replay semantics prematurely |
| Relational Composition | member reads occur under one Composition data snapshot | Framework retains rows and claims under its collection limits until all member/data transactions close | admitted pages are transferred and spooled only from the ready owner; manifest commits in control storage | final page and claims are transferred/released after authoritative publication |
| RDF Composition | member graph reads occur under one Composition data snapshot | Framework retains quads and claims under its collection limits until all member/data transactions close | admitted graph pages are transferred and spooled only from the ready owner; manifest commits in control storage | final graph page and claims are transferred/released after authoritative publication |

## Contracts and Invariants

### Request and dependency contracts

- Every accepted frame reaches the canonical operation handler exactly once;
  adapters do not reinterpret operation payloads.
- Network authentication and routing validation finish before runtime
  execution. Typed operation failures remain typed wire failures.
- The server uses URL dependencies and one coherent resolved graph for release
  evidence. A local path dependency is diagnostic-only.

### Host storage topology contract

- A storage domain declares the Directory path of its own database root. The
  host names that root; it does not resolve or materialize a `Subspace` and
  hand storage keys to the framework.
- A placement names only its domain. A Base Partition's address is fixed below
  that domain's database root, so a placement carries no path, two placements
  on one domain address the same destination, and only one of them may declare
  it.
- The configuration document is versioned against exactly one topology shape.
  A document that still declares a placement path is rejected as invalid rather
  than loaded with the path discarded, and a standard build rejects placement
  keys rather than ignoring them.

### Data/control transaction contract

- A framework data read transaction is the sole owner of data-read state.
- A server control transaction is the sole owner of durable paging state.
- SQL and graph modes finish their bounded data capture before any control read
  or write, because the framework page is already materialized when the snapshot
  returns.
- Composition modes receive a ready result only after all Framework data and
  member transactions close. Control writes never run inside a producing
  callback. Framework collection limits bound retention before that closure;
  Server page/publication limits bound subsequent transfers and spooling.
- A staged page is bounded by both the request intermediate-byte limit and the
  server spool limit. Failure is explicit and does not publish a partial
  manifest.
- Historical continuation usage includes encoded step state and its terminal
  replay record; terminalization cannot exceed the configured historical byte
  limit.
- The staged owner, row/quad claims, and each encoded publication reservation
  remain live until authoritative control commit or abort. Retaining the
  first page is not final promotion: its owner and exact claim survive control
  commit, and only then may final output be promoted.

### Continuation and active-slot contract

- A continuation is opaque and bound to target, schema generation, query
  identity, full principal identity, and absolute expiry.
- A non-terminal page transition creates or reuses exactly one successor for
  concurrent replay. Replays must converge on the same successor.
- A terminal response performs an atomic terminal transition in control
  storage: required replay/tombstone state is retained within its bound, while
  the principal's active slot is removed from the quota index.
- A handler accounts for its response page while the reservation that produced
  it is still releasable: historical query and graph handlers account before
  requesting terminalization, and a durable page spool accounts inside the
  region that aborts the write. A refused output claim releases the published
  snapshot instead of orphaning a committed manifest and an active slot.
- One owner converts a response page into the rows it charges. A response page
  declares its materialized element count and the work meter charges that
  count, so no publication path restates the conversion, and an element count
  outside the budget counter's range is refused rather than truncated.
- A completion failure prevents a success response and leaves the continuation
  retryable.
- A terminal or expired transition may never clear a newer snapshot that reused
  the same slot. Cleanup compares snapshot identity before clearing an index.
- After eight completed snapshots, a ninth request for the same principal must
  be admitted immediately; completed non-active tombstones do not consume the
  active quota.
- Cancellation, append failure, commit failure, and malformed state release
  each reservation exactly once. Cleanup is not cancelled by the operation that
  caused it.

### Durable job payload contract

- A durable job payload declares a format version, and decoding rejects any
  payload whose version or field set does not match the current contract with a
  typed failure. A stale payload is never partially interpreted.
- The Base placement move descriptor records storage domain identity and
  placement generation, not a materialized Directory path. A Base Partition's
  address is fixed below its domain's database root, so naming the domain and
  its generation fully determines the keyspace a resumable slice may copy into.

### Composition contract

- Framework collection owns every produced row/quad with its exact claim
  under the admitted collection budget. A limit violation fails the data
  operation rather than publishing a partial result or starting control I/O.
- After data closure, Server transfers admitted pages from the ready owner
  into its publication owner and spools under the control transaction.
- The first page is retained through control commit; subsequent transfer
  cannot detach payload from its corresponding claim.
- Provenance remains attached to each staged row/quad through encoding and
  publication. It is not reconstructed after the source transaction closes.

## Runtime Flows

### SQL and graph page flow

1. Admit the request and derive its continuation identity.
2. Execute under a framework read snapshot.
3. If the result fits one page, return it without durable paging state.
4. Otherwise, Framework collects bounded successor payload with its claims,
   closes the producing snapshot, and transfers a ready result. Server page
   encoding and control publication occur after that closure.
5. Reserve and write control pages, publish the manifest, and return the first
   page with an opaque continuation.
6. On each continuation request, validate identity and expiry, load the page,
   and atomically terminalize when no successor remains. Historical query and
   graph handlers call their matching `completeHistorical*` operation after a
   final framework page; the store validates the current step before releasing
   its active slot.

### Composition flow

1. Resolve Composition metadata and authorize the request.
2. Framework collects rows/quads, provenance, and exact claims under its
   admitted data-operation limits.
3. Close every producing data/member transaction and resource, then consume
   the collecting result into a ready owner.
4. Server admits page/publication ownership, transfers successor pages, and
   commits the control manifest while retaining all required claims.
5. After authoritative control commit, promote the first-page final output;
   abort releases all publication state and preserves typed failures.

## State, Ownership, and Lifecycle

```text
reserved -> staging -> published/non-terminal -> terminal tombstone
    |          |              |                       |
    +--------> abort ---------+                       +--> expired cleanup
```

- `reserved` owns the principal active slot and pending marker.
- `staging` owns page reservations, encoded payload claims, and the bounded
  captured result.
- `published/non-terminal` owns durable page chunks and the active slot for
  future continuation requests.
- `terminal tombstone` marks the terminal replay state; the bounded manifest,
  steps, and page data remain available until expiry, but the tombstone is not
  an active quota slot.
- `abort` and expiry clear only state proven to belong to the same snapshot.
- The host owns final engine shutdown and must await the backend's authoritative
  completion before publishing a disconnected state or releasing the process.

## Failure, Concurrency, and Constraints

- Control transactions are retried according to StorageKit semantics, but
  publication and terminalization are idempotent by snapshot/page identity.
- Concurrent continuation requests use compare-and-set-like identity checks in
  one control transaction and observe one successor or one terminal state.
- Cancellation is observable by callers, while cleanup continues in a
  non-cancellable cleanup context and reports cleanup failure explicitly.
- Corrupt manifests, descriptors, chunks, or tombstones are typed corruption
  failures; they are never converted to empty success.
- Snapshot lifetime, active-slot count, historical-state limit, and spool bytes
  are correctness limits, not tuning hints.

## Verification and Change Impact

The package-level evidence must exercise real runtime paths, not declarations
or test discovery alone.

| Invariant | Required proof |
|---|---|
| Bounded Composition retention | A durable multi-page Composition read whose result exceeds the request intermediate-row budget proves peak intermediate retention stays within one page window, and that the retained first page is charged to the output limits instead, for both relational and RDF modes. |
| Exact staging ownership | Success, append failure, commit failure, cancellation, and abort tests prove the staging page's row/quad and byte claims remain until publication or abort, that the first page's claim is released exactly when it becomes output, and that every claim is released once. |
| Terminal quota release | Fill all eight active slots, complete each continuation, then admit a ninth request; verify terminal replay convergence, slot reuse isolation, expiry, failure, and cancellation. |
| Continuation identity | Cross-principal, target, schema, query, malformed, and expired continuations are rejected with typed errors. |
| Wire/transport boundary | Standard and MultiBase harnesses execute HTTP, HTTPS, WebSocket, and stdio through the real executable and report exact counts, skips, expected failures, runtime warnings, and internal errors. |
| Dependency authority | The final committed graph resolves URL dependencies, contains no `.package(path:)`, and uses the framework revision whose retained-result contract is actually compiled. |
| Host topology admission | Configuration tests load a valid versioned document and reject an unknown key, a duplicate domain, a missing domain reference, a duplicate persistent backend, and a placement that declares a path. |

Changes to framework retained-result or Composition contracts require a
cross-level review of this document and the framework designs before server
callers are migrated. Changes to active-slot or continuation persistence
require both runtime state tests and the package integration matrix.
