#if !DATABASE_SERVER_HOST_MULTI_BASE
@_spi(DatabaseExecution) import Database
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
import DatabaseServerRuntime
import DatabaseServerFoundation
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import Foundation
import QueryAST
import StorageKit
import StorageKitSystemClock
import Testing
@testable import DatabaseServerHost

@Suite("Canonical HTTP query parity", .timeLimit(.minutes(2)))
struct QueryHTTPParityTests {
    @Test("Authenticated SQLite HTTP matches Framework SQL, IR and block frames")
    func completeFramesAndRollback() async throws {
        let environment = try await NativeDatabaseRuntimeEnvironment.open(
            storage: .sqliteMemory, databaseRoot: .engine,
            authenticator: QueryParityAuthenticator(), version: "query-parity",
            sqlTablePolicies: [.init(schema: "public", table: "items",
                roles: ["list": ["admin"], "get": ["admin"], "create": ["admin"]])])
        defer { await environment.shutdown() }
        let container = try await DBContainer.open(for: Schema(entities: []),
            configuration: DBConfiguration(storageEngine: InMemoryEngine(),
                monotonicClock: SystemStorageClock(), wallClock: RealtimeDatabaseWallClock()),
            runtimeConfiguration: DatabaseFrameworkRuntime.configuration(
                executionIdentity: .init(identifier: "query-parity", revision: 1), entityRuntimes: []),
            security: .enabled())
        defer { await container.shutdown() }
        let local = container.newContext(authorization: .authenticated(.init(identifier: "query-parity", roles: ["admin"])))
        let running = AsyncStream.makeStream(of: Int.self)
        defer { running.continuation.finish() }
        let routing = try DatabaseServerRoutingIdentity(databaseID: "main")
        let service = try DatabaseNetworkService(configuration: .init(port: 0, routingIdentity: routing),
            executor: environment.makeRequestExecutor(routingIdentity: routing),
            onServerRunning: { channel in
                if let port = channel.localAddress?.port { running.continuation.yield(port) }
            })
        let task = Task { try await service.run() }
        defer { task.cancel(); _ = await task.result }
        let port = try #require(await running.stream.first(where: { _ in true }))
        let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/v1/database"))
        func remote(_ input: QueryInput) async throws -> ByteString {
            let frame = try DatabaseWireEncoder().encodeRequest(DatabaseOperationCatalog.queryExecute,
                requestID: 101, request: .init(input: input))
            var request = URLRequest(url: endpoint, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("Bearer query-parity", forHTTPHeaderField: "Authorization")
            request.setValue("main", forHTTPHeaderField: "x-database-id")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(frame)
            let (body, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            // Foundation Data does not expose its full retained allocation. This
            // HTTP ownership boundary copies once into a known bounded Wire owner.
            return ByteString(Array(body))
        }
        for text in [
            "SELECT 7::integer AS v, 1.2300::numeric AS v",
            "SELECT '[0:1]={1,2}'::integer[] AS a, NULL::text AS empty",
            "WITH c AS (SELECT 2::integer AS n) SELECT sum(n)::bigint AS total FROM c LIMIT 1",
        ] {
            let statement = try SQLParser(preservesCastOutputNames: true).parse(text)
            for input: QueryInput in [.sql(text), .statement(statement), .block(try SQLBlock(steps: [.statement(statement)]))] {
                let encoded = try await local.executeQueryEncoded(input, requestID: 101)
                #expect(try await remote(input) == encoded.promoteToOutput())
            }
        }
        _ = try DatabaseWireDecoder().decodeResponse(DatabaseOperationCatalog.queryExecute,
            from: await remote(.sql("CREATE TABLE items(id integer UNIQUE)")), matching: 101).get()
        let failed = try DatabaseWireDecoder().decodeResponse(DatabaseOperationCatalog.queryExecute,
            from: await remote(.sql("INSERT INTO items VALUES(1); INSERT INTO items VALUES(1); INSERT INTO items VALUES(2)")), matching: 101)
        guard case .failure(let error) = failed else { Issue.record("Expected full rollback"); return }
        #expect(try error.sqlDiagnostic()?.sqlState == "23505")
        let checked = try DatabaseWireDecoder().decodeResponse(DatabaseOperationCatalog.queryExecute,
            from: await remote(.sql("SELECT count(*) FROM items")), matching: 101).get()
        var rows = checked.rows.makeRowIterator()
        #expect(try rows.next()?.values == [.primitive(.int64(0))])
        task.cancel()
        _ = await task.result
        var stopped = URLRequest(url: endpoint, timeoutInterval: 1)
        stopped.httpMethod = "POST"
        await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(for: stopped) }
    }
}

private struct QueryParityAuthenticator: DatabaseServerAuthenticator {
    func authenticate(_ credential: DatabaseServerCredential) async throws -> DatabaseServerAuthentication {
        guard case .bearer("query-parity") = credential else {
            throw DatabaseServerAuthenticationError.invalidCredential
        }
        return DatabaseServerAuthentication(authorization: authorization,
            jobAuthorizationReference: try DatabaseJobAuthorizationReference("query-parity"))
    }
    func revalidate(_ reference: DatabaseJobAuthorizationReference) async throws -> AuthorizationContext {
        guard reference.value == "query-parity" else { throw DatabaseServerAuthenticationError.invalidCredential }
        return authorization
    }
    private var authorization: AuthorizationContext {
        .authenticated(.init(identifier: "query-parity", roles: ["admin"]))
    }
}
#endif
