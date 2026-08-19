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
        let namespacePath = ["database", "server-selected"]
        let expectedRoot = try await engine.resolveOrCreateNamespace(
            path: namespacePath
        )
        let container = try await definition.open(
            storageEngine: engine,
            databaseRoot: expectedRoot
        )
        defer { await container.shutdown() }

        #expect(try container.executionStorage().root == expectedRoot)
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
            databaseRoot: Subspace()
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
