# DatabaseServerRuntime

## Purpose and Scope

This internal SwiftPM target owns authenticated DatabaseWire operation
orchestration, durable publication, jobs, and remote diagnostics. Its parent is
the [server package](../../DESIGN.md); it exposes no reusable package product.
It currently has no independently designed child component.

The accepted SQL work adds statement and single-request block dispatch in S17.
Those operations are planned contracts until their execution and transport
tests pass. The complete feature inventory belongs to the
[SQL semantic profile](../../../database-kit/Sources/DatabaseKit/Query/SQL/DESIGN.md).

## Responsibilities and Boundaries

- Decode, correlate, admit, and classify canonical operations.
- Pass the authenticated principal, structural limits, and execution budget to
  Framework without interpreting SQL expressions, schema meaning, or indexes.
- Encode and publish only Framework results whose producing transactions and
  leases have authoritatively closed.
- Preserve typed operation, cleanup, cancellation, resource, and commit-unknown
  failures in the remote diagnostic contract.

Framework owns data transactions, SQL evaluation, constraints, schema
generation, checkpoints, and sequence recovery. StorageKit owns the backend.
Native listeners, credentials, and process shutdown belong to the host target.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Server package](../../DESIGN.md) | parent | operation/host boundary and publication | Composes this internal target. | This target is not a product for other hosts. |
| [DatabaseWire](../../../database-kit/Sources/DatabaseWire/DESIGN.md) | depends on | bounded operation and result codecs | Supplies statement/block requests and typed results. | Preserve target-free v3 and opt-in target-bound v5. |
| [SQL profile](../../../database-kit/Sources/DatabaseKit/Query/SQL/DESIGN.md) | depends on | feature and product-difference contract | Supplies meaning without runtime services. | Parsing success is not an execution capability. |
| [Database](../../../database-framework/Sources/Database/DESIGN.md) | depends on | public SQL statement and block entry | Supplies in-process execution. | No cross-request active transaction is retained here. |
| [DatabaseEngine](../../../database-framework/Sources/DatabaseEngine/DESIGN.md) | depends on | admitted data execution and ready results | Owns transaction closure and schema/sequence completion. | Server cannot manufacture readiness or commit data. |
| [StorageKit](../../../storage-kit/DESIGN.md) | depends on | independent control transactions | Owns durable result publication storage. | Control I/O starts after Framework data closure. |

## Architecture

```text
authenticated request -> bounded Wire decode -> operation admission
  -> Framework statement/block kernel -> data/resource closure
  -> ready result -> admitted page/publication owner
  -> control commit -> bounded Wire response
```

The existing query and mutation operations retain their distinct contracts.
The planned statement/block operation shares their Framework semantic owners;
it does not establish a second evaluator or schema administrator.

## Contracts and Invariants

- A SQL block arrives in one request and returns results in statement order
  after COMMIT/ROLLBACK and required closure work. No active transaction handle
  crosses requests or transports.
- Result columns preserve ordinal, duplicate labels, SQL type, nullability,
  and typmod even when no row is returned. Encoding never derives columns from
  sorted row dictionary keys.
- RETURNING and command effects are publishable only after authoritative
  commit; a commit-unknown outcome never becomes successful output.
- A schema job acceptance is distinct from synchronous SQL DDL completion.
- Principal, field policy, target, schema generation, budget, and continuation
  identity remain bound throughout execution and publication.
- Canonical SQLSTATE classification is an adaptation of typed failures, not a
  replacement for their original cause or cleanup outcome.

## Runtime Flows

For ordinary reads, Framework closes the data snapshot before Server admits
and encodes pages or starts any control transaction. For a block, Framework
collects bounded per-statement outcomes, completes data commit or cancellation,
publishes its prepared schema generation, and resolves sequence completion
before returning a ready owner. Server then performs publication and encoding.

## State, Ownership, and Lifecycle

| State | Owner | End condition |
|---|---|---|
| admitted request and authenticated context | Server operation instance | one typed response/failure or cancellation |
| active data block and collecting results | Framework kernel | authoritative transaction and resource closure |
| ready rows and exact claims | Framework ready owner | admitted page transfer or final output |
| encoded continuation and publication claims | Server publication owner | control commit, abort, or terminal cleanup |

This target does not keep mutable SQL session state. A timeout or disconnect
cancels the admitted operation and awaits its authoritative cleanup boundary.

## Failure, Concurrency, and Constraints

Admission and output limits apply before allocation. Large results retain one
payload owner with bounded ranges until the admitted transfer/output boundary.
Cancellation, publication failure, and shutdown release each claim exactly
once. No mutex is held over I/O or await. A failed or unavailable SQL capability
is explicit, including the profile's cross-request and row-lock exclusions.

## Verification and Change Impact

S17 owns actual text SQL through HTTP, WebSocket, and private stdio into
Framework and real backend readback. Tests compare result ordinals/types,
duplicate names, empty schemas, affected rows, RETURNING, SQLSTATE, block
rollback, principal isolation, paging, cancellation, and shutdown.

The [package harness](../../scripts/xcode-test-harness) owns exact standard and
MultiBase counts. SQL tests update their count with the coverage change.
Changes to Wire values recheck Client/CLI preservation; Framework result or
closure changes recheck this target's page owners and durable publication.
The full PostgreSQL semantic corpus stays owned by Framework, rather than
being repeated for every transport.
