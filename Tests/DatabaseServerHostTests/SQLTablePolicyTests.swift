import Foundation
import DatabaseKit
import DatabaseServerRuntime
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import StorageKit
import Testing
@testable import DatabaseServerHost

@Suite("Native logical SQL table policies", .timeLimit(.minutes(2)))
struct SQLTablePolicyTests {
    @Test("Configuration round trips exact SQL targets and defaults to no grants")
    func configurationRoundTrip() throws {
        let policy = SQLTablePolicy(schema: "public", table: "items", roles: ["list": ["reader"]])
        #if DATABASE_SERVER_HOST_MULTI_BASE
        let configuration = DatabaseServerLaunchConfiguration(controlDomain: "local",
            domains: [.init(id: "local", namespace: ["sql-policy"], storage: .init(sqlite: .init(mode: .memory)))],
            placements: [.init(id: "local", domain: "local")], defaultPlacement: "local",
            routing: .init(databaseID: "main"), tokenRegistryPath: "/unused/tokens.json", sqlTablePolicies: [policy])
        #else
        let configuration = DatabaseServerLaunchConfiguration(storage: .init(sqlite: .init(mode: .memory)),
            databaseRoot: .engine, routing: .init(databaseID: "main"), tokenRegistryPath: "/unused/tokens.json",
            sqlTablePolicies: [policy])
        #endif
        let encoded = try JSONEncoder().encode(configuration)
        try DatabaseServerLaunchConfigurationJSONValidator.validate(encoded)
        let decoded = try JSONDecoder().decode(DatabaseServerLaunchConfiguration.self, from: encoded)
        #expect(decoded.sqlTablePolicies?.first?.schema == "public")
        #expect(decoded.sqlTablePolicies?.first?.table == "items")
        #expect(decoded.sqlTablePolicies?.first?.roles == ["list": ["reader"]])
        var document = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        document.removeValue(forKey: "sqlTablePolicies")
        let absent = try JSONDecoder().decode(DatabaseServerLaunchConfiguration.self,
            from: JSONSerialization.data(withJSONObject: document))
        #expect(absent.sqlTablePolicies == nil)
    }

    @Test("Invalid names, duplicate targets and invalid role grants are rejected")
    func invalidPolicies() throws {
        let good = SQLTablePolicy(schema: "public", table: "items", roles: ["list": ["reader"]])
        for policies in [
            [SQLTablePolicy(schema: "", table: "items", roles: [:])],
            [SQLTablePolicy(schema: "public", table: "", roles: [:])],
            [SQLTablePolicy(schema: "public\0", table: "items", roles: [:])],
            [SQLTablePolicy(schema: "public", table: "items\0", roles: [:])],
            [good, good],
            [SQLTablePolicy(schema: "public", table: "items", roles: ["select": ["reader"]])],
            [SQLTablePolicy(schema: "public", table: "items", roles: ["list": []])],
            [SQLTablePolicy(schema: "public", table: "items", roles: ["list": [""]])],
            [SQLTablePolicy(schema: "public", table: "items", roles: ["list": ["reader", "reader"]])],
            [SQLTablePolicy(schema: "public", table: "items", roles: ["list": [String(repeating: "r", count: 257)]])],
            [SQLTablePolicy(schema: "public", table: "items", roles: ["list": (0..<257).map { "r\($0)" }])],
        ] {
            #expect(throws: DatabaseServerLaunchConfigurationError.invalidSQLTablePolicy) {
                try SQLTablePolicy.validate(policies)
            }
        }
        try SQLTablePolicy.validate([SQLTablePolicy(schema: " ", table: " ", roles: [:])])
        try SQLTablePolicy.validate([SQLTablePolicy(schema: "public", table: "items",
            roles: ["list": [String(repeating: "r", count: 256)]])])
        try SQLTablePolicy.validate([SQLTablePolicy(schema: "public", table: "items",
            roles: ["list": (0..<256).map { "r\($0)" }])])
    }

    @Test("Composite target identity preserves case, Unicode bytes and component boundaries")
    func exactTargets() throws {
        let targets = [("public", "caf\u{e9}"), ("public", "cafe\u{301}"),
            ("Public", "caf\u{e9}"), ("a.b", "c"), ("a", "b.c")]
        try SQLTablePolicy.validate(targets.map { SQLTablePolicy(schema: $0.0, table: $0.1, roles: [:]) })
        #expect(Set(targets.map { SQLTablePolicy.Target(schema: $0.0, table: $0.1) }).count == targets.count)
    }

    @Test("Closed JSON rejects unknown target fields and operation names")
    func closedDocument() throws {
        let policies: [[String: Any]] = [
            ["schema": "public", "table": "items", "roles": ["list": ["reader"]], "typo": true],
            ["schema": "public", "table": "items", "roles": ["select": ["reader"]]],
        ]
        for policy in policies {
            let data = try JSONSerialization.data(withJSONObject: ["sqlTablePolicies": [policy]])
            #expect(throws: (any Error).self) { try DatabaseServerLaunchConfigurationJSONValidator.validate(data) }
        }
    }

    #if !DATABASE_SERVER_HOST_MULTI_BASE
    @Test("Native production composition enforces exact targets and operation roles")
    func nativeRolesAndTargets() async throws {
        let runtime = try await open(policies: [SQLTablePolicy(schema: "public", table: "items",
            roles: ["list": ["reader", "admin"], "get": ["reader", "admin"], "create": ["writer", "admin"]])])
        defer { await runtime.shutdown() }
        _ = try await sql("CREATE TABLE items(value INTEGER); INSERT INTO items VALUES (7); CREATE SCHEMA other; CREATE TABLE other.items(value INTEGER);", runtime: runtime).get()
        let selected = try await sql("SELECT value FROM items", runtime: runtime, role: "reader").get()
        guard case .rows(let rows) = selected.results[0] else { Issue.record("Expected native SQL rows"); return }
        var iterator = rows.makeRowIterator()
        #expect(try iterator.next()?.values == [.primitive(.int32(7))])
        try expectDenied(await sql("SELECT value FROM other.items", runtime: runtime))
        try expectDenied(await sql("SELECT value FROM items", runtime: runtime, role: "writer"))
        try expectDenied(await sql("INSERT INTO items VALUES (8)", runtime: runtime, role: "reader"))
        try expectDenied(await sql("SELECT value FROM items", runtime: runtime, role: nil))
    }

    @Test("Native rename requires a new target grant and rollback restores the old policy")
    func nativeRenameAndRollback() async throws {
        let roles = ["list": ["admin"], "get": ["admin"], "create": ["admin"]]
        let runtime = try await open(policies: [SQLTablePolicy(schema: "public", table: "allowed", roles: roles),
            SQLTablePolicy(schema: "moved", table: "items", roles: roles)])
        defer { await runtime.shutdown() }
        _ = try await sql("CREATE TABLE initial(value INTEGER); ALTER TABLE initial RENAME TO allowed; INSERT INTO allowed VALUES (5);", runtime: runtime).get()
        _ = try await sql("SAVEPOINT original; ALTER TABLE allowed RENAME TO blocked; ROLLBACK TO original; SELECT value FROM allowed;", runtime: runtime).get()
        _ = try await sql("ALTER TABLE allowed RENAME TO blocked", runtime: runtime).get()
        try expectDenied(await sql("SELECT value FROM blocked", runtime: runtime))
        _ = try await sql("CREATE SCHEMA initial_schema; CREATE TABLE initial_schema.items(value INTEGER); ALTER SCHEMA initial_schema RENAME TO moved; INSERT INTO moved.items VALUES (6);", runtime: runtime).get()
        _ = try await sql("ALTER SCHEMA moved RENAME TO blocked_schema", runtime: runtime).get()
        try expectDenied(await sql("SELECT value FROM blocked_schema.items", runtime: runtime))
    }

    @Test("An administrator has no default SQL grant and a failed block rolls back its table")
    func nativeDefaultDeny() async throws {
        let runtime = try await open(policies: [])
        defer { await runtime.shutdown() }
        try expectDenied(await sql("CREATE TABLE denied(value INTEGER); INSERT INTO denied VALUES (1);", runtime: runtime))
        switch try await sql("SELECT value FROM denied", runtime: runtime) {
        case .success: Issue.record("A failed SQL block published its table")
        case .failure(let error): #expect(try error.sqlDiagnostic()?.sqlState == "42P01")
        }
    }

    private func open(policies: [SQLTablePolicy]) async throws -> DatabaseHostedRuntime {
        try await DatabaseHostedRuntime.open(application: NativeDatabaseOperationApplicationFactory.schemaDriven(
            version: "s17-policy", sqlTablePolicies: policies), storageEngine: InMemoryEngine(),
            databaseRootPath: [], hostServices: .none)
    }

    private func sql(_ source: String, runtime: DatabaseHostedRuntime, role: String? = "admin") async throws
        -> Result<QueryExecuteOperation.Response, RemoteOperationError> {
        let frame = try DatabaseWireEncoder().encodeRequest(DatabaseOperationCatalog.queryExecute, requestID: 1,
            request: QueryExecuteOperation.Request(input: .sql(source)))
        let authorization = role.map { AuthorizationContext.authenticated(Principal(identifier: "s17-policy", roles: [$0])) }
            ?? .anonymous
        let response = try await runtime.execute(frame, authorization: .init(authorization: authorization))
        return try DatabaseWireDecoder().decodeResponse(DatabaseOperationCatalog.queryExecute, from: response, matching: 1)
    }

    private func expectDenied(_ result: Result<QueryExecuteOperation.Response, RemoteOperationError>) throws {
        switch result {
        case .success: Issue.record("An unconfigured native SQL target or role was permitted")
        case .failure(let error): #expect(try error.sqlDiagnostic()?.sqlState == "42501")
        }
    }
    #endif
}
