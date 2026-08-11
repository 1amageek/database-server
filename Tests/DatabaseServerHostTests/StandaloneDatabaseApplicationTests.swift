import DatabaseEngine
import DatabaseFoundation
import DatabaseKit
import DatabaseRuntime
import DatabaseWireRuntime
import StorageKit
@testable import DatabaseServerHost
import Testing

@Suite("Standalone database application")
struct StandaloneDatabaseApplicationTests {
    @Test("Accepts a schema-driven definition with schema execution")
    func acceptsCoherentComposition() async throws {
        let schemaFactory = AnyDatabaseSchemaRuntimeFactory(
            SchemaDrivenDatabaseRuntimeFactory()
        )
        let definition = DatabaseContainerDefinition(
            schemaRuntimeFactory: schemaFactory,
            monotonicClock: FixedMonotonicClock(),
            wallClock: RealtimeDatabaseWallClock()
        )
        let runtimeConfiguration = try makeRuntimeConfiguration(
            schemaFactory: schemaFactory
        )

        let application = try StandaloneDatabaseApplication(
            containerDefinition: definition,
            runtimeConfiguration: runtimeConfiguration
        )
        let resolvedDefinition = try await application.makeContainerDefinition()

        #expect(resolvedDefinition.isSchemaDriven)
        #expect(runtimeConfiguration.schemaRuntimeFactory != nil)
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
                schema: emptySchema
            ),
            monotonicClock: FixedMonotonicClock(),
            wallClock: RealtimeDatabaseWallClock()
        )
        let schemaFactory = AnyDatabaseSchemaRuntimeFactory(
            SchemaDrivenDatabaseRuntimeFactory()
        )

        #expect(
            throws: StandaloneDatabaseApplicationError.compiledContainerDefinition
        ) {
            try StandaloneDatabaseApplication(
                containerDefinition: definition,
                runtimeConfiguration: makeRuntimeConfiguration(
                    schemaFactory: schemaFactory
                )
            )
        }
    }

    @Test("Rejects a runtime without schema execution")
    func rejectsMissingSchemaExecution() throws {
        let schemaFactory = AnyDatabaseSchemaRuntimeFactory(
            SchemaDrivenDatabaseRuntimeFactory()
        )
        let definition = DatabaseContainerDefinition(
            schemaRuntimeFactory: schemaFactory,
            monotonicClock: FixedMonotonicClock(),
            wallClock: RealtimeDatabaseWallClock()
        )

        #expect(
            throws: StandaloneDatabaseApplicationError.schemaExecutionUnavailable
        ) {
            try StandaloneDatabaseApplication(
                containerDefinition: definition,
                runtimeConfiguration: makeRuntimeConfiguration(
                    schemaFactory: nil
                )
            )
        }
    }
}

private func makeRuntimeConfiguration(
    schemaFactory: AnyDatabaseSchemaRuntimeFactory?
) throws -> DatabaseOperationRuntimeConfiguration {
    try DatabaseOperationRuntimeConfiguration(
        identity: DatabaseRuntimeIdentity(version: "standalone-application-test"),
        serviceFactory: AnyDatabaseOperationServiceFactory { _ in
            throw StandaloneApplicationTestError.unusedServiceFactory
        },
        admissionPolicy: AnyDatabaseOperationAdmissionPolicy(
            UnrestrictedDatabaseOperationAdmissionPolicy()
        ),
        clock: RealtimeDatabaseWallClock(),
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
