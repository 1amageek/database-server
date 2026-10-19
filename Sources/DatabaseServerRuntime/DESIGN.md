# DatabaseServerRuntime

## Purpose and Scope

This internal SwiftPM target owns authenticated DatabaseWire operation
orchestration, durable publication, jobs, and remote diagnostics. Its parent is
the [server package](../../DESIGN.md); it exposes no reusable package product.
It currently has no independently designed child component.

The accepted SQL work adds one complete-response SQL operation in S17.
The S17 contract below governs implementation; completion still requires its
execution and transport evidence. The complete feature inventory belongs to the
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

### S01 positional page migration

S01 consumes the frozen [Kit query boundary](../../../database-kit/Sources/DatabaseKit/Query/DESIGN.md#s01-public-query-boundary)
and [Wire grammar](../../../database-kit/Sources/DatabaseWire/DESIGN.md#s01-frozen-query-codec-contract).
QueryColumn is imported explicitly from DatabaseKit. QueryRowPage remains a
Wire-owned encoded/retained page; its cells use the Kit-owned QueryValue.
The following are required source migrations, not implemented claims:

| Existing path | S01 replacement and invariant |
|---|---|
| QueryExecuteHandler.rowPage | Consume Framework's bound columns and positional cells directly. Remove sorted union-of-row-keys inference and missing-cell-to-NULL conversion. Validate arity/type before page publication, including zero rows. |
| DatabaseQueryOperations/DatabaseQueryRowEncoder | Pass QueryValue cells without primitive reconstruction. Keep annotations/version conversion explicit and reject incompatible shape; this adapter owns no coercion, type inference or rich-value parser. |
| QueryExecuteHandler durable snapshot staging | Carry columns with the ready retained row owner through first-page, single-page, zero-row and continuation construction. Every stored page carries the identical column declaration; a row range alone cannot reconstruct a page schema. |
| DatabaseQuerySnapshotStore and its page persistence path | Store the new bounded canonical page payload and validate it completely on read. Existing principal/schema-generation/query-fingerprint/continuation identity remains authoritative; unknown/old payloads fail explicitly. Publication starts only after Framework closes its producing resources. |
| DatabaseCompositionQueryAdapter / DatabaseCompositionQueryResultBuilder | Bind ordered member columns before row iteration and compare declarations by position/type. Retain duplicate names and empty member schemas. Preserve v5 provenance origin count/order and consistency; do not use first-row sorted keys. |
| Operation admission/output accounting | Charge bound column metadata and query-value retained/encoded payloads before page construction or snapshot append. Retain the producing claim until the destination has admitted its own representation. |
| DatabaseStatementAdmission | Keep structural validation and parameter binding for every statement. Select SPARQL semantic validation through Kit's top-level `DataSource.usesSPARQLSemantics` contract; SQL SELECT roots retain SQL labels and rich literals. Preserve the existing gate for SPARQL-specific statements. |

```text
Framework Ready(columns, retained positional rows)
  → admit page(columns, selected row range)
      → no continuation: bounded response
      → continuation: stage the same columns in each snapshot page
          → control commit → first response
          → identity-checked continuation → validated stored page
```

The retained first page remains staged until the control manifest commits.
Its destination row/origin/event containers and schema reservation stay charged
alongside the current continuation page; output/page limits do not replace
those claims. Producer events retain their existing payload claims without a
second payload charge. Success transfers the output after authoritative commit;
publication failure and abort release every staged destination claim once.
Server owns checked arithmetic for its destination schema/container claims;
Framework's package-internal footprint model is not a server dependency.
`DatabaseCompositionQueryTests/firstPageReservationSurvivesBlockedPublication()`
blocks the actual manifest commit, checks both retained page claims, and covers
success plus a conflicting target change followed by authoritative abort.

S01 adds no SQL statement/block dispatch and no remote transaction lifetime.
Existing query dispatch consumes richer values; later S17 still owns the new
statement/block operations. Default v3 and opt-in v5 target/provenance shapes
follow Wire and are not renegotiated by this target.

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

### S03 SQL admission relay

DatabaseStatementAdmission uses Kit's non-substituting validation for SQL text
and relational SQL IR. Original parameter references, supplied values and
explicit declarations reach Framework's
[binding/prepared execution boundary](../../../database-framework/Sources/Database/DESIGN.md#s03-sql-binding-and-local-diagnostic-bridge).
The validated carrier retains the SQL parse arena/root and optional source map
for that request; existing SPARQL/GraphTerm replacement and language gates remain.
SQL text is parsed with QueryAST's `preservesCastOutputNames`, as the Database
facade does, so a folded constant cast keeps its PostgreSQL output name; IR
input carries no cast syntax and is named from its expressions.
Server owns structural admission and typed mapping, not SQL inference or a
second binder. Query handling passes parameters to preflight, prepared execution
and zero-row metadata consistently, including MultiBase member paths. Existing
authority, work meter, publication, lazy page and cancellation contracts remain.
S03-C02/C03/C10/C12 require actual SQL/IR invocation and no declaration erasure;
final remote SQLSTATE/details and CLI display remain S16. Unrelated native host
authentication work is outside this change.

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

S01-C10–C13 in the [Kit acceptance ledger](../../../database-kit/Sources/DatabaseKit/Query/SQL/DESIGN.md#s01-falsifiable-case-ids)
require actual authenticated query invocation through Server and Client into
the CLI renderer, with first/continuation/zero-row typed columns, duplicate
labels, rich values and explicit malformed-page failure. Snapshot tests also
prove payload corruption/type mismatch is rejected before output, claims remain
live through staging, and abort/cancel releases partial publication state.
Composition tests cover the selected MultiBase graph without changing origin
identity or ordering. Framework owns model persistence and SQL result semantics;
Server tests own dispatch, page mapping and durable publication, rather than
duplicating the complete evaluator corpus. The package's existing source and
configuration work is independent and must be preserved during this migration.
SPARQL query-literal conversion failures remain invalid RDF literal requests;
explicit literal-size failures retain their resource-limit classification.
Canonical read expression failures preserve the Framework binding/evaluation
cause as `INVALID_QUERY_EXPRESSION` with the invalid-request category. A
schema-bound nonnumeric aggregate operand fails before fetching data rather
than becoming a generic internal failure or a reduction constraint error.
Composition aggregate fixtures compare the bound SQL type and canonical
numeric SUM value. Paging fixtures retain an explicit insufficient Ready-row
budget failure, then read every durable page under a bound that includes
Framework's complete Ready owner and Server's two destination page containers.

S17 owns actual text SQL through HTTP, WebSocket, and private stdio into
Framework and real backend readback. Tests compare result ordinals/types,
duplicate names, empty schemas, affected rows, RETURNING, SQLSTATE, block
rollback, principal isolation, paging, cancellation, and shutdown.

The [package harness](../../scripts/xcode-test-harness) owns exact standard and
MultiBase counts. SQL tests update their count with the coverage change.
Focused native verification uses repeatable `--only-testing` selectors plus
an exact positive `--expected-count`. Every invocation resolves and builds
before executing; both xctestrun formats receive the pinned testing runtime.
Runtime warning counts come from the summary array length.
`--preserve-work-root` and `--reuse-work-root` retain a harness-created source
directory so its compilation path stays stable. Reuse requires an absolute,
non-symlink root with the current user's ownership marker and an exclusive
run lock. Every run synchronizes current source and builds for testing; it
records compiler, traits, source and manifest/pin digests. Source and pin
changes during a run fail verification. Cache retention never skips a build,
and cleanup never deletes an unowned or preserved root. DerivedData has its
own ownership marker bound to that work root. A compiler, normalized manifest,
trait, or input-pin change invalidates only that owned cache before rebuilding;
an existing unmarked cache is rejected instead of adopted or deleted.

`--diagnostic-source-root` copies a prepared manifest with absolute local
package overrides into the harness-owned source directory, including for
`MultiBase`. Such results are diagnostic evidence only. The harness records
original/input manifest and pin SHA-256 values, rejects changes to either
source, and requires every dependency that remains a URL to retain its pin.
The accepted S01 workflow uses frozen local dependency copies and recorded
source/pin provenance for focused and full native evidence. S18 owns final URL
graph verification; local evidence does not satisfy that later boundary.
S01's focused operation
cases are the three new `DatabaseQueryContinuationEndpointTests` methods,
`DatabasePositionalRowEncodingTests` (two cases), and
`DatabaseWireEndpointTests/describesRichQueryTypes()`; MultiBase adds
`duplicateColumnsPreserveProvenance()` and `emptyCompositionRetainsColumns()`
in `DatabaseCompositionQueryTests`.

Rich persistence mutation failures preserve their `QueryValueError` cause.
A resource-limit cause maps to `MUTATION_LIMIT`; malformed or incompatible
values map to `INVALID_ENTITY`, without collapsing either into success.

Changes to Wire values recheck Client/CLI preservation; Framework result or
closure changes recheck this target's page owners and durable publication.
The full PostgreSQL semantic corpus stays owned by Framework, rather than
being repeated for every transport.

## S17 Complete SQL Execution

### Responsibility and Accepted Contract

`SQLExecuteHandler` dispatches the Kit-owned `SQLExecuteOperation` (`0x0202`).
Its input is original SQL text, one semantic statement, or one immutable block,
with canonical parameters and one caller execution budget. The handler invokes
the Framework block kernel once. It preserves complete outcomes in step order:
typed positional rows with optional affected-row count, request-contained COPY
bytes with affected-row count, and typed command outcomes. The SQL rows carrier
does not promise a read point, provenance, or continuation that Framework's
block result does not provide. Wire owns its encoding and shares the existing
column, row, and value codecs.

The standard graph addresses its ordinary database. The `MultiBase` graph
accepts only the existing data target, Base; Composition is rejected. A read
requirement admits the operation without asserting that its contents are
read-only. Framework derives actual read, write, and administration access from
the complete block and enforces the selected root's Grants and entity/field
policies inside the data operation. Server does not reparse SQL to infer access
or bypass a Framework authorization failure.
For a Base, persisted Grant admission precedes entity and field policies:
an anonymous principal retains the native `authentication` failure with
`AUTHENTICATION_REQUIRED` and `never` retryability. The standard graph has no
persisted Grant boundary and retains its entity-policy `authorization` failure.

The operation has one complete bounded response. Existing query continuation
and durable paging contracts remain owned by `queryExecute`. No transaction,
setting, or prepared statement survives a SQL request. Server supplies neither
automatic network replay nor an exactly-once promise. Framework retains its
existing conflict-retry and sequence-demand replay semantics; another request
can repeat committed effects.

### Provisional Projection and Closure

```text
authenticated Wire request -> runtime budget and target admission
  -> Framework block kernel -> collecting outcomes and exact claims
  -> synchronous borrowed provisional projection
       -> Wire measures the complete success frame
       -> same request meter admits frame bytes before allocation
       -> Wire encodes one frame into a Framework-owned payload/claim token
  -> authoritative data commit or rollback -> schema publication
  -> sequence/resource closure -> cancellation gate -> ready frame
  -> prepared DatabaseOperationResult -> endpoint returns the same frame
```

The projection receives a Framework-created noncopyable provisional view,
not a public `SQLBlockResult`, a Ready owner, raw row arrays, or a transaction.
Its synchronous borrows permit only measurement and encoding. It performs no
transport, control-storage, or publication I/O. The Framework owns the encoded
frame and its exact intermediate reservation together until complete closure.
The callback cannot manufacture readiness or detach the reservation. Framework
imports no Wire implementation and continues to own all data execution.

The encoded response is prepared before the checkpoint transaction callback
returns, so frame or structural overflow aborts transactional data, catalog,
and index effects. Deferred validation, commit-unknown, or mandatory cleanup
failure discards the prepared success. Independently committed sequence
consumption retains the existing nonrollback sequence contract. A failure
after commit is never described as proof of rollback. Explicit terminal
ROLLBACK returns the block's admitted observations only after rollback/close.
Cancellation during an already dispatched commit awaits its authoritative
outcome. If that commit succeeds, its data and catalog changes remain committed;
the final cancellation check still discards the prepared response before Ready.

Rows are charged once by the Framework execution owner. Server adds the exact
encoded-frame reservation on the same meter; it does not charge output rows
again or materialize a second full result. The prepared frame reuses
`DatabaseOperationResult`'s existing frame case, so the endpoint performs no
second success encoding after commit.

### Checkpoint Policy and Failure Relay

`DatabaseOperationConfiguration` owns an optional validated
`TransactionCheckpointLimits` ceiling. With no explicit ceiling, each request
derives its checkpoint limits from its validated work, intermediate-byte,
intermediate-row, and structural collection bounds. An explicit ceiling can
only reduce those derived bounds. Checked integer conversion precedes kernel
invocation. The caller cannot raise a runtime or checkpoint ceiling, and no
independent unvalidated tuning constant is introduced.

`SQLExecutionFailure` retains its original native cause. Error adaptation
preserves the underlying remote category, code, retryability, and mandatory
cleanup distinctions, and attaches the Kit-owned diagnostic through Wire's
typed diagnostic namespace. Original text retains one-based Unicode-scalar
positions; semantic input receives no fabricated source position. Only a
direct underlying `CancellationError` is rethrown as transport cancellation.
A cleanup composite containing cancellation remains a typed failure rather
than losing its cleanup cause. Existing bounded failure-envelope fallback
continues to apply when diagnostics themselves exceed response limits.

The operation remains inside `DatabaseOperationInstance` admission from
projection through authoritative closure. Timeout and disconnect cancellation
await cleanup; shutdown rejects new work and drains this same boundary before
container shutdown. The synchronous projection holds no mutex over callbacks
and introduces no shared mutable request or session state.

### Falsifiable Server Evidence

| Case | Required behavior through the real handler |
|---|---|
| S17-SRV01 | Original text, semantic statement, and block reach the one kernel; ordered DDL, DML RETURNING, COPY, and command outcomes survive Wire decoding and backend readback. |
| S17-SRV02 | Exact-fit complete frame succeeds; one-byte oversize fails before commit and transactional backend/catalog readback proves rollback. |
| S17-SRV03 | First-error blocks publish no earlier result; explicit ROLLBACK preserves observations while backend effects are absent. |
| S17-SRV04 | Principal and field-policy denial, read-only execution failure, and Base access rejection retain typed failures; a read admission requirement cannot grant write or administration authority. |
| S17-SRV05 | Text Unicode/CRLF diagnostic positions and semantic no-position outcomes preserve typed SQLSTATE and underlying failure classification. |
| S17-SRV06 | A gate selects the checkpoint-enabled mutating SQL transaction's commit, after its callback has prepared the response. Cancellation there returns no success response after authoritative close, while independent readback confirms the committed row; shutdown waits for this same commit before draining. Framework owns frame-claim release evidence. |
| S17-SRV07 | Capabilities and handler inventory agree in standard and MultiBase graphs; Composition rejects SQL execution and existing query paging remains unchanged. |

Framework owns evaluator, checkpoint, deferred-constraint, sequence, and
projection-lifetime behavior. Kit owns deterministic malformed/limit codecs.
Server tests prove their dispatch, authority, output-admission, diagnostic, and
lifecycle composition; native transport tests prove authenticated delivery.

### S03 continuation parameter identity

A durable query continuation identifies the canonical admitted statement and
its supplied parameter declarations and values. The fingerprint normalizes the
statement into QueryIR and removes only continuation bytes; it preserves each
parameter's position, optional name, optional type, and canonical value through
DatabaseWire encoding. SQL admission retains parameter references, so clearing
parameters would incorrectly equate distinct executions. An unchanged request
can resume its saved result; a changed parameter value, declared type, or name
rejects that continuation before returning rows. SPARQL substitution retains
its admitted statement and the same supplied parameter identity.

### S04 selected numeric failure mapping

QueryExecution owns selected numeric arithmetic failures through
`CanonicalReadError.expressionEvaluation` with its optional decisive Kit
occurrence. Local SQL source annotation remains Database-owned; S16 owns
remote occurrence details. Runtime maps zero division,
numeric overflow/underflow, nonfinite input and numeric-domain rejection to
distinct invalid-request codes without converting resource/cancellation errors
into arithmetic errors. SQLSTATE and remote occurrence details remain S16.

### S05 pattern failure mapping

Framework owns `invalidPattern(offset:reason:)`,
`unsupportedPattern(offset:reason:)`, and
`invalidFunctionArgument(function:reason:)`. Runtime maps these to
`INVALID_PATTERN`, `UNSUPPORTED_PATTERN`, and `INVALID_FUNCTION_ARGUMENT`
invalid-request codes with no retry, for both raw mutation expressions and
canonical read expression failures. Pattern offsets remain pattern-local;
SQLSTATE and remote SQL occurrence details remain S16-owned. Work limits and
cancellation keep their existing mapping.

```text
Framework typed expression failure -> Runtime error mapper -> Wire error
```

[DatabaseErrorMapperTests](../../Tests/DatabaseServerRuntimeTests/DatabaseErrorMapperTests.swift)
checks the three distinct codes, messages, category, and retry policy.


### S06 temporal failures

DatabaseErrorMapper preserves Framework invalid-temporal-input, temporal-range,
typed time-zone cause and missing-environment failures, including the existing
source-position wrapper. No temporal malformed/unsupported/resource failure
becomes empty rows, NULL or a retryable success. Numeric nonfinite output keeps
its existing profile failure. Owning tests check direct and wrapped mappings;
SchemaOperations separately owns durable opaque source-scope relay.

### S07 collection failures

Framework's [selected collection owner](../../../database-framework/Sources/DatabaseEngine/QueryExecution/DESIGN.md#typed-collection-failures)
owns SQLCollectionError and its DatabaseExpressionEvaluationError.collection
wrapper. Runtime maps that wrapper directly and through canonical source
failure wrappers to invalidRequest, code INVALID_COLLECTION_ARGUMENT,
retryability never, preserving the English cause description. Intrinsic
malformed/limit, cancellation and work failures keep their existing mappings;
no failure becomes NULL or a successful empty response. SQLSTATE remains S16.
The queryValue(QueryValueError) expression wrapper maps to INVALID_QUERY_VALUE,
invalidRequest and never retry, preserving the original cause through source
wrappers without relying on runtime reflection for its description.
DatabaseErrorMapperTests must exercise direct/wrapped array and JSON causes and
retain existing temporal/pattern mappings. Server's unrelated user changes are
not prerequisites for this mapping or its verification graph.

### S08 canonical relational and composite carriage

Runtime consumes [canonical QueryIR](../../../database-kit/Sources/DatabaseKit/Query/DESIGN.md#s08-frozen-relational-query-carriage)
and [result-only composite values](../../../database-kit/Sources/DatabaseKit/Query/SQL/DESIGN.md#s08-frozen-composite-values-and-ownership)
through DatabaseWire. Framework's [selected execution contract](../../../database-framework/Sources/DatabaseEngine/QueryExecution/DESIGN.md#s08-frozen-relational-execution)
owns query meaning and authorization. Runtime preserves the admitted query and
parameter values, including expression pagination; request page limits bound
response paging through ReadExecutionOptions rather than rewriting query
pagination. Existing complete-row staging and continuation ownership remain
unchanged. Runtime does not flatten composite fields into model persistence or
replace unsupported, denied or resource-limited execution with empty success.

The migrated statement-admission, continuation, budget, Composition and SPARQL
tests exercise the canonical declarations through the existing handlers. Kit's
Wire tests own descriptor/value encoding, and Framework's SQL tests own the
relational results; the complete Server package run checks their composition.

### S11 SQL catalog failure mapping

Framework's [SQLCatalog](../../../database-framework/Sources/DatabaseEngine/SQLCatalog/DESIGN.md)
owns name resolution, backing validation, and compatibility. Runtime maps its
typed failures directly and through `CanonicalSQLBindingFailure` and
`SQLBindingSourceFailure` using the existing bounded mapping recursion.

| Framework failure | Remote category / code |
|---|---|
| Missing requested namespace / relation | `notFound` / `SQL_NAMESPACE_NOT_FOUND`, `SQL_RELATION_NOT_FOUND` |
| Missing entity, runtime, or field; runtime contract mismatch; missing physical projection column | `internalFailure` / `SQL_CATALOG_MAPPING_INVALID` |
| Fingerprint or digest mismatch, invalid protection or SQL ownership, missing catalog | `internalFailure` / `SQL_CATALOG_INVALID` |
| Protected relation/column/key/constraint/policy/sequence removal or change; protected physical column addition; relation/column retargeting; removed primary-key column | `conflict` / `SQL_CATALOG_INCOMPATIBLE` |
| Read resolution generation mismatch | `conflict` / `SQL_READ_GENERATION_STALE` |

All mappings use `never` retryability: replaying the same admitted generation
cannot repair its contract. Messages are fixed English descriptions and never
include associated entity, runtime, namespace, relation, field, column, or
protection identifiers. Canonical wrappers preserve category, code, message,
and retryability; source wrappers additionally preserve a valid exact byte
`position`, including a mapping-depth failure. Unannotated wrappers do not
invent a position. No failure becomes empty success. This adaptation does not
add catalog administration dispatch; SQLSTATE remains S16-owned.

[DatabaseErrorMapperTests/databaseQueryExecutionFailures](../../Tests/DatabaseServerRuntimeTests/DatabaseErrorMapperTests.swift)
checks the original catalog/resolution cases directly and through both wrappers,
sanitized messages, retry policy, source position, and the recursion bound.
`SQLExecuteHandlerTests.diagnosticPreservesUnderlyingMapping` additionally checks
invalid SQL ownership and protected constraint, column policy, physical column
addition, and sequence changes directly and through `SQLExecutionFailure`.
The native category and code remain authoritative while the wrapper retains
Framework's diagnostic classification without inventing a source position.
