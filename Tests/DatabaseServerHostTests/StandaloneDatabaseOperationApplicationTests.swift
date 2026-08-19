import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
import DatabaseServerFoundation
import DatabaseServerRuntime
import StorageKit
import Testing

@testable import DatabaseServerHost

@Suite("Standalone database application")
struct StandaloneDatabaseOperationApplicationTests {
    @Test("Accepts a schema-driven definition with schema execution")
    func acceptsCoherentComposition() async throws {
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
            monotonicClock: FixedMonotonicClock(),
            wallClock: RealtimeDatabaseWallClock()
        )
        let operationConfiguration = try makeOperationConfiguration(
            schemaFactory: schemaFactory
        )

        let application = try StandaloneDatabaseOperationApplication(
            containerDefinition: definition,
            operationConfiguration: operationConfiguration
        )
        let resolvedDefinition = try await application.makeContainerDefinition()

        #expect(resolvedDefinition.isSchemaDriven)
        #expect(operationConfiguration.schemaRuntimeFactory != nil)
    }

    @Test("Rejects a compiled container definition")
    func rejectsCompiledDefinition() throws {
        let emptySchema = try Schema(
            entities: [],
            version: Schema.Version(0, 0, 0)
        )
        let definition = DatabaseContainerDefinition(
            schema: emptySchema,
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                schema: emptySchema
            ),
            monotonicClock: FixedMonotonicClock(),
            wallClock: RealtimeDatabaseWallClock()
        )
        let schemaFactory = AnyDatabaseSchemaRuntimeFactory(
            SchemaDrivenDatabaseRuntimeFactory(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-server-tests",
                    revision: 1
                ),
            )
        )

        #expect(
            throws: StandaloneDatabaseOperationApplicationError.compiledContainerDefinition
        ) {
            try StandaloneDatabaseOperationApplication(
                containerDefinition: definition,
                operationConfiguration: makeOperationConfiguration(
                    schemaFactory: schemaFactory
                )
            )
        }
    }

    @Test("Rejects an operation configuration without schema execution")
    func rejectsMissingSchemaExecution() throws {
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
            monotonicClock: FixedMonotonicClock(),
            wallClock: RealtimeDatabaseWallClock()
        )

        #expect(
            throws: StandaloneDatabaseOperationApplicationError.schemaExecutionUnavailable
        ) {
            try StandaloneDatabaseOperationApplication(
                containerDefinition: definition,
                operationConfiguration: makeOperationConfiguration(
                    schemaFactory: nil
                )
            )
        }
    }
}

private func makeOperationConfiguration(
    schemaFactory: AnyDatabaseSchemaRuntimeFactory?
) throws -> DatabaseOperationConfiguration {
    try DatabaseOperationConfiguration(
        identity: DatabaseOperationIdentity(version: "standalone-application-test"),
        serviceFactory: AnyDatabaseOperationServiceFactory { _ in
            throw StandaloneApplicationTestError.unusedServiceFactory
        },
        admissionPolicy: AnyDatabaseOperationAdmissionPolicy(
            UnrestrictedDatabaseOperationAdmissionPolicy()
        ),
        schemaRuntimeFactory: schemaFactory
    )
}

private struct FixedMonotonicClock: StorageMonotonicClock {
    let now = StorageInstant(durationSinceReference: .zero)

    func sleep(
        until deadline: StorageInstant
    ) async throws(StorageClockError) {
        _ = deadline
    }
}

private enum StandaloneApplicationTestError: Error {
    case unusedServiceFactory
}
