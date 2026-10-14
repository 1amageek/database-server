@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseOperationCore
import DatabaseQueryOperations
import DatabaseRuntime
import DatabaseServerFoundation
import DatabaseServerRuntime
import DatabaseTypes
import DatabaseWire
import StorageKit
import TestSupport
import Testing

@Suite("Canonical query continuation endpoint", .serialized)
struct DatabaseQueryContinuationEndpointTests {
    @Test("positional duplicate labels survive first and durable continuation pages")
    func duplicateLabelsSurviveContinuation() async throws {
        let endpoint = try await makeEndpoint()
        let query = SelectQuery(
            projection: .items([
                ProjectionItem(.col("id"), alias: "duplicate"),
                ProjectionItem(.col("title"), alias: "duplicate"),
            ]),
            source: .table(TableRef(DatabaseEndpointEntity.persistableType)),
            orderBy: [SortKey(.col("id"))]
        )
        let first = try await successfulPage(request(query: query, pageLimit: 2), requestID: 100, endpoint: endpoint)
        let continuation = try #require(first.continuation)
        let second = try await successfulPage(
            request(query: query, pageLimit: 2, continuation: continuation),
            requestID: 101, endpoint: endpoint
        )
        #expect(first.columns.map(\.name) == ["duplicate", "duplicate"])
        #expect(first.columns.map(\.number) == [1, 2])
        #expect(first.columns == second.columns)
        #expect(try first.materializedRows(maximumCount: 2).first?.values == [
            .primitive(.string("entity-0")), .primitive(.string("Title 0")),
        ])
        #expect(try second.materializedRows(maximumCount: 2).first?.values == [
            .primitive(.string("entity-2")), .primitive(.string("Title 2")),
        ])
    }

    @Test("an empty result retains ordered typed columns")
    func emptyResultRetainsTypedColumns() async throws {
        let endpoint = try await makeEndpoint()
        let query = SelectQuery(
            projection: .items([
                ProjectionItem(.col("priority"), alias: "z"),
                ProjectionItem(.col("id"), alias: "a"),
            ]),
            source: .table(TableRef(DatabaseEndpointEntity.persistableType)),
            filter: .equal(.col("id"), .string("missing"))
        )
        let page = try await successfulPage(request(query: query, pageLimit: 2), requestID: 102, endpoint: endpoint)
        #expect(page.rowCount == 0)
        #expect(page.columns.map(\.name) == ["z", "a"])
        #expect(page.columns.map(\.type) == [.primitive(.int64), .primitive(.string)])
        #expect(page.columns.map(\.isNullable) == [false, false])
        #expect(page.continuation == nil)
    }

    @Test("rich positional values and typmods survive durable paging")
    func richValuesSurviveDurablePaging() async throws {
        let endpoint = try await makeEndpoint()
        let limits = QueryValueLimits(maximumRetainedBytes: 1_024 * 1_024,
                                      maximumTotalNodes: 1_000, maximumNestingDepth: 16,
                                      maximumCollectionElements: 1_000)
        let json = try QueryJSONValue(bytes: ByteString(Array(" { \"a\": 1 } ".utf8)), limits: limits)
        let numeric = try QueryNumericValue(value: ExactDecimal(coefficient: 123, scale: 2), displayScale: 4)
        let array = try QueryArrayValue(
            elementType: .integer,
            dimensions: [QueryArrayDimension(lowerBound: -2, length: 2)],
            elements: [.primitive(.int32(7)), .primitive(.null)], limits: limits
        )
        let interval = try QueryIntervalValue(period: CalendarPeriod(months: 2, days: 3), time: TimeSpan(seconds: 4))
        let values: [QueryValue] = [.numeric(numeric), .json(json), .jsonb(try QueryJSONBValue(json: json, limits: limits)), .array(array), .interval(interval)]
        let types: [QueryColumnType] = [.sql(.decimal(precision: nil, scale: nil)), .sql(.json), .sql(.jsonb), .sql(.array(.integer)), .sql(.interval)]
        let query = SelectQuery(
            projection: .items(zip(values, types).enumerated().map { index, pair in
                ProjectionItem(.literal(.queryValue(pair.0, type: pair.1)), alias: "rich-\(index)")
            }),
            source: .table(TableRef(DatabaseEndpointEntity.persistableType))
        )
        let first = try await successfulPage(request(query: query, pageLimit: 2), requestID: 103, endpoint: endpoint)
        let continuation = try #require(first.continuation)
        let second = try await successfulPage(
            request(query: query, pageLimit: 2, continuation: continuation),
            requestID: 104, endpoint: endpoint
        )
        #expect(first.columns.map(\.type) == types)
        #expect(first.columns == second.columns)
        for page in [first, second] {
            for row in try page.materializedRows(maximumCount: 2) { #expect(row.values == values) }
        }
    }

    @Test("a backend without historical reads serves a durable continuation")
    func nonHistoricalBackendUsesDurableContinuation() async throws {
        let endpoint = try await makeEndpoint()
        let query = tableQuery()

        let first = try await successfulPage(
            request(query: query, pageLimit: 2),
            requestID: 1,
            endpoint: endpoint
        )
        let continuation = try #require(first.continuation)
        #if MultiBase
        guard case .transactional(let readPoint) = first.consistency else {
            Issue.record("Expected one transactional read point")
            return
        }
        guard case .version = readPoint.position else {
            Issue.record("Expected the in-memory backend to report its current version")
            return
        }
        #else
        _ = try #require(first.snapshotVersion)
        #endif

        let second = try await successfulPage(
            request(
                query: query,
                pageLimit: 2,
                continuation: continuation
            ),
            requestID: 2,
            endpoint: endpoint
        )
        #expect(
            try second.materializedRows(maximumCount: 2).map {
                try identifier(from: $0, columns: second.columns)
            } == ["entity-2", "entity-3"]
        )
        #expect(second.continuation == nil)

        let complete = try await successfulPage(
            request(query: query, pageLimit: 4),
            requestID: 3,
            endpoint: endpoint
        )
        let rows = try complete.materializedRows(maximumCount: 4)
        let identifiers = try rows.map {
            try identifier(from: $0, columns: complete.columns)
        }
        #expect(identifiers == ["entity-0", "entity-1", "entity-2", "entity-3"])
        #expect(Set(identifiers).count == identifiers.count)
        #expect(complete.continuation == nil)
    }

    @Test("a continuation is rejected for a different canonical QueryIR")
    func continuationRejectsDifferentQueryIR() async throws {
        let endpoint = try await makeEndpoint()
        let first = try await successfulPage(
            request(query: tableQuery(), pageLimit: 1),
            requestID: 10,
            endpoint: endpoint
        )
        let continuation = try #require(first.continuation)

        let error = try await remoteFailure(
            request(
                query: tableQuery(distinct: true),
                pageLimit: 1,
                continuation: continuation
            ),
            requestID: 11,
            endpoint: endpoint
        )

        expectInvalidContinuation(error)
    }

    @Test("a continuation is rejected for a different partition selection")
    func continuationRejectsDifferentPartitionSelection() async throws {
        let endpoint = try await makeEndpoint()
        let first = try await successfulPage(
            request(
                query: partitionedGraphQuery(),
                graphPartitions: try partition("calendar-a"),
                pageLimit: 1
            ),
            requestID: 20,
            endpoint: endpoint
        )
        let continuation = try #require(first.continuation)

        let error = try await remoteFailure(
            request(
                query: partitionedGraphQuery(),
                graphPartitions: try partition("calendar-b"),
                pageLimit: 1,
                continuation: continuation
            ),
            requestID: 21,
            endpoint: endpoint
        )

        expectInvalidContinuation(error)
    }

    @Test("a durable continuation retains the materialized result after writes")
    func continuationRetainsMaterializedResult() async throws {
        let container = try await makeContainer(seedCount: 3)
        let endpoint = try makeEndpoint(container: container)
        let query = tableQuery()
        let first = try await successfulPage(
            request(query: query, pageLimit: 1),
            requestID: 30,
            endpoint: endpoint
        )
        let continuation = try #require(first.continuation)

        let context = container.testBaseContext()
        var inserted = DatabaseEndpointEntity()
        inserted.id = "entity-added"
        inserted.title = "Added after the first page"
        inserted.priority = 100
        try context.insert(inserted)
        try await context.save()

        let second = try await successfulPage(
            request(
                query: query,
                pageLimit: 1,
                continuation: continuation
            ),
            requestID: 31,
            endpoint: endpoint
        )
        #expect(
            try identifier(
                from: second.materializedRows(maximumCount: 1)[0],
                columns: second.columns
            ) == "entity-1"
        )
        let thirdContinuation = try #require(second.continuation)
        let third = try await successfulPage(
            request(
                query: query,
                pageLimit: 1,
                continuation: thirdContinuation
            ),
            requestID: 32,
            endpoint: endpoint
        )
        #expect(
            try identifier(
                from: third.materializedRows(maximumCount: 1)[0],
                columns: third.columns
            ) == "entity-2"
        )
        #expect(third.continuation == nil)
    }

    @Test("an execution identity change makes durable continuations stale")
    func executionIdentityChangeMakesContinuationStale() async throws {
        let container = try await makeContainer(seedCount: 3)
        let endpoint = try makeEndpoint(container: container)
        let query = tableQuery()
        let firstGeneration = container.schemaGeneration
        let first = try await successfulPage(
            request(query: query, pageLimit: 1),
            requestID: 33,
            endpoint: endpoint
        )
        let continuation = try #require(first.continuation)
        let schema = container.schema
        let nextRuntime = try DatabaseFrameworkRuntime.configuration(
            executionIdentity: DatabaseExecutionRuntimeIdentity(
                identifier: "database-query-continuation-tests",
                revision: 2
            ),
            entityRuntimes: [
                try DatabaseFrameworkRuntime.entity(
                    DatabaseEndpointEntity.self
                ),
                try DatabaseFrameworkRuntime.entity(
                    DatabasePartitionedGraphQueryStatement.self
                ),
            ]
        )
        let publication = try await container.publishSchema(
            schema,
            fingerprint: try SchemaManifest(schema: schema).fingerprint(),
            expectedFingerprint: container.schemaFingerprint.detached(),
            idempotencyKey: "execution-identity-continuation-invalidation",
            authorization: TestBaseEnvironment.authorization,
            runtimeConfiguration: nextRuntime
        )
        #expect(publication.generation == firstGeneration + 1)

        let error = try await remoteFailure(
            request(
                query: query,
                pageLimit: 1,
                continuation: continuation
            ),
            requestID: 34,
            endpoint: endpoint
        )
        #expect(error.category == .conflict)
        #expect(error.code == "QUERY_SNAPSHOT_STALE")
        #expect(error.retryability == .never)
    }

    @Test("malformed binary continuation bytes are rejected")
    func malformedContinuationFrameIsRejected() async throws {
        let endpoint = try await makeEndpoint()

        let error = try await remoteFailure(
            request(
                query: tableQuery(),
                pageLimit: 1,
                continuation: [0x43, 0x51, 0x50]
            ),
            requestID: 40,
            endpoint: endpoint
        )

        expectInvalidContinuation(error)
    }

    private func makeEndpoint() async throws -> DatabaseWireEndpoint {
        let container = try await makeContainer()
        return try makeEndpoint(container: container)
    }

    private func makeEndpoint(container: DBContainer) throws -> DatabaseWireEndpoint {
        let snapshotStore = DatabaseQuerySnapshotStore(
            container: container,
            clock: AnyDatabaseWallClock(RealtimeDatabaseWallClock()),
            identifierGenerator: AnyDatabaseUUIDGenerator(
                RandomDatabaseUUIDGenerator()
            ),
            scheduler: AnyDatabaseJobScheduler(
                ContinuationSnapshotScheduler()
            ),
            wireLimits: .default
        )
        let registry = try DatabaseOperationRegistry(
            handlers: [
                AnyDatabaseOperationHandler(
                    QueryExecuteHandler(
                        runtimeLimits: .default,
                        querySnapshotStore: snapshotStore
                    )
                )
            ],
            requiredOperations: [.queryExecute]
        )
        return DatabaseWireEndpoint(
            container: container,
            registry: registry,
            admissionPolicy: AnyDatabaseOperationAdmissionPolicy(
                UnrestrictedDatabaseOperationAdmissionPolicy()
            )
        )
    }

    private func makeContainer(seedCount: Int = 4) async throws -> DBContainer {
        let container = try await DBContainer.open(
            for: try Schema(
                entities: [
                    try DatabaseEndpointEntity.schemaEntity,
                    try DatabasePartitionedGraphQueryStatement.schemaEntity,
                ],
                version: Schema.Version(1, 0, 0)
            ),
            configuration: DBConfiguration.testing(storageEngine: InMemoryEngine()),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-query-continuation-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(DatabaseEndpointEntity.self),
                    try DatabaseFrameworkRuntime.entity(
                        DatabasePartitionedGraphQueryStatement.self
                    ),
                ]
            ),
            security: .testingDisabled
        )
        guard seedCount > 0 else {
            return container
        }
        let context = container.testBaseContext()
        for index in 0..<seedCount {
            var entity = DatabaseEndpointEntity()
            entity.id = "entity-\(index)"
            entity.title = "Title \(index)"
            entity.priority = Int64(index)
            try context.insert(entity)
        }
        for index in 0..<2 {
            try context.insert(
                partitionedGraphStatement(
                    id: "calendar-a-\(index)",
                    calendar: "calendar-a",
                    subject: "urn:calendar-a:\(index)"
                )
            )
        }
        try context.insert(
            partitionedGraphStatement(
                id: "calendar-b-0",
                calendar: "calendar-b",
                subject: "urn:calendar-b:0"
            )
        )
        try await context.save()
        return container
    }

    private func tableQuery(distinct: Bool = false) -> SelectQuery {
        SelectQuery(
            projection: .all,
            source: .table(TableRef(DatabaseEndpointEntity.persistableType)),
            distinct: distinct
        )
    }

    private func partitionedGraphQuery() -> SelectQuery {
        SelectQuery(
            projection: .items([
                ProjectionItem(.variable(Variable("subject")))
            ]),
            source: .graphPattern(
                .basic([
                    TriplePattern(
                        subject: .variable("subject"),
                        predicate: .iri("urn:calendar-entry"),
                        object: .variable("object")
                    )
                ])
            ),
            orderBy: [SortKey(.variable(Variable("subject")))]
        )
    }

    private func partitionedGraphStatement(
        id: String,
        calendar: String,
        subject: String
    ) throws -> DatabasePartitionedGraphQueryStatement {
        DatabasePartitionedGraphQueryStatement(
            id: id,
            calendar: calendar,
            subject: try .iri(validating: subject),
            predicate: try .iri(validating: "urn:calendar-entry"),
            object: try .iri(validating: "urn:event:\(id)"),
            graph: nil
        )
    }

    private func request(
        query: SelectQuery,
        graphPartitions: FieldObject = FieldObject(),
        pageLimit: UInt32,
        continuation: ByteString? = nil
    ) -> QueryExecuteOperation.Request {
        QueryExecuteOperation.Request(
            input: .ir(.select(query)),
            graphPartitions: graphPartitions,
            page: QueryExecuteOperation.Page(
                limit: pageLimit,
                continuation: continuation
            )
        )
    }

    private func partition(_ value: String) throws -> FieldObject {
        try FieldObject([
            (key: "calendar", value: .string(value))
        ])
    }

    private func successfulPage(
        _ request: QueryExecuteOperation.Request,
        requestID: UInt64,
        endpoint: DatabaseWireEndpoint
    ) async throws -> QueryRowPage {
        let response = try await execute(
            request,
            requestID: requestID,
            endpoint: endpoint
        )
        switch response {
        case .success(let value):
            let response = value
            guard case .rows(let page) = response else {
                Issue.record("Expected a row page response")
                throw ContinuationEndpointAssertionError.unexpectedResponse
            }
            return page
        case .failure(let error):
            Issue.record("Expected success, received \(error.code): \(error.message)")
            throw ContinuationEndpointAssertionError.unexpectedResponse
        }
    }

    private func remoteFailure(
        _ request: QueryExecuteOperation.Request,
        requestID: UInt64,
        endpoint: DatabaseWireEndpoint
    ) async throws -> RemoteOperationError {
        let response = try await execute(
            request,
            requestID: requestID,
            endpoint: endpoint
        )
        switch response {
        case .failure(let error):
            return error
        case .success:
            Issue.record("Expected the endpoint to return a remote failure")
            throw ContinuationEndpointAssertionError.unexpectedResponse
        }
    }

    private func execute(
        _ request: QueryExecuteOperation.Request,
        requestID: UInt64,
        endpoint: DatabaseWireEndpoint
    ) async throws -> Result<
        QueryExecuteOperation.Response,
        RemoteOperationError
    > {
        #if MultiBase
        let requestFrame = try DatabaseWireEncoder().encodeRequest(
            DatabaseOperationCatalog.queryExecute,
            requestID: requestID,
            target: try testDataRootTarget(),
            metadata: OperationRequestMetadata(),
            request: request
        )
        #else
        let requestFrame = try DatabaseWireEncoder().encodeRequest(
            DatabaseOperationCatalog.queryExecute,
            requestID: requestID,
            metadata: OperationRequestMetadata(),
            request: request
        )
        #endif
        let responseFrame = try await endpoint.execute(
            requestFrame,
            context: DatabaseRequestExecutionContext(
                authorization: TestBaseEnvironment.authorization
            )
        )
        let decoder = DatabaseWireDecoder()
        let header = try decoder.decodeResponseHeader(responseFrame)
        #expect(header.requestID == requestID)
        #expect(header.operation == .queryExecute)
        return try decoder.decodeResponse(
            DatabaseOperationCatalog.queryExecute,
            from: responseFrame,
            matching: requestID
        )
    }

    private func identifier(
        from row: DatabaseWire.QueryRow,
        columns: [QueryColumn]
    ) throws -> String {
        guard let index = columns.firstIndex(where: { $0.name == "id" }),
              row.values.indices.contains(index),
              case .primitive(.string(let identifier)) = row.values[index] else {
            Issue.record("Expected each row to contain a string id")
            throw ContinuationEndpointAssertionError.missingIdentifier
        }
        return identifier
    }

    private func expectInvalidContinuation(_ error: RemoteOperationError) {
        #expect(error.category == .invalidRequest)
        #expect(error.code == "INVALID_CONTINUATION")
        #expect(error.retryability == .never)
    }
}

private enum ContinuationEndpointAssertionError: Error {
    case missingIdentifier
    case unexpectedResponse
}

private actor ContinuationSnapshotScheduler: DatabaseJobScheduler {
    func ensureWakeUp(noLaterThan deadline: Timestamp) async throws {
        _ = deadline
    }
}
