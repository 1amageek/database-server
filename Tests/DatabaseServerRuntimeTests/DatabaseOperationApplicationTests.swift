@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
import DatabaseServerFoundation
import StorageKit
import TestSupport
import Testing

@testable import DatabaseServerRuntime

@Suite("Database application composition", .serialized)
struct DatabaseOperationApplicationTests {
    #if !DATABASE_SERVER_MULTI_BASE
    @Test("Standard definition preserves the host-selected root")
    func standardDefinitionPreservesRoot() async throws {
        let schemaFactory = AnyDatabaseSchemaRuntimeFactory(
            SchemaDrivenDatabaseRuntimeFactory(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-server-tests",
                    revision: 1
                ),
            )
        )
        let definition = DatabaseContainerDefinition(
            schemaRuntimeFactory: schemaFactory,
            security: .testingDisabled,
            databaseName: "namespace-application",
            monotonicClock: TestProcessMonotonicClock(),
            wallClock: RealtimeDatabaseWallClock()
        )
        let engine = InMemoryEngine()
        let databaseRootPath = ["database", "server-selected"]
        let container = try await definition.open(
            storageEngine: engine,
            databaseRootPath: databaseRootPath
        )
        defer { await container.shutdown() }

        let storage = try container.executionStorage()
        let expected = try await Self.resolveDefaultTenantRoots(
            path: databaseRootPath,
            in: engine
        )
        #expect(storage.systemRoot == expected.system)
        #expect(storage.dataRoot == expected.data)
        #expect(storage.systemRoot != storage.dataRoot)
    }

    /// Resolves the Default Tenant's reserved roots below the host-selected
    /// path, creating nothing: opening the container already committed the
    /// layout, so an absent node means the host-selected path was not the one
    /// the container used.
    ///
    /// The names below mirror the Framework's reserved layout names, which are
    /// module-internal to the Framework and therefore restated here.
    private static func resolveDefaultTenantRoots(
        path: [String],
        in engine: any StorageEngine
    ) async throws -> (system: Subspace, data: Subspace) {
        let access = engine.directoryAccess
        return try await engine.withTransaction { transaction in
            guard var current = try await access.openRoot(
                transaction: transaction
            ) else {
                throw DatabaseRootResolutionError.missingDirectory(path: [])
            }
            var resolved: [String] = []
            for component in path {
                guard let next = try await access.openDirectory(
                    component,
                    in: current,
                    transaction: transaction
                ) else {
                    throw DatabaseRootResolutionError.missingDirectory(
                        path: resolved + [component]
                    )
                }
                resolved.append(component)
                current = next
            }
            guard let tenant = try await access.openPartition(
                "default",
                in: current,
                transaction: transaction
            ) else {
                throw DatabaseRootResolutionError.missingDirectory(
                    path: resolved + ["default"]
                )
            }
            guard let system = try await access.openDirectory(
                "system",
                in: tenant.root,
                transaction: transaction
            ), let framework = try await access.openDirectory(
                "database-framework",
                in: system,
                transaction: transaction
            ) else {
                throw DatabaseRootResolutionError.missingDirectory(
                    path: resolved + ["default", "system", "database-framework"]
                )
            }
            guard let data = try await access.openDirectory(
                "data",
                in: tenant.root,
                transaction: transaction
            ) else {
                throw DatabaseRootResolutionError.missingDirectory(
                    path: resolved + ["default", "data"]
                )
            }
            return (system: framework.root, data: data.root)
        }
    }
    #endif

    @Test("Schema-driven definition restores an empty durable catalog")
    func schemaDrivenDefinitionOpensEmptyCatalog() async throws {
        let schemaFactory = AnyDatabaseSchemaRuntimeFactory(
            SchemaDrivenDatabaseRuntimeFactory(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-server-tests",
                    revision: 1
                ),
            )
        )
        let definition = DatabaseContainerDefinition(
            schemaRuntimeFactory: schemaFactory,
            security: .testingDisabled,
            databaseName: "schema-driven-application",
            monotonicClock: TestProcessMonotonicClock(),
            wallClock: RealtimeDatabaseWallClock()
        )
        let container = try await open(definition)
        defer { await container.shutdown() }

        #expect(definition.isSchemaDriven)
        #expect(definition.declaredSchema == nil)
        #expect(container.schema.entities.isEmpty)
        #expect(container.schema.version == Schema.Version(0, 0, 0))
    }

    @Test("Application erasure preserves definition and runtime factories")
    func applicationErasurePreservesComposition() async throws {
        let schemaFactory = AnyDatabaseSchemaRuntimeFactory(
            SchemaDrivenDatabaseRuntimeFactory(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-server-tests",
                    revision: 1
                ),
            )
        )
        let definition = DatabaseContainerDefinition(
            schemaRuntimeFactory: schemaFactory,
            security: .testingDisabled,
            monotonicClock: TestProcessMonotonicClock(),
            wallClock: RealtimeDatabaseWallClock()
        )
        let runtimeConfiguration = try makeOperationConfiguration(
            schemaFactory: schemaFactory
        )
        let application = TestDatabaseOperationApplication(
            containerDefinition: definition,
            runtimeConfiguration: runtimeConfiguration
        )
        let erased = AnyDatabaseOperationApplication(application)
        let resolvedDefinition = try await erased.makeContainerDefinition()
        let container = try await open(resolvedDefinition)
        defer { await container.shutdown() }
        let resolvedRuntime = try await erased.makeOperationConfiguration(
            for: container
        )

        #expect(resolvedDefinition.isSchemaDriven)
        #expect(resolvedRuntime.identity.version == "application-test")
        #expect(resolvedRuntime.schemaRuntimeFactory != nil)
    }

    private func makeOperationConfiguration(
        schemaFactory: AnyDatabaseSchemaRuntimeFactory?
    ) throws -> DatabaseOperationConfiguration {
        try DatabaseOperationConfiguration(
            identity: DatabaseOperationIdentity(version: "application-test"),
            serviceFactory: AnyDatabaseOperationServiceFactory { _ in
                throw DatabaseOperationApplicationTestError.unusedServiceFactory
            },
            admissionPolicy: AnyDatabaseOperationAdmissionPolicy(
                UnrestrictedDatabaseOperationAdmissionPolicy()
            ),
            schemaRuntimeFactory: schemaFactory
        )
    }

    private func open(
        _ definition: DatabaseContainerDefinition
    ) async throws -> DBContainer {
        let engine = InMemoryEngine()
        #if MultiBase
        return try await definition.open(
            storageTopology: .testing(storageEngine: engine)
        )
        #else
        return try await definition.open(
            storageEngine: engine,
            databaseRootPath: []
        )
        #endif
    }
}

private struct TestDatabaseOperationApplication: DatabaseOperationApplication {
    let containerDefinition: DatabaseContainerDefinition
    let runtimeConfiguration: DatabaseOperationConfiguration

    func makeContainerDefinition() async throws -> DatabaseContainerDefinition {
        containerDefinition
    }

    func makeOperationConfiguration(
        for container: DBContainer
    ) async throws -> DatabaseOperationConfiguration {
        _ = container
        return runtimeConfiguration
    }
}

private enum DatabaseOperationApplicationTestError: Error {
    case unusedServiceFactory
}

#if !DATABASE_SERVER_MULTI_BASE
/// A reserved layout node the container was expected to have committed is
/// absent below the host-selected database root path.
private enum DatabaseRootResolutionError: Error {
    case missingDirectory(path: [String])
}
#endif
