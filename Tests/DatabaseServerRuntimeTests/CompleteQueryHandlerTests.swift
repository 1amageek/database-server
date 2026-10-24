@_spi(DatabaseExecution) import Database
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseOperationCore
import DatabaseRuntime
import DatabaseServerFoundation
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import QueryAST
import StorageKit
import Synchronization
import TestSupport
import Testing

@testable import DatabaseServerRuntime

@Suite("Complete SQL operation", .timeLimit(.minutes(2)))
struct CompleteQueryHandlerTests {
    @Test("S17-SRV01 text statement and block retain ordered typed complete outcomes")
    func orderedCompleteOutcomes() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let endpoint = try makeEndpoint(container)
        let response = try await execute(.sql("""
            CREATE TABLE items (id integer, value text);
            COPY items FROM STDIN WITH (FORMAT csv);
            1,one
            2,two
            \\.
            INSERT INTO items VALUES (3, 'three') RETURNING id, value;
            COPY (SELECT id, value FROM items ORDER BY id) TO STDOUT WITH (FORMAT csv);
            SELECT id AS duplicate, value AS duplicate FROM items WHERE FALSE;
            EXPLAIN (FORMAT JSON) SELECT * FROM items;
            """), endpoint: endpoint)
        #expect(response.results.count == 6)
        guard case .command(.createTable, nil) = response.results[0],
              case .command(.copy, 2) = response.results[1],
              case .rows(let returned) = response.results[2],
              case .copy(let exported, 3) = response.results[3],
              case .rows(let empty) = response.results[4],
              case .rows(let explain) = response.results[5] else {
            Issue.record("Expected ordered DDL/COPY/RETURNING/typed rows/EXPLAIN outcomes"); return
        }
        #expect(returned.affectedRows == 1)
        #expect(try values(returned) == [[.primitive(.int32(3)), .primitive(.string("three"))]])
        #expect(exported == ByteString(Array("1,one\n2,two\n3,three\n".utf8)))
        #expect(empty.rowCount == 0)
        #expect(empty.columns.map(\.name) == ["duplicate", "duplicate"])
        #expect(empty.columns.map(\.number) == [1, 2])
        #expect(empty.columns.map(\.type) == [.sql(.integer), .sql(.text)])
        #expect(explain.columns[0].type == .sql(.json))
        let parameter = QueryParameter(position: 1, value: .primitive(.int32(7)), type: .sql(.integer))
        let single = try await execute(.statement(SQLParser().parse("SELECT $1 AS value")),
            parameters: [parameter], endpoint: endpoint)
        let block = try await execute(.block(SQLParser().parseBlock("SELECT $1 AS value; SELECT 8 AS value")),
            parameters: [parameter], endpoint: endpoint)
        guard case .rows(let first) = single.results[0], case .rows(let second) = block.results[0] else {
            Issue.record("Expected semantic inputs to use the same SQL kernel"); return
        }
        #expect(try values(first) == values(second))
        #expect(try await container.testBaseContext().executeSQL("SELECT id FROM items").rows.count == 3)
    }

    @Test("S17-SRV02 exact frame fits and one-byte overflow rolls back data and catalog")
    func frameLimitBeforeCommit() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let payload = String(repeating: "x", count: 4096)
        func sql(_ name: String) -> String {
            "CREATE TABLE \(name) (id integer, value text); INSERT INTO \(name) VALUES (1, '\(payload)') RETURNING value"
        }
        let baseline = try await execute(.sql(sql("baseline")), endpoint: makeEndpoint(container))
        let count = try DatabaseWireEncoder().measureSuccessResponse(
            DatabaseOperationCatalog.queryExecute, requestID: 1, response: baseline)
        let exact = try makeEndpoint(container, responseLimits: wireLimits(frameBytes: count))
        _ = try await execute(.sql(sql("exact")), endpoint: exact)
        let short = try makeEndpoint(container, responseLimits: wireLimits(frameBytes: count - 1))
        let refused = try await failure(.sql(sql("rejected")), endpoint: short)
        #expect(refused.category == .resourceLimit)
        #expect(refused.code == "RESPONSE_RESOURCE_LIMIT")
        #expect(try refused.sqlDiagnostic()?.sqlState == "54000")
        do {
            _ = try await container.testBaseContext().executeEncodedSQLBlock(sql("native_rejected"),
                options: SQLBlockExecutionOptions(checkpointLimits: SQLCheckpointPolicy.limits(
                    for: ExecutionBudget(), structuralLimits: .default, ceiling: nil)),
                encoder: QueryResponseEncoder(requestID: 1, limits: wireLimits(frameBytes: count - 1)))
            Issue.record("Expected actual complete-frame limit failure")
        } catch let error as SQLExecutionFailure {
            #expect(error.diagnostic.sqlState == "54000")
            guard let cause = error.underlyingError as? QueryResponseEncodingError else {
                Issue.record("Expected original response preparation cause"); return
            }
            guard case .resourceLimit(let wireError) = cause else { Issue.record("Expected Wire resource failure"); return }
            #expect(wireError == .frameTooLarge(actual: count, maximum: count - 1))
        }
        #if DATABASE_OPERATIONS_TEST_GRAPH_INDEXES
        let graphPayload = String(repeating: "g", count: 2_000)
        let triples = (0..<8).map { "<urn:s:\($0)> <urn:p> \"\(graphPayload)\" ." }.joined(separator: " ")
        let graph = QueryInput.text(language: .sparql, statement: "CONSTRUCT { \(triples) } WHERE {}")
        let graphContainer = try await makeContainer()
        defer { await graphContainer.shutdown() }
        do {
            let prepared = try await graphContainer.testBaseContext().executeQueryEncoded(graph, requestID: 1)
            _ = try prepared.promoteToOutput()
        } catch {
            Issue.record("Graph baseline failed before response limits: \(String(reflecting: error))")
            return
        }
        let graphFailure = try await failure(graph,
            endpoint: makeEndpoint(graphContainer, responseLimits: wireLimits(frameBytes: 1_024)))
        #expect(graphFailure.category == .resourceLimit)
        #expect(graphFailure.code == "RESPONSE_RESOURCE_LIMIT")
        #endif
        #expect(try await container.testBaseContext().executeSQL("SELECT id FROM exact").rows.count == 1)
        await #expect(throws: (any Error).self) {
            _ = try await container.testBaseContext().executeSQL("SELECT id FROM rejected")
        }
    }

    @Test("S17-SRV03 first errors abort the block while explicit rollback preserves observations")
    func blockRollback() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let endpoint = try makeEndpoint(container)
        _ = try await execute(.sql("CREATE TABLE items (id integer UNIQUE)"), endpoint: endpoint)
        let duplicate = try await failure(.sql("INSERT INTO items VALUES (1); INSERT INTO items VALUES (1)"), endpoint: endpoint)
        #expect(try duplicate.sqlDiagnostic()?.sqlState == "23505")
        #expect(try await container.testBaseContext().executeSQL("SELECT id FROM items").rows.isEmpty)
        let rollback = try await execute(.sql("BEGIN; INSERT INTO items VALUES (2); SELECT id FROM items; ROLLBACK"), endpoint: endpoint)
        guard case .rows(let observed) = rollback.results[2] else { Issue.record("Expected rollback observation"); return }
        #expect(try values(observed) == [[.primitive(.int32(2))]])
        #expect(try await container.testBaseContext().executeSQL("SELECT id FROM items").rows.isEmpty)
    }

    @Test("S17-SRV04 read admission never grants entity writes or Base administration")
    func authorizationRetainsKernelAuthority() async throws {
        let container = try await makeContainer(security: true)
        defer { await container.shutdown() }
        let endpoint = try makeEndpoint(container)
        _ = try await execute(.sql("CREATE TABLE items (id integer); INSERT INTO items VALUES (1)"), endpoint: endpoint)
        let reader = AuthorizationContext.authenticated(Principal(identifier: "reader", roles: ["reader"]))
        #if MultiBase
        try await container.grantTestBaseAccess(to: .principal("reader"), access: .read)
        #endif
        let read = try await execute(.sql("SELECT id FROM items"), endpoint: endpoint, authorization: reader)
        guard case .rows(let rows) = read.results[0] else { Issue.record("Expected authorized read"); return }
        #expect(rows.rowCount == 1)
        let write = try await failure(.sql("INSERT INTO items VALUES (2)"), endpoint: endpoint, authorization: reader)
        #expect(write.category == .authorization)
        let anonymous = try await failure(.sql("SELECT id FROM items"), endpoint: endpoint, authorization: .anonymous)
        #if MultiBase
        #expect(anonymous.category == .authentication)
        #expect(anonymous.code == "AUTHENTICATION_REQUIRED")
        #expect(anonymous.retryability == .never)
        #else
        #expect(anonymous.category == .authorization)
        #endif
        #if MultiBase
        let ddl = try await failure(.sql("CREATE TABLE denied (id integer)"), endpoint: endpoint, authorization: reader)
        #expect(ddl.category == .authorization)
        #endif
        #expect(try await container.testBaseContext().executeSQL("SELECT id FROM items").rows.count == 1)
    }

    @Test("S17-SRV05 SQL diagnostics preserve original Unicode source and semantic absence")
    func typedSourceDiagnostics() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let endpoint = try makeEndpoint(container)
        let text = try await failure(.sql("SELECT '猫';\r\nSELECT missing_column"), endpoint: endpoint)
        #expect(try text.sqlDiagnostic()?.sqlState == "42703")
        #expect(try text.sqlDiagnostic()?.position == 21)
        #expect(try text.sqlDiagnostic()?.column == "missing_column")
        let semantic = try await failure(.statement(SQLParser().parse("SELECT missing_column")), endpoint: endpoint)
        #expect(try semantic.sqlDiagnostic()?.sqlState == "42703")
        #expect(try semantic.sqlDiagnostic()?.position == nil)
        let syntax = try await failure(.sql("SELECT '猫';\r\nSELECT FROM"), endpoint: endpoint)
        #expect(try syntax.sqlDiagnostic()?.sqlState == "42601")
        #expect(try syntax.sqlDiagnostic()?.position == 21)
    }

    @Test("S17-SRV06 cancellation discards prepared output and shutdown waits for real SQL close")
    func cancellationAndShutdown() async throws {
        for cancelled in [true, false] {
            let gate = SQLExecutionCommitGate()
            let container = try await makeContainer(engine: SQLExecutionGatedEngine(gate: gate))
            let instance = try await makeInstance(container)
            let endpoint = DatabaseWireEndpoint(instance: instance)
            await gate.arm()
            let active = Task { try await execute(.sql("CREATE TABLE items (id integer); INSERT INTO items VALUES (1); SELECT id FROM items"), endpoint: endpoint) }
            await gate.waitUntilArrived()
            if cancelled {
                active.cancel()
                await gate.release()
                await #expect(throws: CancellationError.self) { _ = try await active.value }
                let committed = try await container.testBaseContext().executeSQL("SELECT id FROM items")
                #expect(committed.rows.map(\.values) == [[.primitive(.int32(1))]])
                await instance.shutdown()
            } else {
                let finished = Mutex(false)
                let shutdown = Task { await instance.shutdown(); finished.withLock { $0 = true } }
                for _ in 0..<8 { await Task.yield() }
                #expect(!finished.withLock { $0 })
                await gate.release()
                let response = try await active.value
                guard case .rows(let rows) = response.results[2] else { Issue.record("Expected committed rows"); return }
                #expect(try values(rows) == [[.primitive(.int32(1))]])
                await shutdown.value
                #expect(finished.withLock { $0 })
                await #expect(throws: DatabaseOperationInstanceError.shuttingDown) {
                    _ = try await execute(.sql("SELECT 1"), endpoint: endpoint)
                }
            }
        }
    }

    @Test("S17-SRV07 inventory and target admission advertise only supported complete SQL")
    func operationInventoryAndTargets() async throws {
        let container = try await makeContainer()
        let instance = try await makeInstance(container)
        defer { await instance.shutdown() }
        let endpoint = DatabaseWireEndpoint(instance: instance)
        #expect(DatabaseOperationCapabilityCatalog.operations(includesSchemaExecution: false, includesJobs: false).contains(.queryExecute))
        #expect(DatabaseOperationCapabilityCatalog.features(includesSchemaExecution: false, includesJobs: false)
            .contains(.init(identifier: "query.execute", version: 1)))
        let requirement = DatabaseOperationRequirement.canonical(for: .queryExecute)
        #expect(requirement.access == .read)
        #expect(requirement.transaction == .none)
        let response = try await execute(.sql("SELECT 1 AS one"), endpoint: endpoint)
        guard case .rows(let rows) = response.results[0] else { Issue.record("Expected registered SQL handler"); return }
        #expect(rows.rowCount == 1)
        #if MultiBase
        #expect(!requirement.acceptedTargets.contains(.database))
        #expect(requirement.acceptedTargets.contains(.composition))
        let request = try DatabaseWireEncoder().encodeRequest(DatabaseOperationCatalog.queryExecute,
            requestID: 99, target: .database, request: .init(input: .sql("SELECT 1")))
        let result = try await endpoint.execute(request, context: .init(authorization: TestBaseEnvironment.authorization))
        guard case .failure(let rejected) = try DatabaseWireDecoder().decodeResponse(
            DatabaseOperationCatalog.queryExecute, from: result, matching: 99) else {
            Issue.record("Expected database target rejection in MultiBase"); return
        }
        #expect(rejected.code == "TARGET_KIND_NOT_ACCEPTED")
        #endif
    }

    @Test("SQL wrapper preserves existing failure category retryability and commit uncertainty")
    func diagnosticPreservesUnderlyingMapping() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let context = try mappingContext(container)
        let error = DatabaseContextError.commitOutcomeUnknown
        let mapped = CanonicalDatabaseErrorMapper().remoteError(for: SQLExecutionFailure(
            underlyingError: error,
            diagnostic: try SQLDiagnostic(sqlState: "40003", category: .transaction, message: "Commit outcome is unknown")
        ), context: context)
        #expect(mapped.category == .unavailable)
        #expect(mapped.code == "COMMIT_OUTCOME_UNKNOWN")
        #expect(mapped.retryability == .immediate)
        #expect(try mapped.sqlDiagnostic()?.sqlState == "40003")
        let resource = CanonicalDatabaseErrorMapper().remoteError(for: SQLExecutionFailure(
            underlyingError: DatabaseResponsePreparationError(wireError: .frameTooLarge(actual: 2, maximum: 1)),
            diagnostic: try SQLDiagnostic(sqlState: "XX000", category: .internalError, message: "Native cause retained")
        ), context: context)
        #expect(resource.category == .resourceLimit)
        #expect(resource.code == "RESPONSE_RESOURCE_LIMIT")
        let catalogFailures: [(SQLCatalogBindingError, OperationErrorCategory, String, String)] = [
            (.invalidSQLOwnership("private-entity"), .internalFailure, "SQL_CATALOG_INVALID", "The SQL catalog is invalid"),
            (.protectedConstraintsChanged("private-relation"), .conflict, "SQL_CATALOG_INCOMPATIBLE", "The SQL catalog change violates an existing contract"),
            (.protectedColumnPolicyChanged(relation: "private-relation", column: "private-column"), .conflict, "SQL_CATALOG_INCOMPATIBLE", "The SQL catalog change violates an existing contract"),
            (.protectedColumnAdded(relation: "private-relation", column: "private-column"), .conflict, "SQL_CATALOG_INCOMPATIBLE", "The SQL catalog change violates an existing contract"),
            (.protectedSequenceChanged("private-sequence"), .conflict, "SQL_CATALOG_INCOMPATIBLE", "The SQL catalog change violates an existing contract"),
        ]
        for (cause, category, code, message) in catalogFailures {
            let mapper = CanonicalDatabaseErrorMapper()
            let direct = mapper.remoteError(for: cause, context: context)
            #expect(direct.category == category)
            #expect(direct.code == code)
            #expect(direct.message == message)
            #expect(direct.retryability == .never)
            let wrapped = mapper.remoteError(for: SQLExecutionFailure(
                underlyingError: cause, diagnostic: SQLDiagnostics.diagnostic(for: cause)
            ), context: context)
            #expect(wrapped.category == category)
            #expect(wrapped.code == code)
            #expect(wrapped.message == message)
            #expect(wrapped.retryability == .never)
            #expect(try wrapped.sqlDiagnostic()?.sqlState == "XX000")
            #expect(try wrapped.sqlDiagnostic()?.position == nil)
        }
    }

    @Test("Cancellation with cleanup failure remains a typed composite failure")
    func diagnosticRetainsCleanupFailure() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let context = try mappingContext(container)
        let error = DatabaseReadSessionCleanupError(operationError: CancellationError(), cleanupError: SQLBlockExecutionError.unsupportedStatement)
        let mapped = CanonicalDatabaseErrorMapper().remoteError(for: SQLExecutionFailure(
            underlyingError: error, diagnostic: SQLDiagnostics.diagnostic(for: error)), context: context)
        #expect(mapped.category == .internalFailure)
        #expect(mapped.code == "SQL_EXECUTION_CLEANUP_FAILURE")
        #expect(mapped.details["operationError"] != nil)
        #expect(mapped.details["cleanupError"] != nil)
        if case .object(let operation)? = mapped.details["operationError"] {
            #expect(operation["code"] == .string("OPERATION_CANCELLED"))
        } else { Issue.record("Expected preserved cancellation cause") }
        #expect(try mapped.sqlDiagnostic()?.sqlState == "57014")
    }

    @Test("Checkpoint limits derive from request bounds and explicit ceilings only reduce them")
    func checkpointPolicy() throws {
        let budget = ExecutionBudget(maximumRows: 10, maximumWorkUnits: 100,
            maximumIntermediateRows: 20, maximumIntermediateBytes: 2000, timeoutMilliseconds: 1000)
        let structural = QueryStructuralLimits(maximumCollectionElements: 30)
        let derived = try SQLCheckpointPolicy.limits(for: budget, structuralLimits: structural, ceiling: nil)
        #expect(derived.maximumEntries == 100)
        #expect(derived.maximumDepth == 30)
        #expect(derived.maximumRetainedBytes == 2000)
        #expect(derived.maximumWorkUnits == 100)
        #expect(derived.maximumReadPageRows == 20)
        let ceiling = try TransactionCheckpointLimits(maximumEntries: 40, maximumDepth: 10,
            maximumRetainedBytes: 1000, maximumWorkUnits: 50, maximumReadPageRows: 100)
        let limited = try SQLCheckpointPolicy.limits(for: budget, structuralLimits: structural, ceiling: ceiling)
        #expect(limited.maximumEntries == 40)
        #expect(limited.maximumDepth == 10)
        #expect(limited.maximumRetainedBytes == 1000)
        #expect(limited.maximumWorkUnits == 50)
        #expect(limited.maximumReadPageRows == 20)
    }

    @Test("SQL, IR and blocks publish exactly the Framework complete frame")
    func completeRepresentationAgreement() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let endpoint = try makeEndpoint(container)
        let data = container.testBaseContext()
        for text in [
            "SELECT 7::integer AS v, 1.2300::numeric AS v",
            "SELECT '[0:1]={1,2}'::integer[] AS a, NULL::text AS empty",
            "WITH c AS (SELECT 2::integer AS n) SELECT sum(n)::bigint AS total FROM c LIMIT 1",
            "SELECT n, row_number() OVER (ORDER BY n) AS ordinal FROM (VALUES (2),(1)) AS v(n) ORDER BY n",
        ] {
            let statement = try SQLParser(preservesCastOutputNames: true).parse(text)
            var expected: ByteString?
            for input: QueryInput in [.sql(text), .statement(statement), .block(try SQLBlock(steps: [.statement(statement)]))] {
                let local = try await data.executeQueryEncoded(input, requestID: 1)
                let localFrame = try local.promoteToOutput()
                let remote = try await endpoint.execute(frame(input, parameters: []),
                    context: .init(authorization: TestBaseEnvironment.authorization))
                #expect(remote == localFrame)
                if let expected { #expect(remote == expected) } else { expected = remote }
            }
        }
    }

    @Test("Explicit pages reject mutations, writable WITH and sequence effects before execution")
    func pagedEffectsNeverRun() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let endpoint = try makeEndpoint(container)
        _ = try await execute(.sql("CREATE TABLE items(id integer); CREATE SEQUENCE counter"), endpoint: endpoint)
        for input: QueryInput in [
            .sql("INSERT INTO items VALUES (1) RETURNING id"),
            .sql("WITH changed AS (INSERT INTO items VALUES (2) RETURNING id) SELECT id FROM changed"),
            .sql("SELECT nextval('counter')"),
            .block(try SQLBlock(steps: [.statement(try SQLParser().parse("INSERT INTO items VALUES (3)"))])),
        ] {
            let request = QueryExecuteOperation.Request(input: input, page: .init(limit: 1))
            #if MultiBase
            let bytes = try DatabaseWireEncoder().encodeRequest(DatabaseOperationCatalog.queryExecute,
                requestID: 1, target: .base(TestBaseEnvironment.id()), request: request)
            #else
            let bytes = try DatabaseWireEncoder().encodeRequest(DatabaseOperationCatalog.queryExecute,
                requestID: 1, request: request)
            #endif
            let response = try await endpoint.execute(bytes, context: .init(authorization: TestBaseEnvironment.authorization))
            guard case .failure = try DatabaseWireDecoder().decodeResponse(DatabaseOperationCatalog.queryExecute,
                from: response, matching: 1) else { Issue.record("Effectful paging was admitted"); continue }
        }
        let count = try await execute(.sql("SELECT count(*) FROM items"), endpoint: endpoint)
        #expect(try values(count.rows) == [[.primitive(.int64(0))]])
        let next = try await execute(.sql("SELECT nextval('counter')"), endpoint: endpoint)
        #expect(try values(next.rows) == [[.primitive(.int64(1))]])
    }

    private func makeContainer(engine: any StorageEngine = InMemoryEngine(), security: Bool = false) async throws -> DBContainer {
        let runtime = try DatabaseFrameworkRuntime.configuration(executionIdentity: .init(identifier: "s17-server", revision: 1),
            entityRuntimes: [], schemaDrivenAuthorizationPolicyFactory: { entity in
                AuthorizationPolicyHandler(schemaDriven: entity) { operation, authorization in
                    guard let roles = authorization.principal?.roles else { return false }
                    return roles.contains("test-runner") || (roles.contains("reader") && (operation == .list || operation == .get))
                }
            })
        return try await DBContainer.open(for: Schema(entities: []),
            configuration: .testing(storageEngine: engine), runtimeConfiguration: runtime,
            security: security ? .enabled() : .testingDisabled)
    }

    private func makeInstance(_ container: DBContainer) async throws -> DatabaseOperationInstance {
        let generator = RandomDatabaseUUIDGenerator()
        let factory = CanonicalDatabaseOperationServiceFactory(
            maintenanceServiceFactory: DatabaseMaintenanceOperationServiceFactory(identifierGenerator: generator),
            jobServiceFactory: try DatabasePersistentJobServiceFactory(registry: DatabaseResumableOperationRegistry(operations: []),
                identifierGenerator: generator, storageLimits: .init(maximumStorageValueBytes: 1_000_000)))
        return try await DatabaseOperationInstance.open(container: container,
            configuration: DatabaseOperationConfiguration(identity: .init(version: "s17-test"),
                serviceFactory: AnyDatabaseOperationServiceFactory(factory),
                admissionPolicy: AnyDatabaseOperationAdmissionPolicy(UnrestrictedDatabaseOperationAdmissionPolicy())))
    }

    private func makeEndpoint(_ container: DBContainer, responseLimits: DatabaseWireLimits = .default) throws -> DatabaseWireEndpoint {
        let registry = try DatabaseOperationRegistry(handlers: [AnyDatabaseOperationHandler(QueryExecuteHandler())], requiredOperations: [.queryExecute])
        return DatabaseWireEndpoint(container: container, registry: registry,
            admissionPolicy: AnyDatabaseOperationAdmissionPolicy(UnrestrictedDatabaseOperationAdmissionPolicy()),
            responseLimits: responseLimits)
    }

    private func frame(_ input: QueryInput, parameters: [QueryParameter]) throws -> ByteString {
        let request = QueryExecuteOperation.Request(input: input, parameters: parameters)
        #if MultiBase
        return try DatabaseWireEncoder().encodeRequest(DatabaseOperationCatalog.queryExecute, requestID: 1,
            target: .base(TestBaseEnvironment.id()), request: request)
        #else
        return try DatabaseWireEncoder().encodeRequest(DatabaseOperationCatalog.queryExecute, requestID: 1, request: request)
        #endif
    }

    private func execute(_ input: QueryInput, parameters: [QueryParameter] = [],
        endpoint: DatabaseWireEndpoint, authorization: AuthorizationContext = TestBaseEnvironment.authorization
    ) async throws -> QueryExecuteOperation.Response {
        let bytes = try await endpoint.execute(frame(input, parameters: parameters), context: .init(authorization: authorization))
        return try DatabaseWireDecoder().decodeResponse(DatabaseOperationCatalog.queryExecute, from: bytes, matching: 1).get()
    }

    private func failure(_ input: QueryInput, endpoint: DatabaseWireEndpoint,
        authorization: AuthorizationContext = TestBaseEnvironment.authorization
    ) async throws -> RemoteOperationError {
        let bytes = try await endpoint.execute(frame(input, parameters: []), context: .init(authorization: authorization))
        switch try DatabaseWireDecoder().decodeResponse(DatabaseOperationCatalog.queryExecute, from: bytes, matching: 1) {
        case .failure(let error): return error
        case .success: throw ExpectedSQLFailure()
        }
    }

    private func values(_ rows: QueryRowPage) throws -> [[QueryValue]] {
        var result: [[QueryValue]] = []
        var iterator = rows.makeRowIterator()
        while let row = try iterator.next() { result.append(row.values) }
        return result
    }

    private func wireLimits(frameBytes: Int) throws -> DatabaseWireLimits {
        let limits = DatabaseWireLimits.default
        return try DatabaseWireLimits(maximumFrameBytes: frameBytes, maximumStringBytes: limits.maximumStringBytes,
            maximumByteStringBytes: limits.maximumByteStringBytes, maximumCollectionCount: limits.maximumCollectionCount,
            maximumNestingDepth: limits.maximumNestingDepth, maximumObjectCount: limits.maximumObjectCount)
    }

    private func mappingContext(_ container: DBContainer) throws -> DatabaseOperationContext {
        #if MultiBase
        return DatabaseOperationContext(container: container, target: .base(try TestBaseEnvironment.id()),
            requirement: .canonical(for: .queryExecute), requestID: 1, metadata: .init(),
            authorization: TestBaseEnvironment.authorization, requestPayload: [], wireLimits: .default)
        #else
        return DatabaseOperationContext(container: container, requirement: .canonical(for: .queryExecute),
            requestID: 1, metadata: .init(), authorization: TestBaseEnvironment.authorization,
            requestPayload: [], wireLimits: .default)
        #endif
    }

    private struct ExpectedSQLFailure: Error {}
}
