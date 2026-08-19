@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
import DatabaseSchemaOperations
import DatabaseServerFoundation
import DatabaseTypes
import DatabaseWire
import StorageKit
import TestSupport
import Testing

@testable import DatabaseEngine
@testable import DatabaseServerRuntime

@Persistable
private struct SchemaExecuteAccount {
    #Directory<SchemaExecuteAccount>("schema-execute", "accounts")
    #Index(
        .ordered(
            name: "schema_execute_account_email",
            keys: [.ascending(\SchemaExecuteAccount.email)]
        ))

    var id: String = ""
    var email: String = ""
}

@Persistable(type: "SchemaBuildAccount")
private struct SchemaBuildAccountV1 {
    #Directory<SchemaBuildAccountV1>("schema-execute", "build-accounts")

    var id: String = ""
    var email: String = ""
}

@Persistable(type: "SchemaBuildAccount")
private struct SchemaBuildAccountV2 {
    #Directory<SchemaBuildAccountV2>("schema-execute", "build-accounts")
    #Index(
        .ordered(
            name: "schema_build_account_email",
            keys: [.ascending(\SchemaBuildAccountV2.email)]
        ))

    var id: String = ""
    var email: String = ""
}

@Persistable(type: "SchemaBuildAccount")
private struct SchemaBuildAccountV3 {
    #Directory<SchemaBuildAccountV3>("schema-execute", "build-accounts")
    #Index(
        .ordered(
            name: "schema_build_account_email",
            keys: [.descending(\SchemaBuildAccountV3.email)]
        ))

    var id: String = ""
    var email: String = ""
}

@Persistable(type: "SchemaBuildTenantAccount")
private struct SchemaBuildTenantAccountV1 {
    #Directory<SchemaBuildTenantAccountV1>(
        "schema-execute",
        "tenants",
        \SchemaBuildTenantAccountV1.tenantID,
        "accounts",
        layer: .partition
    )

    var id: String = ""
    var tenantID: String = ""
    var email: String = ""
}

@Persistable(type: "SchemaBuildTenantAccount")
private struct SchemaBuildTenantAccountV2 {
    #Directory<SchemaBuildTenantAccountV2>(
        "schema-execute",
        "tenants",
        \SchemaBuildTenantAccountV2.tenantID,
        "accounts",
        layer: .partition
    )
    #Index(
        .ordered(
            name: "schema_build_tenant_account_email",
            keys: [.ascending(\SchemaBuildTenantAccountV2.email)]
        ))

    var id: String = ""
    var tenantID: String = ""
    var email: String = ""
}

private struct LayoutVersionedScalarIndexMaintainerProvider:
    IndexMaintainerProvider
{
    let indexType: IndexType = .ordered
    let revision: UInt32

    private let base = ScalarIndexMaintainerProvider()

    var physicalEntryCapabilities: IndexPhysicalEntryCapabilities? {
        base.physicalEntryCapabilities
    }

    var supportsUniquenessConstraints: Bool {
        base.supportsUniquenessConstraints
    }

    func physicalLayout(
        for index: ResolvedIndex,
        configurations: [any IndexRuntimeConfiguration]
    ) throws -> IndexPhysicalLayout {
        guard configurations.isEmpty else {
            throw IndexMaintainerProviderError.unhandledRuntimeConfiguration(
                indexType: indexType,
                indexName: index.name
            )
        }
        return try IndexPhysicalLayout(
            name: "test.layout-versioned-scalar",
            revision: revision
        )
    }

    func makeIndexMaintainer<Item: PersistedEntityValue>(
        index: ResolvedIndex,
        subspace: Subspace,
        idExpression: KeyExpression,
        configurations: [any IndexRuntimeConfiguration],
        wallClock: any WallClock
    ) throws -> any IndexMaintainer<Item> {
        try base.makeIndexMaintainer(
            index: index,
            subspace: subspace,
            idExpression: idExpression,
            configurations: configurations,
            wallClock: wallClock
        )
    }

    func makeIndexUniquenessMaintainer<Item: PersistedEntityValue>(
        index: ResolvedIndex,
        subspace: Subspace,
        idExpression: KeyExpression,
        configurations: [any IndexRuntimeConfiguration]
    ) throws -> any IndexUniquenessMaintainer<Item> {
        try base.makeIndexUniquenessMaintainer(
            index: index,
            subspace: subspace,
            idExpression: idExpression,
            configurations: configurations
        )
    }
}

private actor LayoutChangingSchemaRuntimeFactory:
    DatabaseSchemaRuntimeFactory
{
    private var invocationCount = 0

    func makeOperationConfiguration(
        for schema: Schema
    ) async throws -> DatabaseRuntimeConfiguration {
        invocationCount += 1
        return try layoutVersionedRuntimeConfiguration(
            schema: schema,
            revision: invocationCount >= 3 ? 2 : 1
        )
    }
}

private struct FixedLayoutSchemaRuntimeFactory: DatabaseSchemaRuntimeFactory {
    let revision: UInt32

    func makeOperationConfiguration(
        for schema: Schema
    ) async throws -> DatabaseRuntimeConfiguration {
        try layoutVersionedRuntimeConfiguration(
            schema: schema,
            revision: revision
        )
    }
}

private actor QueryPolicyChangingSchemaRuntimeFactory:
    DatabaseSchemaRuntimeFactory
{
    private var invocationCount = 0

    func makeOperationConfiguration(
        for schema: Schema
    ) async throws -> DatabaseRuntimeConfiguration {
        invocationCount += 1
        let provider = QueryTunedScalarIndexMaintainerProvider()
        var registrations: [EntityRuntimeRegistration] = []
        registrations.reserveCapacity(schema.entities.count)
        for entity in schema.entities {
            var definition = EntityRuntimeDefinition(schemaDriven: entity)
            try definition.register(provider)
            registrations.append(definition.registration())
        }
        let configuredIndex = schema.indexDescriptors.first {
            $0.type == .ordered
        }
        let configurations: [any IndexRuntimeConfiguration]
        if let configuredIndex {
            configurations = [
                QueryTunedScalarIndexConfiguration(
                    indexName: configuredIndex.name,
                    searchBudget: invocationCount.isMultiple(of: 2) ? 40 : 10
                )
            ]
        } else {
            configurations = []
        }
        return try DatabaseRuntimeConfiguration(
            executionIdentity: DatabaseExecutionRuntimeIdentity(
                identifier: "database-tests",
                revision: 1
            ),
            indexMaintainerProviderDescriptors: [
                IndexMaintainerProviderDescriptor(describing: provider)
            ],
            entityRuntimes: registrations,
            indexConfigurations: configurations
        )
    }
}

private struct QueryTunedScalarIndexConfiguration:
    IndexRuntimeConfiguration
{
    static let indexType: IndexType = .ordered

    let indexName: String
    let searchBudget: Int

    var executionOptions: FieldObject {
        get throws {
            try FieldObject([
                ("searchBudget", .int64(Int64(searchBudget)))
            ])
        }
    }
}

private struct QueryTunedScalarIndexMaintainerProvider:
    IndexMaintainerProvider
{
    let indexType: IndexType = .ordered
    private let base = ScalarIndexMaintainerProvider()

    var physicalEntryCapabilities: IndexPhysicalEntryCapabilities? {
        base.physicalEntryCapabilities
    }

    var supportsUniquenessConstraints: Bool {
        base.supportsUniquenessConstraints
    }

    func physicalLayout(
        for index: ResolvedIndex,
        configurations: [any IndexRuntimeConfiguration]
    ) throws -> IndexPhysicalLayout {
        _ = configurations
        return try base.physicalLayout(for: index, configurations: [])
    }

    func makeIndexMaintainer<Item: PersistedEntityValue>(
        index: ResolvedIndex,
        subspace: Subspace,
        idExpression: KeyExpression,
        configurations: [any IndexRuntimeConfiguration],
        wallClock: any WallClock
    ) throws -> any IndexMaintainer<Item> {
        _ = configurations
        return try base.makeIndexMaintainer(
            index: index,
            subspace: subspace,
            idExpression: idExpression,
            configurations: [],
            wallClock: wallClock
        )
    }

    func makeIndexUniquenessMaintainer<Item: PersistedEntityValue>(
        index: ResolvedIndex,
        subspace: Subspace,
        idExpression: KeyExpression,
        configurations: [any IndexRuntimeConfiguration]
    ) throws -> any IndexUniquenessMaintainer<Item> {
        _ = configurations
        return try base.makeIndexUniquenessMaintainer(
            index: index,
            subspace: subspace,
            idExpression: idExpression,
            configurations: []
        )
    }
}

private func layoutVersionedRuntimeConfiguration(
    schema: Schema,
    revision: UInt32
) throws -> DatabaseRuntimeConfiguration {
    let provider = LayoutVersionedScalarIndexMaintainerProvider(
        revision: revision
    )
    var registrations: [EntityRuntimeRegistration] = []
    registrations.reserveCapacity(schema.entities.count)
    for entity in schema.entities {
        var definition = EntityRuntimeDefinition(schemaDriven: entity)
        try definition.register(provider)
        registrations.append(definition.registration())
    }
    return try DatabaseRuntimeConfiguration(
        executionIdentity: DatabaseExecutionRuntimeIdentity(
            identifier: "database-tests",
            revision: 1
        ),
        indexMaintainerProviderDescriptors: [
            IndexMaintainerProviderDescriptor(describing: provider)
        ],
        entityRuntimes: registrations
    )
}

@Suite("Schema execute runtime", .serialized)
struct SchemaExecuteHandlerTests {
    @Test("Schema job plan rejects an exact build and retirement overlap")
    func schemaJobPlanRejectsExactBuildRetirementOverlap() throws {
        let schema = try Schema(
            entities: [try SchemaBuildAccountV2.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let manifest = SchemaManifest(schema: schema)
        let fingerprint = try manifest.fingerprint()
        let descriptor = try #require(
            schema.indexDescriptors.first {
                $0.name == "schema_build_account_email"
            }
        )
        let entity = try #require(
            schema.entity(named: descriptor.entityName)
        )
        let layout = try IndexPhysicalLayout(
            name: "test.ordered",
            revision: 1
        )
        let target = try DatabaseIndexTransitionPlan.Target(
            scope: .entity(
                name: descriptor.entityName,
                directoryComponents: entity.directoryComponents
            ),
            identity: try DatabaseIndexStorageIdentity(
                name: descriptor.name,
                definitionFingerprint: try SchemaManifest.indexFingerprint(
                    descriptor
                ),
                layoutFingerprint: layout.fingerprint
            )
        )
        #if DATABASE_SERVER_MULTI_BASE
        let dataTarget = DatabaseSchemaApplyJobPlan.DataTarget(
            resource: .database,
            generation: 0
        )
        #else
        let dataTarget = DatabaseSchemaApplyJobPlan.DataTarget(generation: 0)
        #endif

        #expect(throws: DatabaseSchemaApplyJobError.corruptedPlan) {
            _ = try DatabaseSchemaApplyJobPlan(
                previousFingerprint: fingerprint,
                targetFingerprint: fingerprint,
                indexPhysicalFingerprint: ByteString(
                    repeating: 0,
                    count: SHA256Accumulator.digestByteCount
                ),
                manifest: manifest,
                idempotencyKey: "exact-target-overlap",
                dataTargets: [dataTarget],
                indexBuilds: [target],
                indexRetirements: [target],
                maximumWorkUnitsPerSlice: 1
            )
        }
    }

    @Test("plan, apply, replay, and request generation leases are coherent")
    func planApplyReplayAndLease() async throws {
        let initialSchema = try Schema(
            entities: [],
            version: Schema.Version(0, 0, 0)
        )
        let targetSchema = try Schema(
            entities: [try SchemaExecuteAccount.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let container = try await makeContainer(schema: initialSchema)
        defer { await container.shutdown() }
        let runtime = try await makeRuntime(container: container)
        let initialFingerprint = container.schemaFingerprint
        let targetManifest = SchemaManifest(schema: targetSchema)

        let capabilities = try await invoke(
            DatabaseOperationCatalog.capabilitiesDescribe,
            request: EmptyOperationPayload(),
            requestID: 1,
            runtime: runtime
        )
        #expect(capabilities.features.contains {
            $0.identifier == "schema.execute" && $0.version == 1
        })

        let planResponse = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .plan(
                    manifest: targetManifest,
                    expectedFingerprint: initialFingerprint
                )
            ),
            requestID: 2,
            runtime: runtime
        )
        guard case .plan(let plan) = planResponse else {
            Issue.record("Expected a schema plan response")
            return
        }
        let targetFingerprint = try targetManifestFingerprint(targetManifest)
        #expect(plan.currentFingerprint == initialFingerprint)
        #expect(plan.targetFingerprint == targetFingerprint)
        #expect(plan.compatibility == .initial)
        #expect(plan.issues.isEmpty)

        let accepted = try await container.withSchemaLease { lease in
            #expect(lease.schema == initialSchema)
            let response = try await invoke(
                DatabaseOperationCatalog.schemaExecute,
                request: SchemaExecuteOperation.Request(
                    invocation: .apply(
                        manifest: targetManifest,
                        expectedFingerprint: initialFingerprint,
                        idempotencyKey: "schema-apply-1"
                    )
                ),
                requestID: 3,
                runtime: runtime
            )
            #expect(container.schema == initialSchema)
            return response
        }
        guard case .accepted(let job) = accepted else {
            Issue.record("Expected an accepted schema transition job")
            return
        }
        #expect(container.schema == initialSchema)
        let status = try await runUntilTerminal(
            job,
            runtime: runtime,
            firstRequestID: 4
        )
        #expect(status.state == .succeeded)
        let publication = try await schemaApplyResult(
            job,
            runtime: runtime,
            requestID: 80
        )
        #expect(container.schema == targetSchema)
        #expect(container.schemaGeneration == publication.generation)

        let replay = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: targetManifest,
                    expectedFingerprint: initialFingerprint,
                    idempotencyKey: "schema-apply-1"
                )
            ),
            requestID: 81,
            runtime: runtime
        )
        #expect(replay == accepted)

        let description = try await invoke(
            DatabaseOperationCatalog.schemaDescribe,
            request: EmptyOperationPayload(),
            requestID: 82,
            runtime: runtime
        )
        #expect(description.version == targetSchema.version)
        #expect(description.entities.map(\.name) == [SchemaExecuteAccount.persistableType])
    }

    @Test("Schema publication preserves an already acquired generation lease")
    func publicationPreservesStaleRequestLease() async throws {
        let initialSchema = try Schema(
            entities: [],
            version: Schema.Version(0, 0, 0)
        )
        let firstSchema = try Schema(
            entities: [try SchemaExecuteAccount.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let secondSchema = try schemaAddingOptionalField(to: firstSchema)
        let container = try await makeContainer(schema: initialSchema)
        defer { await container.shutdown() }
        let runtime = try await makePersistentRuntime(container: container)
        let initialFingerprint = container.schemaFingerprint.detached()
        let firstManifest = SchemaManifest(schema: firstSchema)
        let firstFingerprint = try firstManifest.fingerprint()
        let secondManifest = SchemaManifest(schema: secondSchema)

        let firstPublication = try await container.withSchemaLease { lease in
            #expect(lease.schema == initialSchema)
            let response = try await invoke(
                DatabaseOperationCatalog.schemaExecute,
                request: SchemaExecuteOperation.Request(
                    invocation: .apply(
                        manifest: firstManifest,
                        expectedFingerprint: initialFingerprint,
                        idempotencyKey: "stale-lease-first"
                    )
                ),
                requestID: 6,
                runtime: runtime
            )
            guard case .accepted(let job) = response else {
                throw SchemaExecuteHandlerTestError.expectedAcceptedJob
            }
            #expect(container.schema == initialSchema)
            let status = try await runUntilTerminal(
                job,
                runtime: runtime,
                firstRequestID: 90
            )
            #expect(status.state == .succeeded)
            #expect(lease.schema == initialSchema)
            #expect(container.schema == initialSchema)
            return try await schemaApplyResult(
                job,
                runtime: runtime,
                requestID: 91
            )
        }
        #expect(container.schema == firstSchema)

        let secondResponse = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: secondManifest,
                    expectedFingerprint: firstFingerprint,
                    idempotencyKey: "stale-lease-second"
                )
            ),
            requestID: 7,
            runtime: runtime
        )
        guard case .accepted(let secondJob) = secondResponse else {
            Issue.record("Expected the second schema transition job")
            return
        }
        let secondStatus = try await runUntilTerminal(
            secondJob,
            runtime: runtime,
            firstRequestID: 92
        )
        #expect(secondStatus.state == .succeeded)
        let secondPublication = try await schemaApplyResult(
            secondJob,
            runtime: runtime,
            requestID: 93
        )

        #expect(container.schema == secondSchema)
        #expect(container.schemaFingerprint == secondPublication.fingerprint)
        #expect(firstPublication.fingerprint == firstFingerprint)
        #expect(secondPublication.previousFingerprint == firstFingerprint)
    }

    @Test("An old idempotency replay never republishes an obsolete generation")
    func oldIdempotencyReplayDoesNotRollBackGeneration() async throws {
        let initialSchema = try Schema(
            entities: [],
            version: Schema.Version(0, 0, 0)
        )
        let firstSchema = try Schema(
            entities: [try SchemaExecuteAccount.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let secondSchema = try schemaAddingOptionalField(to: firstSchema)
        let container = try await makeContainer(schema: initialSchema)
        defer { await container.shutdown() }
        let runtime = try await makeRuntime(container: container)
        let initialFingerprint = container.schemaFingerprint.detached()
        let firstManifest = SchemaManifest(schema: firstSchema)
        let firstFingerprint = try firstManifest.fingerprint()
        let secondManifest = SchemaManifest(schema: secondSchema)
        let secondFingerprint = try secondManifest.fingerprint()

        let firstResponse = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: firstManifest,
                    expectedFingerprint: initialFingerprint,
                    idempotencyKey: "obsolete-generation-first"
                )
            ),
            requestID: 8,
            runtime: runtime
        )
        guard case .accepted(let firstJob) = firstResponse else {
            Issue.record("Expected the first schema transition job")
            return
        }
        #expect(
            try await runUntilTerminal(
                firstJob,
                runtime: runtime,
                firstRequestID: 100
            ).state == .succeeded
        )
        let first = try await schemaApplyResult(
            firstJob,
            runtime: runtime,
            requestID: 101
        )
        let secondResponse = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: secondManifest,
                    expectedFingerprint: firstFingerprint,
                    idempotencyKey: "obsolete-generation-second"
                )
            ),
            requestID: 9,
            runtime: runtime
        )
        guard case .accepted(let secondJob) = secondResponse else {
            Issue.record("Expected the second schema transition job")
            return
        }
        #expect(
            try await runUntilTerminal(
                secondJob,
                runtime: runtime,
                firstRequestID: 102
            ).state == .succeeded
        )
        let second = try await schemaApplyResult(
            secondJob,
            runtime: runtime,
            requestID: 103
        )
        let replayResponse = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: firstManifest,
                    expectedFingerprint: initialFingerprint,
                    idempotencyKey: "obsolete-generation-first"
                )
            ),
            requestID: 10,
            runtime: runtime
        )

        #expect(replayResponse == firstResponse)
        #expect(container.schema == secondSchema)
        #expect(container.schemaFingerprint == secondFingerprint)
        #expect(container.schemaGeneration == second.generation)
        #expect(second.generation > first.generation)
    }

    @Test("fingerprint conflict and migration requirement remain typed failures")
    func failuresAreTyped() async throws {
        let initialSchema = try Schema(
            entities: [try SchemaExecuteAccount.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let container = try await makeContainer(schema: initialSchema)
        defer { await container.shutdown() }
        let runtime = try await makeRuntime(container: container)
        let wrongFingerprint = try SchemaManifest(
            schema: try Schema(entities: [], version: .init(0, 0, 0))
        ).fingerprint()

        let conflictingBytes = try await execute(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .plan(
                    manifest: SchemaManifest(schema: initialSchema),
                    expectedFingerprint: wrongFingerprint
                )
            ),
            requestID: 11,
            runtime: runtime
        )
        let conflicting = try DatabaseWireDecoder().decodeResponse(
            DatabaseOperationCatalog.schemaExecute,
            from: conflictingBytes,
            matching: 11
        )
        guard case .failure(let conflict) = conflicting else {
            Issue.record("Expected a schema fingerprint conflict")
            return
        }
        #expect(conflict.category == .conflict)
        #expect(conflict.code == "SCHEMA_FINGERPRINT_CONFLICT")

        let requiredFieldSchema = try schemaAddingRequiredField(
            to: initialSchema
        )
        let migrationPlan = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .plan(
                    manifest: SchemaManifest(schema: requiredFieldSchema),
                    expectedFingerprint: container.schemaFingerprint
                )
            ),
            requestID: 12,
            runtime: runtime
        )
        guard case .plan(let plan) = migrationPlan else {
            Issue.record("Expected a migration plan")
            return
        }
        #expect(plan.compatibility == .requiresMigration)
        #expect(plan.issues.contains { $0.code == "required-field-added" })
    }

    @Test("index addition publishes write-only state and completes through its atomic persistent job")
    func indexAdditionUsesPersistentBuildJob() async throws {
        let initialSchema = try Schema(
            entities: [try SchemaBuildAccountV1.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let targetSchema = try Schema(
            entities: [try SchemaBuildAccountV2.schemaEntity],
            version: Schema.Version(2, 0, 0)
        )
        let container = try await DBContainer.open(
            for: initialSchema,
            configuration: DBConfiguration.testing(
                storageEngine: InMemoryEngine()
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        SchemaBuildAccountV1.self
                    )
                ]
            ),
            security: .testingDisabled
        )
        defer { await container.shutdown() }
        let runtime = try await makePersistentRuntime(container: container)
        let context = container.testBaseContext()
        let first = SchemaBuildAccountV1(
            id: "account-1",
            email: "first@example.com"
        )
        let second = SchemaBuildAccountV1(
            id: "account-2",
            email: "second@example.com"
        )
        try context.insert(first)
        try context.insert(second)
        try await context.save()

        let manifest = SchemaManifest(schema: targetSchema)
        let response = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: manifest,
                    expectedFingerprint: container.schemaFingerprint,
                    idempotencyKey: "schema-index-build"
                )
            ),
            requestID: 21,
            runtime: runtime
        )
        guard case .accepted(let job) = response else {
            Issue.record("Expected an accepted schema transition job")
            return
        }
        #expect(container.schema == initialSchema)

        try await runtime.runScheduledWork()
        #expect(container.schema == initialSchema)
        try await runtime.runScheduledWork()
        let building = try await indexStatus(
            container: container,
            entity: SchemaBuildAccountV2.persistableType,
            index: "schema_build_account_email"
        )
        #expect(building.indexState == .writeOnly)
        #expect(container.schema == targetSchema)

        let completed = try await runUntilTerminal(
            job,
            runtime: runtime,
            firstRequestID: 22
        )
        #expect(completed.state == .succeeded)
        #expect(container.schema == targetSchema)

        let ready = try await indexStatus(
            container: container,
            entity: SchemaBuildAccountV2.persistableType,
            index: "schema_build_account_email"
        )
        #expect(ready.indexState == .readable)
        #expect(ready.indexedEntityCount == 2)

        let replay = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: manifest,
                    expectedFingerprint: try SchemaManifest(
                        schema: initialSchema
                    ).fingerprint(),
                    idempotencyKey: "schema-index-build"
                )
            ),
            requestID: 23,
            runtime: runtime
        )
        #expect(replay == response)
    }

    @Test("Physical layout drift fails before index state staging")
    func physicalLayoutDriftPrecedesStaging() async throws {
        let initialSchema = try Schema(
            entities: [try SchemaBuildAccountV1.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let targetSchema = try Schema(
            entities: [try SchemaBuildAccountV2.schemaEntity],
            version: Schema.Version(2, 0, 0)
        )
        let container = try await DBContainer.open(
            for: initialSchema,
            configuration: DBConfiguration.testing(
                storageEngine: InMemoryEngine()
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        SchemaBuildAccountV1.self
                    )
                ]
            ),
            security: .testingDisabled
        )
        defer { await container.shutdown() }

        let store = try await container.testBaseDirectory(
            for: SchemaBuildAccountV1.self
        )
        let stagedStatePrefix =
            store
            .subspace("state")
            .subspace("schema_build_account_email")
        #expect(
            try await storedEntryCount(
                stagedStatePrefix,
                container: container
            ) == 0
        )

        let runtime = try await makePersistentRuntime(
            container: container,
            schemaRuntimeFactory: AnyDatabaseSchemaRuntimeFactory(
                LayoutChangingSchemaRuntimeFactory()
            )
        )
        let response = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: SchemaManifest(schema: targetSchema),
                    expectedFingerprint: container.schemaFingerprint,
                    idempotencyKey: "schema-layout-drift"
                )
            ),
            requestID: 20,
            runtime: runtime
        )
        guard case .accepted(let job) = response else {
            Issue.record("Expected an accepted schema transition job")
            return
        }

        let status = try await runUntilTerminal(
            job,
            runtime: runtime,
            firstRequestID: 200
        )
        #expect(status.state == .failed)
        #expect(container.schema == initialSchema)
        #expect(
            try await storedEntryCount(
                stagedStatePrefix,
                container: container
            ) == 0
        )
    }

    @Test("Query-only runtime drift does not invalidate a schema job")
    func queryOnlyRuntimeDriftKeepsPhysicalJobContract() async throws {
        let initialSchema = try Schema(
            entities: [try SchemaBuildAccountV1.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let targetSchema = try Schema(
            entities: [try SchemaBuildAccountV2.schemaEntity],
            version: Schema.Version(2, 0, 0)
        )
        let container = try await DBContainer.open(
            for: initialSchema,
            configuration: DBConfiguration.testing(
                storageEngine: InMemoryEngine()
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        SchemaBuildAccountV1.self
                    )
                ]
            ),
            security: .testingDisabled
        )
        defer { await container.shutdown() }
        let runtime = try await makePersistentRuntime(
            container: container,
            schemaRuntimeFactory: AnyDatabaseSchemaRuntimeFactory(
                QueryPolicyChangingSchemaRuntimeFactory()
            )
        )
        let response = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: SchemaManifest(schema: targetSchema),
                    expectedFingerprint: container.schemaFingerprint,
                    idempotencyKey: "schema-query-policy-drift"
                )
            ),
            requestID: 220,
            runtime: runtime
        )
        guard case .accepted(let job) = response else {
            Issue.record("Expected an accepted schema transition job")
            return
        }

        let status = try await runUntilTerminal(
            job,
            runtime: runtime,
            firstRequestID: 221
        )
        #expect(status.state == .succeeded)
        #expect(container.schema == targetSchema)
    }

    @Test("index replacement publishes a new generation and retires only the old fingerprint")
    func indexReplacementRetiresOldGeneration() async throws {
        let initialSchema = try Schema(
            entities: [try SchemaBuildAccountV2.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let targetSchema = try Schema(
            entities: [try SchemaBuildAccountV3.schemaEntity],
            version: Schema.Version(2, 0, 0)
        )
        let container = try await DBContainer.open(
            for: initialSchema,
            configuration: DBConfiguration.testing(
                storageEngine: InMemoryEngine()
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        SchemaBuildAccountV2.self
                    )
                ]
            ),
            security: .testingDisabled
        )
        defer { await container.shutdown() }
        let context = container.testBaseContext()
        try context.insert(
            SchemaBuildAccountV2(
                id: "replacement-account",
                email: "replacement@example.com"
            )
        )
        try await context.save()

        let store = try await container.testBaseDirectory(
            for: SchemaBuildAccountV2.self
        )
        let oldDescriptor = try #require(
            initialSchema.indexDescriptor(named: "schema_build_account_email")
        )
        let newDescriptor = try #require(
            targetSchema.indexDescriptor(named: "schema_build_account_email")
        )
        let oldGeneration =
            store
            .subspace(SubspaceKey.indexes)
            .subspace(oldDescriptor.name)
            .subspace(try SchemaManifest.indexFingerprint(oldDescriptor).bytes)
            .subspace(try standardIndexLayoutFingerprint())
        let newGeneration =
            store
            .subspace(SubspaceKey.indexes)
            .subspace(newDescriptor.name)
            .subspace(try SchemaManifest.indexFingerprint(newDescriptor).bytes)
            .subspace(try standardIndexLayoutFingerprint())
        #expect(try await storedEntryCount(oldGeneration, container: container) > 0)
        #expect(try await storedEntryCount(newGeneration, container: container) == 0)

        let runtime = try await makePersistentRuntime(container: container)
        let response = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: SchemaManifest(schema: targetSchema),
                    expectedFingerprint: container.schemaFingerprint,
                    idempotencyKey: "schema-index-generation-replacement"
                )
            ),
            requestID: 24,
            runtime: runtime
        )
        guard case .accepted(let job) = response else {
            Issue.record("Expected an index replacement job")
            return
        }

        var staleLease: DatabaseSchemaLease? =
            container
            .acquirePublishedSchemaLease()
        #expect(staleLease?.schema == initialSchema)
        let execution = Task {
            try await runUntilTerminal(
                job,
                runtime: runtime,
                firstRequestID: 25
            )
        }
        var targetIsBuilt = false
        for _ in 0..<10_000 {
            if container.schema == targetSchema,
                try await storedEntryCount(
                    newGeneration,
                    container: container
                ) > 0
            {
                targetIsBuilt = true
                break
            }
            await Task.yield()
        }
        #expect(targetIsBuilt)
        #expect(
            try await storedEntryCount(
                oldGeneration,
                container: container
            ) > 0
        )

        staleLease = nil
        let terminalStatus = try await execution.value
        #expect(terminalStatus.state == .succeeded)

        #expect(try await storedEntryCount(oldGeneration, container: container) == 0)
        #expect(try await storedEntryCount(newGeneration, container: container) > 0)
        #expect(
            try await indexStatus(
                container: container,
                entity: SchemaBuildAccountV3.persistableType,
                index: "schema_build_account_email"
            ).indexState == .readable
        )
    }

    @Test("Provider layout replacement builds and retires exact generations")
    func providerLayoutReplacementRetiresOldGeneration() async throws {
        let initialSchema = try Schema(
            entities: [try SchemaBuildAccountV2.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let targetSchema = try Schema(
            entities: [try SchemaBuildAccountV2.schemaEntity],
            version: Schema.Version(2, 0, 0)
        )
        let container = try await DBContainer.open(
            for: initialSchema,
            configuration: DBConfiguration.testing(
                storageEngine: InMemoryEngine()
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        SchemaBuildAccountV2.self
                    )
                ]
            ),
            security: .testingDisabled
        )
        defer { await container.shutdown() }
        let context = container.testBaseContext()
        try context.insert(
            SchemaBuildAccountV2(
                id: "layout-replacement-account",
                email: "layout-replacement@example.com"
            )
        )
        try await context.save()

        let store = try await container.testBaseDirectory(
            for: SchemaBuildAccountV2.self
        )
        let descriptor = try #require(
            initialSchema.indexDescriptor(
                named: "schema_build_account_email"
            )
        )
        let definitionFingerprint = try SchemaManifest.indexFingerprint(
            descriptor
        )
        let oldGeneration =
            store
            .subspace(SubspaceKey.indexes)
            .subspace(descriptor.name)
            .subspace(definitionFingerprint.bytes)
            .subspace(try standardIndexLayoutFingerprint())
        let replacementLayout = try IndexPhysicalLayout(
            name: "test.layout-versioned-scalar",
            revision: 1
        )
        let newGeneration =
            store
            .subspace(SubspaceKey.indexes)
            .subspace(descriptor.name)
            .subspace(definitionFingerprint.bytes)
            .subspace(replacementLayout.fingerprint)
        #expect(
            try await storedEntryCount(
                oldGeneration,
                container: container
            ) > 0
        )
        #expect(
            try await storedEntryCount(
                newGeneration,
                container: container
            ) == 0
        )

        let runtime = try await makePersistentRuntime(
            container: container,
            schemaRuntimeFactory: AnyDatabaseSchemaRuntimeFactory(
                FixedLayoutSchemaRuntimeFactory(revision: 1)
            )
        )
        let response = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: SchemaManifest(schema: targetSchema),
                    expectedFingerprint: container.schemaFingerprint,
                    idempotencyKey: "schema-layout-replacement"
                )
            ),
            requestID: 205,
            runtime: runtime
        )
        guard case .accepted(let job) = response else {
            Issue.record("Expected a provider layout replacement job")
            return
        }
        #expect(
            try await runUntilTerminal(
                job,
                runtime: runtime,
                firstRequestID: 206
            ).state == .succeeded
        )

        #expect(
            try await storedEntryCount(
                oldGeneration,
                container: container
            ) == 0
        )
        #expect(
            try await storedEntryCount(
                newGeneration,
                container: container
            ) > 0
        )
    }

    @Test("index removal retires its declared physical generation")
    func indexRemovalRetiresDeclaredGeneration() async throws {
        let initialSchema = try Schema(
            entities: [try SchemaBuildAccountV2.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let targetSchema = try Schema(
            entities: [try SchemaBuildAccountV1.schemaEntity],
            version: Schema.Version(2, 0, 0)
        )
        let container = try await DBContainer.open(
            for: initialSchema,
            configuration: DBConfiguration.testing(
                storageEngine: InMemoryEngine()
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        SchemaBuildAccountV2.self
                    )
                ]
            ),
            security: .testingDisabled
        )
        defer { await container.shutdown() }
        let context = container.testBaseContext()
        try context.insert(
            SchemaBuildAccountV2(
                id: "removed-index-account",
                email: "removed@example.com"
            )
        )
        try await context.save()

        let store = try await container.testBaseDirectory(
            for: SchemaBuildAccountV2.self
        )
        let indexStorage =
            store
            .subspace(SubspaceKey.indexes)
            .subspace("schema_build_account_email")
        #expect(try await storedEntryCount(indexStorage, container: container) > 0)

        let runtime = try await makePersistentRuntime(container: container)
        let response = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: SchemaManifest(schema: targetSchema),
                    expectedFingerprint: container.schemaFingerprint,
                    idempotencyKey: "schema-index-removal"
                )
            ),
            requestID: 26,
            runtime: runtime
        )
        guard case .accepted(let job) = response else {
            Issue.record("Expected an index removal job")
            return
        }
        #expect(
            try await runUntilTerminal(
                job,
                runtime: runtime,
                firstRequestID: 27
            ).state == .succeeded
        )

        #expect(try await storedEntryCount(indexStorage, container: container) == 0)
        let allStates = store.subspace("state")
            .subspace("schema_build_account_email")
        let remainingStateCount = try await storedEntryCount(
            allStates,
            container: container
        )
        #expect(remainingStateCount == 0)
    }

    @Test("replacement retirement survives cancellation after schema publication")
    func replacementRetirementSurvivesPublishedCancellation() async throws {
        let initialSchema = try Schema(
            entities: [try SchemaBuildAccountV2.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let targetSchema = try Schema(
            entities: [try SchemaBuildAccountV3.schemaEntity],
            version: Schema.Version(2, 0, 0)
        )
        let container = try await DBContainer.open(
            for: initialSchema,
            configuration: DBConfiguration.testing(
                storageEngine: InMemoryEngine()
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        SchemaBuildAccountV2.self
                    )
                ]
            ),
            security: .testingDisabled
        )
        defer { await container.shutdown() }
        let context = container.testBaseContext()
        try context.insert(
            SchemaBuildAccountV2(
                id: "cancelled-replacement-account",
                email: "cancelled-replacement@example.com"
            )
        )
        try await context.save()

        let store = try await container.testBaseDirectory(
            for: SchemaBuildAccountV2.self
        )
        let oldDescriptor = try #require(
            initialSchema.indexDescriptor(named: "schema_build_account_email")
        )
        let oldGeneration =
            store
            .subspace(SubspaceKey.indexes)
            .subspace(oldDescriptor.name)
            .subspace(try SchemaManifest.indexFingerprint(oldDescriptor).bytes)
            .subspace(try standardIndexLayoutFingerprint())
        #expect(try await storedEntryCount(oldGeneration, container: container) > 0)

        let runtime = try await makePersistentRuntime(container: container)
        let firstResponse = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: SchemaManifest(schema: targetSchema),
                    expectedFingerprint: container.schemaFingerprint,
                    idempotencyKey: "schema-published-retirement-cancelled"
                )
            ),
            requestID: 28,
            runtime: runtime
        )
        guard case .accepted(let firstJob) = firstResponse else {
            Issue.record("Expected a replacement schema job")
            return
        }

        // One scheduled call advances one committed checkpoint. Staging,
        // publication, and snapshot installation leave the target schema
        // published while the durable retirement marker is still pending.
        for _ in 0..<3 {
            try await runtime.runScheduledWork()
        }
        #expect(container.schema == targetSchema)
        let cancellation = try await invoke(
            DatabaseOperationCatalog.jobCancel,
            request: JobCancelOperation.Request(job: firstJob),
            requestID: 29,
            runtime: runtime,
            metadata: OperationRequestMetadata(
                idempotencyKey: "cancel-published-retirement"
            )
        )
        #expect(cancellation.accepted)
        #expect(
            try await runUntilTerminal(
                firstJob,
                runtime: runtime,
                firstRequestID: 30
            ).state == .cancelled
        )

        let replacementResponse = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: SchemaManifest(schema: targetSchema),
                    expectedFingerprint: container.schemaFingerprint,
                    idempotencyKey: "schema-published-retirement-recovery"
                )
            ),
            requestID: 31,
            runtime: runtime
        )
        guard case .accepted(let replacementJob) = replacementResponse else {
            Issue.record("Expected a recovery schema job")
            return
        }
        #expect(
            try await runUntilTerminal(
                replacementJob,
                runtime: runtime,
                firstRequestID: 32
            ).state == .succeeded
        )
        #expect(try await storedEntryCount(oldGeneration, container: container) == 0)
    }

    @Test("schema reversal preserves the generation selected by the new target")
    func schemaReversalPreservesReactivatedGeneration() async throws {
        let initialSchema = try Schema(
            entities: [try SchemaBuildAccountV2.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let replacementSchema = try Schema(
            entities: [try SchemaBuildAccountV3.schemaEntity],
            version: Schema.Version(2, 0, 0)
        )
        let reversalSchema = try Schema(
            entities: [try SchemaBuildAccountV2.schemaEntity],
            version: Schema.Version(3, 0, 0)
        )
        let container = try await DBContainer.open(
            for: initialSchema,
            configuration: DBConfiguration.testing(
                storageEngine: InMemoryEngine()
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        SchemaBuildAccountV2.self
                    )
                ]
            ),
            security: .testingDisabled
        )
        defer { await container.shutdown() }
        let context = container.testBaseContext()
        try context.insert(
            SchemaBuildAccountV2(
                id: "reversed-replacement-account",
                email: "reversed-replacement@example.com"
            )
        )
        try await context.save()

        let store = try await container.testBaseDirectory(
            for: SchemaBuildAccountV2.self
        )
        let oldDescriptor = try #require(
            initialSchema.indexDescriptor(named: "schema_build_account_email")
        )
        let replacementDescriptor = try #require(
            replacementSchema.indexDescriptor(
                named: "schema_build_account_email"
            )
        )
        let oldGeneration =
            store
            .subspace(SubspaceKey.indexes)
            .subspace(oldDescriptor.name)
            .subspace(try SchemaManifest.indexFingerprint(oldDescriptor).bytes)
            .subspace(try standardIndexLayoutFingerprint())
        let replacementGeneration =
            store
            .subspace(SubspaceKey.indexes)
            .subspace(replacementDescriptor.name)
            .subspace(
                try SchemaManifest.indexFingerprint(replacementDescriptor).bytes
            )
            .subspace(try standardIndexLayoutFingerprint())
        #expect(try await storedEntryCount(oldGeneration, container: container) > 0)
        #expect(
            try await storedEntryCount(
                replacementGeneration,
                container: container
            ) == 0
        )

        let runtime = try await makePersistentRuntime(container: container)
        let replacementResponse = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: SchemaManifest(schema: replacementSchema),
                    expectedFingerprint: container.schemaFingerprint,
                    idempotencyKey: "schema-reversal-replacement"
                )
            ),
            requestID: 33,
            runtime: runtime
        )
        guard case .accepted(let replacementJob) = replacementResponse else {
            Issue.record("Expected a replacement schema job")
            return
        }

        // Leave the old generation and its durable retirement marker in place
        // after publishing the replacement schema.
        for _ in 0..<3 {
            try await runtime.runScheduledWork()
        }
        #expect(container.schema == replacementSchema)
        let cancellation = try await invoke(
            DatabaseOperationCatalog.jobCancel,
            request: JobCancelOperation.Request(job: replacementJob),
            requestID: 34,
            runtime: runtime,
            metadata: OperationRequestMetadata(
                idempotencyKey: "cancel-schema-reversal-replacement"
            )
        )
        #expect(cancellation.accepted)
        #expect(
            try await runUntilTerminal(
                replacementJob,
                runtime: runtime,
                firstRequestID: 35
            ).state == .cancelled
        )

        let reversalResponse = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: SchemaManifest(schema: reversalSchema),
                    expectedFingerprint: container.schemaFingerprint,
                    idempotencyKey: "schema-reversal-reactivate-old-generation"
                )
            ),
            requestID: 36,
            runtime: runtime
        )
        guard case .accepted(let reversalJob) = reversalResponse else {
            Issue.record("Expected a schema reversal job")
            return
        }
        #expect(
            try await runUntilTerminal(
                reversalJob,
                runtime: runtime,
                firstRequestID: 37
            ).state == .succeeded
        )

        #expect(container.schema == reversalSchema)
        #expect(try await storedEntryCount(oldGeneration, container: container) > 0)
        #expect(
            try await storedEntryCount(
                replacementGeneration,
                container: container
            ) == 0
        )
        #expect(
            try await indexStatus(
                container: container,
                entity: SchemaBuildAccountV2.persistableType,
                index: "schema_build_account_email"
            ).indexState == .readable
        )
    }

    @Test("dynamic partitions stay write-only until every partition is backfilled")
    func dynamicIndexAdditionBuildsEveryPartition() async throws {
        let initialSchema = try Schema(
            entities: [try SchemaBuildTenantAccountV1.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let targetSchema = try Schema(
            entities: [try SchemaBuildTenantAccountV2.schemaEntity],
            version: Schema.Version(2, 0, 0)
        )
        let container = try await DBContainer.open(
            for: initialSchema,
            configuration: DBConfiguration.testing(
                storageEngine: InMemoryEngine()
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        SchemaBuildTenantAccountV1.self
                    )
                ]
            ),
            security: .testingDisabled
        )
        defer { await container.shutdown() }
        let runtime = try await makePersistentRuntime(container: container)
        let context = container.testBaseContext()
        try context.insert(
            SchemaBuildTenantAccountV1(
                id: "account-a",
                tenantID: "tenant-a",
                email: "a@example.com"
            )
        )
        try context.insert(
            SchemaBuildTenantAccountV1(
                id: "account-b",
                tenantID: "tenant-b",
                email: "b@example.com"
            )
        )
        try await context.save()

        let response = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: SchemaManifest(schema: targetSchema),
                    expectedFingerprint: container.schemaFingerprint,
                    idempotencyKey: "schema-dynamic-index-build"
                )
            ),
            requestID: 31,
            runtime: runtime
        )
        guard case .accepted(let job) = response else {
            Issue.record("Expected a dynamic schema index build job")
            return
        }

        #expect(container.schema == initialSchema)
        try await runtime.runScheduledWork()
        #expect(container.schema == initialSchema)
        try await runtime.runScheduledWork()
        #expect(container.schema == targetSchema)
        let tenantA = try partitions(tenantID: "tenant-a")
        let tenantB = try partitions(tenantID: "tenant-b")
        #expect(
            try await indexStatus(
                container: container,
                entity: SchemaBuildTenantAccountV2.persistableType,
                index: "schema_build_tenant_account_email",
                partitions: tenantA
            ).indexState == .writeOnly
        )
        #expect(
            try await indexStatus(
                container: container,
                entity: SchemaBuildTenantAccountV2.persistableType,
                index: "schema_build_tenant_account_email",
                partitions: tenantB
            ).indexState == .writeOnly
        )

        let completed = try await runUntilTerminal(
            job,
            runtime: runtime,
            firstRequestID: 32
        )
        #expect(completed.state == .succeeded)
        #expect(container.schema == targetSchema)
        for tenant in [tenantA, tenantB] {
            let status = try await indexStatus(
                container: container,
                entity: SchemaBuildTenantAccountV2.persistableType,
                index: "schema_build_tenant_account_email",
                partitions: tenant
            )
            #expect(status.indexState == .readable)
            #expect(status.indexedEntityCount == 1)
        }
    }

    @Test("cancelled schema index build is recoverable by idempotent re-apply")
    func cancelledIndexBuildCanBeReplaced() async throws {
        let initialSchema = try Schema(
            entities: [try SchemaBuildAccountV1.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let targetSchema = try Schema(
            entities: [try SchemaBuildAccountV2.schemaEntity],
            version: Schema.Version(2, 0, 0)
        )
        let container = try await DBContainer.open(
            for: initialSchema,
            configuration: DBConfiguration.testing(
                storageEngine: InMemoryEngine()
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        SchemaBuildAccountV1.self
                    )
                ]
            ),
            security: .testingDisabled
        )
        defer { await container.shutdown() }
        let runtime = try await makePersistentRuntime(container: container)
        let context = container.testBaseContext()
        try context.insert(
            SchemaBuildAccountV1(
                id: "cancelled-account",
                email: "cancelled@example.com"
            )
        )
        try await context.save()

        let manifest = SchemaManifest(schema: targetSchema)
        let first = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: manifest,
                    expectedFingerprint: container.schemaFingerprint,
                    idempotencyKey: "schema-index-cancelled"
                )
            ),
            requestID: 41,
            runtime: runtime
        )
        guard case .accepted(let firstJob) = first else {
            Issue.record("Expected the first schema index build job")
            return
        }
        let cancellation = try await invoke(
            DatabaseOperationCatalog.jobCancel,
            request: JobCancelOperation.Request(job: firstJob),
            requestID: 42,
            runtime: runtime,
            metadata: OperationRequestMetadata(
                idempotencyKey: "schema-index-cancel-job"
            )
        )
        #expect(cancellation.accepted)
        let cancelled = try await runUntilTerminal(
            firstJob,
            runtime: runtime,
            firstRequestID: 43
        )
        #expect(cancelled.state == .cancelled)

        let replacement = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: manifest,
                    expectedFingerprint: container.schemaFingerprint,
                    idempotencyKey: "schema-index-replacement"
                )
            ),
            requestID: 44,
            runtime: runtime
        )
        guard case .accepted(let replacementJob) = replacement else {
            Issue.record("Expected a replacement schema index build job")
            return
        }
        #expect(replacementJob != firstJob)

        let completed = try await runUntilTerminal(
            replacementJob,
            runtime: runtime,
            firstRequestID: 45
        )
        #expect(completed.state == .succeeded)
        #expect(
            try await indexStatus(
                container: container,
                entity: SchemaBuildAccountV2.persistableType,
                index: "schema_build_account_email"
            ).indexState == .readable
        )
    }

#if MultiBase
    @Test("An accepted schema transition blocks Base lifecycle changes")
    func acceptedTransitionBlocksBaseLifecycle() async throws {
        let initialSchema = try Schema(
            entities: [],
            version: Schema.Version(0, 0, 0)
        )
        let targetSchema = try Schema(
            entities: [try SchemaExecuteAccount.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let container = try await makeContainer(schema: initialSchema)
        defer { await container.shutdown() }
        let runtime = try await makePersistentRuntime(container: container)
        let base = try await baseRecord(container)
        let response = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: SchemaManifest(schema: targetSchema),
                    expectedFingerprint: container.schemaFingerprint,
                    idempotencyKey: "schema-blocks-base-lifecycle"
                )
            ),
            requestID: 51,
            runtime: runtime
        )
        guard case .accepted(let job) = response else {
            Issue.record("Expected an accepted schema transition job")
            return
        }

        do {
            _ = try await container.retireBase(
                base.id,
                expectedRevision: base.revision
            )
            Issue.record("Expected the Base lifecycle change to be rejected")
        } catch DatabaseSchemaPublicationError.transitionInProgress {
            // The framework owns the schema transition state, while the
            // server owns the persistent job identity. Rejection therefore
            // carries no server-owned job value across the package boundary.
        }

        #expect(
            try await runUntilTerminal(
                job,
                runtime: runtime,
                firstRequestID: 52
            ).state == .succeeded
        )
    }

    @Test("Schema transition installs the current snapshot into retired Bases")
    func retiredBaseReceivesSchemaSnapshot() async throws {
        let initialSchema = try Schema(
            entities: [try SchemaBuildAccountV1.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let targetSchema = try Schema(
            entities: [try SchemaBuildAccountV2.schemaEntity],
            version: Schema.Version(2, 0, 0)
        )
        let container = try await DBContainer.open(
            for: initialSchema,
            configuration: DBConfiguration.testing(
                storageEngine: InMemoryEngine()
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        SchemaBuildAccountV1.self
                    )
                ]
            ),
            security: .testingDisabled
        )
        defer { await container.shutdown() }
        let current = try await baseRecord(container)
        let retired = try await container.retireBase(
            current.id,
            expectedRevision: current.revision
        )
        let runtime = try await makePersistentRuntime(container: container)
        let response = try await invoke(
            DatabaseOperationCatalog.schemaExecute,
            request: SchemaExecuteOperation.Request(
                invocation: .apply(
                    manifest: SchemaManifest(schema: targetSchema),
                    expectedFingerprint: container.schemaFingerprint,
                    idempotencyKey: "schema-retired-base"
                )
            ),
            requestID: 61,
            runtime: runtime
        )
        guard case .accepted(let job) = response else {
            Issue.record("Expected an accepted schema transition job")
            return
        }
        #expect(
            try await runUntilTerminal(
                job,
                runtime: runtime,
                firstRequestID: 62
            ).state == .succeeded
        )

        let lease = try container.acquireBaseSchemaMaintenanceLease(
            retired.id
        )
        let installedVersion = try await container.withBaseLease(lease) {
            try await container.getCurrentSchemaVersion()
        }
        #expect(installedVersion == targetSchema.version)

        let active = try await container.activateBase(
            retired.id,
            expectedRevision: retired.revision,
            authorization: TestBaseEnvironment.authorization
        )
        #expect(active.lifecycle == .active)
    }
#endif

    private func makeContainer(schema: Schema) async throws -> DBContainer {
        try await DBContainer.open(
            for: schema,
            configuration: DBConfiguration.testing(
                storageEngine: InMemoryEngine()
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                schema: schema
            ),
            security: .testingDisabled
        )
    }

#if MultiBase
    private func baseRecord(
        _ container: DBContainer
    ) async throws -> DatabaseBaseRecord {
        let id = try TestBaseEnvironment.id()
        return try await container.withControlMetadataTransaction(
            configuration: .readOnly
        ) { transaction in
            try #require(
                try await container.baseCatalog.load(
                    id,
                    transaction: transaction.executionStorageAccess
                )
            )
        }
    }
#endif

    private func makeRuntime(
        container: DBContainer
    ) async throws -> DatabaseOperationInstance {
        try await makePersistentRuntime(container: container)
    }

    private func makePersistentRuntime(
        container: DBContainer,
        schemaRuntimeFactory: AnyDatabaseSchemaRuntimeFactory =
            AnyDatabaseSchemaRuntimeFactory(
                SchemaDrivenDatabaseRuntimeFactory(
                    executionIdentity: DatabaseExecutionRuntimeIdentity(
                        identifier: "database-server-tests",
                        revision: 1
                    ),
                )
            )
    ) async throws -> DatabaseOperationInstance {
        let runtimeLimits = DatabaseOperationLimits.default
        let identifierGenerator = RandomDatabaseUUIDGenerator()
        let registry = try DatabaseResumableOperationRegistry(
            operations: [
                try AnyDatabaseResumableOperation(
                    DatabaseMaintenanceResumableOperation(
                        runtimeLimits: runtimeLimits
                    )
                )
            ]
        )
        let services = CanonicalDatabaseOperationServiceFactory(
            maintenanceServiceFactory:
                DatabaseMaintenanceOperationServiceFactory(
                    identifierGenerator: identifierGenerator
                ),
            jobServiceFactory: try DatabasePersistentJobServiceFactory(
                registry: registry,
                identifierGenerator: identifierGenerator,
                storageLimits: DatabasePersistentJobStorageLimits(
                    maximumStorageValueBytes: 1_048_576
                )
            )
        )
        return try await DatabaseOperationInstance.open(
            container: container,
            configuration: try DatabaseOperationConfiguration(
                identity: DatabaseOperationIdentity(version: "schema-test"),
                serviceFactory: AnyDatabaseOperationServiceFactory(services),
                admissionPolicy: AnyDatabaseOperationAdmissionPolicy(
                    UnrestrictedDatabaseOperationAdmissionPolicy()
                ),
                schemaRuntimeFactory: schemaRuntimeFactory,
                runtimeLimits: runtimeLimits
            ),
            hostServices: try testJobHostServices(
                scheduler: SchemaTestJobScheduler()
            )
        )
    }

    private func runUntilTerminal(
        _ job: JobIdentity,
        runtime: DatabaseOperationInstance,
        firstRequestID: UInt64
    ) async throws -> JobStatusOperation.Response {
        var requestID = firstRequestID
        for _ in 0..<128 {
            try await runtime.runScheduledWork()
            let status = try await invoke(
                DatabaseOperationCatalog.jobStatus,
                request: JobStatusOperation.Request(job: job),
                requestID: requestID,
                runtime: runtime
            )
            switch status.state {
            case .succeeded, .failed, .cancelled:
                return status
            case .pending, .running, .committingUnsuccessfulOutcome:
                break
            }
            requestID += 1
        }
        throw SchemaExecuteHandlerTestError.didNotReachTerminalState
    }

    private func schemaApplyResult(
        _ job: JobIdentity,
        runtime: DatabaseOperationInstance,
        requestID: UInt64
    ) async throws -> SchemaExecuteOperation.Applied {
        let result = try await invoke(
            DatabaseOperationCatalog.jobResult,
            request: JobResultOperation.Request(job: job),
            requestID: requestID,
            runtime: runtime
        )
        guard case .succeeded(
            _,
            let responsePayload,
            _,
            _,
            nil
        ) = result else {
            throw SchemaExecuteHandlerTestError.expectedSuccessfulJobResult
        }
        let response = try DatabaseWireDecoder().decodeResponsePayload(
            DatabaseOperationCatalog.schemaExecute,
            from: responsePayload
        )
        guard case .applied(let publication) = response else {
            throw SchemaExecuteHandlerTestError.expectedAppliedResult
        }
        return publication
    }

    private func indexStatus(
        container: DBContainer,
        entity: String,
        index: String,
        partitions: FieldObject = FieldObject()
    ) async throws -> DatabaseIndexMaintenanceStatus {
        try await container.testBaseContext().withTransaction { transaction in
            try await DatabaseIndexMaintenanceRuntime(
                container: container
            ).status(
                entity: entity,
                index: index,
                partitions: partitions,
                transaction: transaction.executionStorageAccess
            )
        }
    }

    private func storedEntryCount(
        _ subspace: Subspace,
        container: DBContainer
    ) async throws -> Int {
        let range = subspace.range()
        return try await container.withTestBaseTransaction { transaction in
            let entries = try await transaction.collectRange(
                begin: range.begin,
                end: range.end,
                snapshot: true
            )
            return entries.count
        }
    }

    private func partitions(tenantID: String) throws -> FieldObject {
        try FieldObject([
            (key: "tenantID", value: .string(tenantID))
        ])
    }

    private func schemaAddingRequiredField(
        to schema: Schema
    ) throws -> Schema {
        let current = try #require(schema.entities.first)
        let added = FieldSchema(
            name: "requiredValue",
            fieldNumber: 3,
            type: .string,
            isOptional: false,
            isArray: false
        )
        return try Schema(
            entities: [
                try Schema.Entity(
                    name: current.name,
                    identifierType: current.identifierType,
                    fields: current.fields + [added],
                    directoryComponents: current.directoryComponents,
                    directoryLayer: current.directoryLayer,
                    indexes: current.indexes,
                    relationships: current.relationships,
                    fieldAccessRules: current.fieldAccessRules,
                    enumMetadata: current.enumMetadata,
                    ontology: current.ontology,
                    polymorphicMembership: current.polymorphicMembership
                )
            ],
            version: Schema.Version(2, 0, 0)
        )
    }

    private func schemaAddingOptionalField(
        to schema: Schema
    ) throws -> Schema {
        let current = try #require(schema.entities.first)
        let added = FieldSchema(
            name: "optionalValue",
            fieldNumber: 3,
            type: .string,
            isOptional: true,
            isArray: false
        )
        return try Schema(
            entities: [
                try Schema.Entity(
                    name: current.name,
                    identifierType: current.identifierType,
                    fields: current.fields + [added],
                    directoryComponents: current.directoryComponents,
                    directoryLayer: current.directoryLayer,
                    indexes: current.indexes,
                    relationships: current.relationships,
                    fieldAccessRules: current.fieldAccessRules,
                    enumMetadata: current.enumMetadata,
                    ontology: current.ontology,
                    polymorphicMembership: current.polymorphicMembership
                )
            ],
            version: Schema.Version(2, 0, 0)
        )
    }

    private func targetManifestFingerprint(
        _ manifest: SchemaManifest
    ) throws -> SchemaFingerprint {
        try manifest.fingerprint()
    }

    private func standardIndexLayoutFingerprint() throws -> ByteString {
        try IndexPhysicalLayout(
            name: "standard",
            revision: 1
        ).fingerprint
    }

    private func execute<Request: Sendable, Response: Sendable>(
        _ operation: DatabaseOperation<Request, Response>,
        request: Request,
        requestID: UInt64,
        runtime: DatabaseOperationInstance,
        metadata: OperationRequestMetadata = OperationRequestMetadata()
    ) async throws -> ByteString {
        #if MultiBase
        let bytes = try DatabaseWireEncoder().encodeRequest(
            operation,
            requestID: requestID,
            target: .database,
            metadata: metadata,
            request: request
        )
        #else
        let bytes = try DatabaseWireEncoder().encodeRequest(
            operation,
            requestID: requestID,
            metadata: metadata,
            request: request
        )
        #endif
        return try await DatabaseWireEndpoint(instance: runtime).execute(
            bytes,
            context: DatabaseRequestExecutionContext(
                authorization: TestBaseEnvironment.authorization,
                jobAuthorizationReference:
                    try TestDatabaseJobAuthorizationValidator.reference()
            )
        )
    }

    private func invoke<Request: Sendable, Response: Sendable>(
        _ operation: DatabaseOperation<Request, Response>,
        request: Request,
        requestID: UInt64,
        runtime: DatabaseOperationInstance,
        metadata: OperationRequestMetadata = OperationRequestMetadata()
    ) async throws -> Response {
        let response = try DatabaseWireDecoder().decodeResponse(
            operation,
            from: try await execute(
                operation,
                request: request,
                requestID: requestID,
                runtime: runtime,
                metadata: metadata
            ),
            matching: requestID
        )
        switch response {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

private actor SchemaTestJobScheduler: DatabaseJobScheduler {
    func ensureWakeUp(noLaterThan timestamp: Timestamp) async throws {
        _ = timestamp
    }
}

private enum SchemaExecuteHandlerTestError: Error {
    case didNotReachTerminalState
    case expectedAcceptedJob
    case expectedSuccessfulJobResult
    case expectedAppliedResult
}
