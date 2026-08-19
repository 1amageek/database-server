#if SQLITE
import Foundation
@_spi(DatabaseExecution) import DatabaseEngine
@testable import DatabaseEngine
import Database
import DatabaseKit
import DatabaseRuntime
import DatabaseServerRuntime
import DatabaseServerFoundation
import DatabaseTypes
import DatabaseWire
import StorageKit
import TestSupport
import Testing

@Persistable(type: "RestartSchemaBuildAccount")
private struct RestartSchemaBuildAccountV1 {
    #Directory<RestartSchemaBuildAccountV1>(
        "schema-index-job-restart",
        "accounts"
    )

    var id: String = ""
    var email: String = ""
}

@Persistable(type: "RestartSchemaBuildAccount")
private struct RestartSchemaBuildAccountV2 {
    #Directory<RestartSchemaBuildAccountV2>(
        "schema-index-job-restart",
        "accounts"
    )
    #Index(
        .ordered(
            name: "restart_schema_build_account_email",
            keys: [.ascending(\RestartSchemaBuildAccountV2.email)]
        ))

    var id: String = ""
    var email: String = ""
}

@Suite("Schema index job SQLite restart", .serialized)
struct SchemaIndexJobRestartSQLiteTests {
    @Test("published schema and pending index job resume after process restart")
    func pendingBuildResumesAfterRestart() async throws {
        let database = try SQLiteTestDatabase(
            prefix: "schema-index-job-restart"
        )
        defer { database.remove() }
        let initialSchema = try Schema(
            entities: [try RestartSchemaBuildAccountV1.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let targetSchema = try Schema(
            entities: [try RestartSchemaBuildAccountV2.schemaEntity],
            version: Schema.Version(2, 0, 0)
        )
        let first = try await DBContainer.open(
            for: initialSchema,
            configuration: DBConfiguration.testing(
                storageEngine: try SQLiteStorageEngine(
                    configuration: .file(database.path)
                )
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        RestartSchemaBuildAccountV1.self
                    )
                ]
            ),
            security: .testingDisabled
        )
        let job: JobIdentity
        do {
            let firstRuntime = try await makeRuntime(container: first)
            let context = first.testBaseContext()
            try context.insert(
                RestartSchemaBuildAccountV1(
                    id: "persisted-before-restart",
                    email: "restart@example.com"
                )
            )
            try await context.save()
            let response = try await invoke(
                DatabaseOperationCatalog.schemaExecute,
                request: SchemaExecuteOperation.Request(
                    invocation: .apply(
                        manifest: SchemaManifest(schema: targetSchema),
                        expectedFingerprint: first.schemaFingerprint,
                        idempotencyKey: "schema-index-job-restart"
                    )
                ),
                requestID: 1,
                runtime: firstRuntime
            )
            guard case .accepted(let acceptedJob) = response else {
                Issue.record("Expected an accepted schema transition job")
                await first.shutdown()
                return
            }
            job = acceptedJob
            #expect(first.schema == initialSchema)
            try await firstRuntime.runScheduledWork()
            try await firstRuntime.runScheduledWork()
            #expect(first.schema == targetSchema)
            #expect(
                try await first.withTestBaseOperation {
                    try await first.getCurrentSchemaVersion()
                } == initialSchema.version
            )
            await first.shutdown()
        } catch {
            await first.shutdown()
            throw error
        }

        let reopened = try await DBContainer.openRestoringSchema(
            configuration: DBConfiguration.testing(
                storageEngine: try SQLiteStorageEngine(
                    configuration: .file(database.path)
                )
            ),
            security: .testingDisabled
        ) { schema in
            try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                schema: schema)
        }
        defer { await reopened.shutdown() }
        #expect(reopened.schema == targetSchema)

        let restoredRuntime = try await makeRuntime(container: reopened)
        let status = try await runUntilTerminal(
            job,
            runtime: restoredRuntime,
            firstRequestID: 2
        )
        #expect(status.state == .succeeded)
        #expect(reopened.schema == targetSchema)
        let index = try await indexStatus(container: reopened)
        #expect(index.indexState == .readable)
        #expect(index.indexedEntityCount == 1)
    }

    private func makeRuntime(
        container: DBContainer
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
        let serviceFactory = CanonicalDatabaseOperationServiceFactory(
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
                identity: DatabaseOperationIdentity(
                    version: "schema-restart-test"
                ),
                serviceFactory: AnyDatabaseOperationServiceFactory(
                    serviceFactory
                ),
                admissionPolicy: AnyDatabaseOperationAdmissionPolicy(
                    UnrestrictedDatabaseOperationAdmissionPolicy()
                ),
                schemaRuntimeFactory: AnyDatabaseSchemaRuntimeFactory(
                    SchemaDrivenDatabaseRuntimeFactory(
                        executionIdentity: DatabaseExecutionRuntimeIdentity(
                            identifier: "database-server-tests",
                            revision: 1
                        ),
                    )
                ),
                runtimeLimits: runtimeLimits
            ),
            hostServices: DatabaseOperationHostServices(
                jobScheduler: AnyDatabaseJobScheduler(
                    SQLiteSchemaJobScheduler()
                ),
                jobAuthorizationValidator:
                    AnyDatabaseJobAuthorizationValidator(
                        SQLiteJobAuthorizationValidator()
                    )
            )
        )
    }

    private func runUntilTerminal(
        _ job: JobIdentity,
        runtime: DatabaseOperationInstance,
        firstRequestID: UInt64
    ) async throws -> JobStatusOperation.Response {
        var requestID = firstRequestID
        for _ in 0..<64 {
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
        throw SchemaIndexJobRestartTestError.didNotReachTerminalState
    }

    private func indexStatus(
        container: DBContainer
    ) async throws -> DatabaseIndexMaintenanceStatus {
        try await container.testBaseContext().withTransaction { transaction in
            try await DatabaseIndexMaintenanceRuntime(
                container: container
            ).status(
                entity: RestartSchemaBuildAccountV2.persistableType,
                index: "restart_schema_build_account_email",
                partitions: FieldObject(),
                transaction: transaction.executionStorageAccess
            )
        }
    }

    private func invoke<Request: Sendable, Response: Sendable>(
        _ operation: DatabaseOperation<Request, Response>,
        request: Request,
        requestID: UInt64,
        runtime: DatabaseOperationInstance
    ) async throws -> Response {
        #if MultiBase
        let requestBytes = try DatabaseWireEncoder().encodeRequest(
            operation,
            requestID: requestID,
            target: .database,
            metadata: OperationRequestMetadata(),
            request: request
        )
        #else
        let requestBytes = try DatabaseWireEncoder().encodeRequest(
            operation,
            requestID: requestID,
            metadata: OperationRequestMetadata(),
            request: request
        )
        #endif
        let responseBytes = try await DatabaseWireEndpoint(
            instance: runtime
        ).execute(
            requestBytes,
            context: DatabaseRequestExecutionContext(
                authorization: TestBaseEnvironment.authorization,
                jobAuthorizationReference:
                    try SQLiteJobAuthorizationValidator.reference()
            )
        )
        let response = try DatabaseWireDecoder().decodeResponse(
            operation,
            from: responseBytes,
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

private enum SchemaIndexJobRestartTestError: Error {
    case didNotReachTerminalState
}

private actor SQLiteSchemaJobScheduler: DatabaseJobScheduler {
    func ensureWakeUp(noLaterThan timestamp: Timestamp) async throws {
        _ = timestamp
    }
}

private struct SQLiteTestDatabase {
    let directory: URL
    let path: String

    init(prefix: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(prefix)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        self.directory = directory
        self.path = directory.appendingPathComponent("database.sqlite").path
    }

    func remove() {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove SQLite test database: \(error)")
        }
    }
}
#endif
