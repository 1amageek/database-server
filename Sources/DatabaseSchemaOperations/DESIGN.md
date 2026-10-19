# DatabaseSchemaOperations

## Purpose and Scope

This internal Server module owns schema-operation orchestration, schema-change
analysis, runtime-factory invocation and durable schema-apply job plans/state.
Parent: [Database Server](../../DESIGN.md). Children: none. It is an internal
module, not a supported reusable package product. Framework owns schema
execution, Directory resolution, physical index work and transactions.

## Responsibilities and Boundaries

The module records the admitted schema job inputs and delegates execution to the
Framework runtime. It persists enough Framework-owned work metadata to resume
builds and retirements after restart. It does not reinterpret temporal values,
index ordering, source Directory identity or the schema authority that issued
that work. Application runtime factories retain their existing ownership.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Server](../../DESIGN.md) | parent | Internal schema-operation and durable job boundary | Composes this module. | User host configuration is not changed by job metadata adaptation. |
| [Server Runtime](../DatabaseServerRuntime/DESIGN.md) | coordinates with | Admitted operation and job dispatch | Invokes schema-operation orchestration. | Preserve control/data transaction separation. |
| [Framework Index](../../../database-framework/Sources/DatabaseEngine/Index/DESIGN.md) | depends on | DatabaseIndexStorageScope and opaque scope codec | Owns physical work and source Directory descriptors. | The Server never reconstructs SQL descriptor meaning. |
| [Framework Directory](../../../database-framework/Sources/DatabaseEngine/Directory/DESIGN.md) | depends on | Total canonical Directory resolution | Resolves retained source partition values. | The target/current schema cannot replace the captured source metadata. |
| [Framework schema protection](../../../database-framework/Sources/DatabaseEngine/Schema/DESIGN.md#compiled-model-protection-and-application-evolution) | depends on | Compiled-model protection and application evolution authority | Preserves the S11-C07 static contract across schema-driven restoration. | Remote schema jobs cannot regenerate an application's compiled witness. |

## Architecture

```text
admitted schema operation
  -> DatabaseSchemaApplyJobPlan + state in control storage
      -> opaque Framework scope bytes + exact work identity
          -> restart/resume
              -> Framework build/retire execution in data transaction
                  -> durable completion in control storage
```

## Contracts and Invariants

`DatabaseSchemaApplyJobPlan` retains each Framework index scope as bounded opaque
bytes produced by `DatabaseIndexStorageScopeCodec`. The Framework scope carries
the source Directory components and only the dynamic-field descriptors needed
to resolve them after source entity deletion. Server metadata does not become a
second Directory/schema authority. The complete scope participates in plan
identity and replay validation.

S06 updates the single schema-apply durable format from11 to12 coherently with
Framework scope encoding. There is no legacy alias or fallback to the currently
published schema. A scope decode failure remains an explicit typed persistent
job failure; it cannot become an empty scope, skipped retirement or successful
completion. The Server neither derives temporal sentinels nor examines SQL
extension object keys. Existing application-owned runtime factory and user host
configuration files remain outside this change.

## Runtime Flows

A job captures the Framework work scope at its existing schema-generation
boundary, persists the plan, executes bounded slices, and resumes from that
exact plan after restart. A target schema may remove the source entity;
retirement still resolves through the old source descriptors retained in the
scope. `DatabaseDataOperationExecutor` relays the retirement-specific partition
page API, and only the retiring branch of `DatabaseSchemaApplyResumableOperation`
uses it. Build paging keeps its existing current-schema contract. Data execution completes before control-storage completion is recorded.

## State, Ownership, and Lifecycle

The durable plan owns its scope bytes. Framework decode reconstructs the
immutable execution scope and validates all metadata before Directory/index
work. Existing job-state ownership, cancellation, idempotency, process lifecycle
and transaction boundaries are unchanged.

## Failure, Concurrency, and Constraints

Malformed, incomplete, mismatched or unsupported scope bytes fail through
`PersistentJobPayloadError` with the Framework cause boundary preserved. The
existing bounded codec and job payload limits apply. No new mutable shared state,
service, credential or synchronization path is introduced.

## Verification and Change Impact

The existing `SchemaIndexJobRestartSQLiteTests.pendingBuildResumesAfterRestart()`
scenario additionally proves a schema-apply plan round trip, then a separate
Framework migration publication and SQLite restart with SQL infinity/TIME24
partition scope, source-entity deletion, and authoritative retirement. The
normal Server apply migration-required gate is preserved. Assertions retain exact original payloads and source descriptors;
corrupt metadata must fail rather than bind a target/current schema. Framework
codec tests own byte/metadata validation; Framework Directory/index tests own
canonical components and temporal key order. Server host configuration and
unrelated operation behavior remain separate proof subjects.

Schema/index-administration fixtures start with schema-driven runtime
registration and retain that ownership through target publication and restart.
Their `Persistable` declarations supply schema and encoded fixture data; they
do not register a compiled runtime witness. This lets the tests exercise index
backfill, physical-layout rejection, cancellation, retirement, reversal, and
restart under the authority they actually invoke. Dynamic runtime registration
is distinct from a dynamic Directory component: partition backfill still
uses the declared `.partition` Directory and every original partition/data
assertion. Framework's S11 compiled-protection tests separately prove that a
schema-driven target cannot weaken a persisted compiled contract.


### Logical SQL policy factory forwarding

`SchemaDrivenDatabaseRuntimeFactory` forwards the optional
`sqlAuthorizationPolicyFactory` to
[Framework runtime composition](../../../database-framework/Sources/DatabaseEngine/DESIGN.md).
Framework alone resolves SQL-owned entities and supplies the current namespace
and public relation name (including visible materialized-view names). The Server factory neither derives physical names nor binds policy
to non-SQL entities. Existing `authorizationPolicies` forwarding remains intact.
The native host always supplies a logical factory, even for absent configuration,
so missing logical rules deny. Framework owns policy rebinding during schema
publication, rollback and reopen; native host integration tests prove this
factory is used by production application composition.
