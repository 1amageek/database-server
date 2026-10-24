import Foundation
import DatabaseKit
import DatabaseServerRuntime
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import StorageKit
import Synchronization
import Testing
@testable import DatabaseServerHost

@Persistable
private struct EntityPolicyAsset {
    #Directory<EntityPolicyAsset>("entity-policy", "assets")

    var id: String = ""
    var title: String = ""
}

@Persistable
private struct EntityPolicyNote {
    #Directory<EntityPolicyNote>("entity-policy", "notes")

    var id: String = ""
    var body: String = ""
}

@Suite("Native entity policies", .serialized, .timeLimit(.minutes(2)))
struct EntityPolicyTests {
    @Test("Closed JSON carries entity and SQL table policies together")
    func configurationCarriesBothPolicyKinds() throws {
        #if !DATABASE_SERVER_HOST_MULTI_BASE
        let document = #"""
            {"formatVersion":3,"storage":{"kind":"sqlite","sqlite":{"mode":"memory"}},
             "databaseRoot":{"kind":"engine"},"host":"127.0.0.1","port":7878,
             "routing":{"databaseID":"main"},
             "tokenRegistryPath":"/unused/tokens.json",
             "entityPolicies":[{"entity":"Asset","roles":{"get":["reader"]}}],
             "sqlTablePolicies":[{"schema":"public","table":"items","roles":{"list":["reader"]}}]}
            """#
        try DatabaseServerLaunchConfigurationJSONValidator.validate(Data(document.utf8))
        let decoded = try JSONDecoder().decode(
            DatabaseServerLaunchConfiguration.self, from: Data(document.utf8))
        #expect(decoded.entityPolicies?.first?.entity == "Asset")
        #expect(decoded.entityPolicies?.first?.roles == ["get": ["reader"]])
        #expect(decoded.sqlTablePolicies?.first?.table == "items")
        #endif
        for invalid in [
            #"{"entityPolicies":[{"entity":"Asset","roles":{"get":["reader"]},"schema":"public"}]}"#,
            #"{"entityPolicies":"Asset"}"#,
        ] {
            #expect(throws: (any Error).self) {
                try DatabaseServerLaunchConfigurationJSONValidator.validate(Data(invalid.utf8))
            }
        }
    }

    #if !DATABASE_SERVER_HOST_MULTI_BASE
    @Test("Entity roles bind entities across schema generations, deny others and survive reopen")
    func publishedEntityRoles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("entity-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { removeDirectory(directory) }
        let storage = NativeDatabaseStorageConfiguration.sqliteFile(
            path: directory.appendingPathComponent("database.sqlite").path)
        let assetRoles = [DatabaseServerLaunchConfiguration.EntityPolicy(
            entity: EntityPolicyAsset.persistableType,
            roles: ["list": ["reader", "curator"], "get": ["reader", "curator"], "create": ["editor"],
                "update": ["curator"], "delete": ["curator"]])]
        let tableRoles = [SQLTablePolicy(schema: "public", table: "items",
            roles: ["list": ["admin"], "get": ["admin"], "create": ["admin"]])]

        let first = try await PolicyRuntime(storage: storage, entityPolicies: assetRoles,
            sqlTablePolicies: tableRoles)
        do {
            try await first.publish([EntityPolicyAsset.self], version: Schema.Version(1, 0, 0))
            _ = try await first.sql(#"INSERT INTO "EntityPolicyAsset"(id, title) VALUES ('a1', 'first')"#,
                token: "editor").get()
            try expectDenied(await first.sql(#"INSERT INTO "EntityPolicyAsset"(id, title) VALUES ('a2', 'second')"#,
                token: "reader"))
            #expect(try await first.titles(token: "reader") == ["first"])
            // Update and delete follow their own role lists.
            for token in ["reader", "editor"] {
                try expectDenied(await first.sql(#"UPDATE "EntityPolicyAsset" SET title = 'denied' WHERE id = 'a1'"#,
                    token: token))
                try expectDenied(await first.sql(#"DELETE FROM "EntityPolicyAsset" WHERE id = 'a1'"#, token: token))
            }
            _ = try await first.sql(#"UPDATE "EntityPolicyAsset" SET title = 'renamed' WHERE id = 'a1'"#,
                token: "curator").get()
            _ = try await first.sql(#"INSERT INTO "EntityPolicyAsset"(id, title) VALUES ('a2', 'second')"#,
                token: "editor").get()
            _ = try await first.sql(#"DELETE FROM "EntityPolicyAsset" WHERE id = 'a2'"#, token: "curator").get()
            #expect(try await first.titles(token: "reader") == ["renamed"])
            // A later schema generation keeps the configured rules and denies the unconfigured entity.
            try await first.publish([EntityPolicyAsset.self, EntityPolicyNote.self], version: Schema.Version(1, 1, 0))
            #expect(try await first.titles(token: "reader") == ["renamed"])
            try expectDenied(await first.sql(#"INSERT INTO "EntityPolicyNote"(id, body) VALUES ('n1', 'note')"#,
                token: "admin"))
            try expectDenied(await first.sql(#"SELECT body FROM "EntityPolicyNote""#, token: "reader"))
            try expectDenied(await first.sql(#"SELECT title FROM "EntityPolicyAsset""#, token: "editor"))
            try expectDenied(await first.sql(#"SELECT title FROM "EntityPolicyAsset""#, token: "admin"))
            try expectDenied(await first.anonymousSQL(#"SELECT title FROM "EntityPolicyAsset""#))
            // Entity grants never reach SQL-owned tables; their table rules decide alone.
            _ = try await first.sql("CREATE TABLE items(value INTEGER); INSERT INTO items VALUES (7);",
                token: "admin").get()
            try expectDenied(await first.sql("SELECT value FROM items", token: "reader"))
            _ = try await first.sql("SELECT value FROM items", token: "admin").get()
        } catch {
            await first.shutdown()
            throw error
        }
        await first.shutdown()

        let reopened = try await PolicyRuntime(storage: storage, entityPolicies: assetRoles,
            sqlTablePolicies: tableRoles)
        do {
            #expect(try await reopened.titles(token: "reader") == ["renamed"])
        } catch {
            await reopened.shutdown()
            throw error
        }
        await reopened.shutdown()

        let unconfigured = try await PolicyRuntime(storage: storage, entityPolicies: [],
            sqlTablePolicies: tableRoles)
        do {
            try expectDenied(await unconfigured.sql(#"SELECT title FROM "EntityPolicyAsset""#, token: "reader"))
        } catch {
            await unconfigured.shutdown()
            throw error
        }
        await unconfigured.shutdown()
    }

    private func expectDenied(_ result: Result<QueryExecuteOperation.Response, RemoteOperationError>) throws {
        switch result {
        case .success: Issue.record("An unconfigured entity, operation or principal was permitted")
        case .failure(let error): #expect(try error.sqlDiagnostic()?.sqlState == "42501")
        }
    }

    private func removeDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Temporary database directory was not removed: \(error)")
        }
    }
    #endif
}

#if !DATABASE_SERVER_HOST_MULTI_BASE
/// Production native composition reached through bearer authentication.
private struct PolicyRuntime {
    let environment: NativeDatabaseRuntimeEnvironment
    let executor: DatabaseServerRequestExecutor
    private let requestIDs = Counter()

    init(
        storage: NativeDatabaseStorageConfiguration,
        entityPolicies: [DatabaseServerLaunchConfiguration.EntityPolicy],
        sqlTablePolicies: [SQLTablePolicy]
    ) async throws {
        environment = try await NativeDatabaseRuntimeEnvironment.open(
            storage: storage, databaseRoot: .engine, authenticator: RoleTokenAuthenticator(),
            version: "entity-policy", sqlTablePolicies: sqlTablePolicies, entityPolicies: entityPolicies)
        executor = environment.makeRequestExecutor(
            routingIdentity: try DatabaseServerRoutingIdentity(databaseID: "main"))
    }

    func publish(_ models: [any Persistable.Type], version: Schema.Version) async throws {
        let manifest = SchemaManifest(schema: try Schema(
            entities: try models.map { try $0.schemaEntity }, version: version))
        let plan = try await call(DatabaseOperationCatalog.schemaExecute, SchemaExecuteOperation.Request(
            invocation: .plan(manifest: manifest, expectedFingerprint: nil)), token: "admin").get()
        guard case .plan(let planned) = plan, let fingerprint = planned.currentFingerprint else {
            throw EntityPolicyTestError.unexpectedSchemaResponse
        }
        let applied = try await call(DatabaseOperationCatalog.schemaExecute, SchemaExecuteOperation.Request(
            invocation: .apply(manifest: manifest, expectedFingerprint: fingerprint,
                idempotencyKey: "entity-policy-publish-\(models.count)")), token: "admin").get()
        switch applied {
        case .applied:
            return
        case .accepted(let job):
            for _ in 0..<128 {
                try await environment.runtime.runScheduledWork()
                let status = try await call(DatabaseOperationCatalog.jobStatus,
                    JobStatusOperation.Request(job: job), token: "admin").get()
                switch status.state {
                case .succeeded: return
                case .failed, .cancelled: throw EntityPolicyTestError.schemaJobFailed
                case .pending, .running, .committingUnsuccessfulOutcome: continue
                }
            }
            throw EntityPolicyTestError.schemaJobFailed
        case .plan:
            throw EntityPolicyTestError.unexpectedSchemaResponse
        }
    }

    func sql(_ source: String, token: String) async throws
        -> Result<QueryExecuteOperation.Response, RemoteOperationError> {
        try await call(DatabaseOperationCatalog.queryExecute,
            QueryExecuteOperation.Request(input: .sql(source)), token: token)
    }

    func anonymousSQL(_ source: String) async throws
        -> Result<QueryExecuteOperation.Response, RemoteOperationError> {
        let requestID = requestIDs.next()
        let frame = try DatabaseWireEncoder().encodeRequest(DatabaseOperationCatalog.queryExecute,
            requestID: requestID, request: QueryExecuteOperation.Request(input: .sql(source)))
        let response = try await environment.runtime.execute(frame,
            authorization: DatabaseRequestExecutionContext(authorization: .anonymous))
        return try DatabaseWireDecoder().decodeResponse(DatabaseOperationCatalog.queryExecute,
            from: response, matching: requestID)
    }

    func titles(token: String) async throws -> [String] {
        let response = try await sql(#"SELECT title FROM "EntityPolicyAsset" ORDER BY title"#,
            token: token).get()
        guard case .rows(let rows) = response.results[0] else {
            throw EntityPolicyTestError.unexpectedSQLResult
        }
        var iterator = rows.makeRowIterator()
        var titles: [String] = []
        while let row = try iterator.next() {
            guard row.values.count == 1, case .primitive(.string(let title)) = row.values[0] else {
                throw EntityPolicyTestError.unexpectedSQLResult
            }
            titles.append(title)
        }
        return titles
    }

    func shutdown() async {
        await environment.shutdown()
    }

    private func call<Request: Sendable, Response: Sendable>(
        _ operation: DatabaseOperation<Request, Response>, _ request: Request, token: String
    ) async throws -> Result<Response, RemoteOperationError> {
        let requestID = requestIDs.next()
        let context = try await executor.authorize(authorizationHeader: "Bearer \(token)",
            databaseID: "main", tenantID: nil, workspaceID: nil)
        let frame = try DatabaseWireEncoder().encodeRequest(operation, requestID: requestID, request: request)
        return try DatabaseWireDecoder().decodeResponse(operation,
            from: try await executor.execute(frame, context: context), matching: requestID)
    }
}

/// Maps each bearer token to a principal holding the role of the same name.
private struct RoleTokenAuthenticator: DatabaseServerAuthenticator {
    func authenticate(_ credential: DatabaseServerCredential) async throws -> DatabaseServerAuthentication {
        guard case .bearer(let token) = credential else {
            throw DatabaseServerAuthenticationError.invalidCredential
        }
        return DatabaseServerAuthentication(authorization: Self.authorization(token),
            jobAuthorizationReference: try DatabaseJobAuthorizationReference(token))
    }

    func revalidate(_ reference: DatabaseJobAuthorizationReference) async throws -> AuthorizationContext {
        Self.authorization(reference.value)
    }

    private static func authorization(_ role: String) -> AuthorizationContext {
        .authenticated(Principal(identifier: "entity-policy-\(role)", roles: [role]))
    }
}

private final class Counter: Sendable {
    private let value = Mutex<UInt64>(0)

    func next() -> UInt64 {
        value.withLock { value in
            value += 1
            return value
        }
    }
}

private enum EntityPolicyTestError: Error {
    case unexpectedSchemaResponse
    case schemaJobFailed
    case unexpectedSQLResult
}
#endif
