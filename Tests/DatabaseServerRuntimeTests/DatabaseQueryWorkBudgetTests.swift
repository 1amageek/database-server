@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
import DatabaseServerFoundation
import DatabaseServerRuntime
import DatabaseTypes
import DatabaseWire
import StorageKit
import TestSupport
import Testing

@Suite("Canonical query work budget", .serialized)
struct DatabaseQueryWorkBudgetTests {
    @Test("Direct QueryIR uses the configured structural limits")
    func directQueryIRUsesConfiguredStructuralLimits() async throws {
        let container = try await makeContainer()
        let query = SelectQuery(
            projection: .items([
                ProjectionItem(.column(ColumnRef("id"))),
                ProjectionItem(.column(ColumnRef("title"))),
            ]),
            source: .table(TableRef(DatabaseEndpointEntity.persistableType))
        )
        let request = QueryExecuteOperation.Request(
            input: .ir(.select(query)),
            page: QueryExecuteOperation.Page(limit: 1)
        )
        let handler = QueryExecuteHandler(
            runtimeLimits: try DatabaseOperationLimits(
                maximumRows: 10_000,
                maximumWorkUnits: 1_000_000,
                maximumTimeoutMilliseconds: 30_000,
                queryStructuralLimits: QueryStructuralLimits(
                    maximumCollectionElements: 1
                )
            )
        )

        do {
            _ = try await handle(request, using: handler, container: container)
            Issue.record("Expected the QueryIR collection limit to reject the query")
        } catch QueryParameterBindingError.invalidStructure(let error) {
            #expect(
                error == .resourceLimitExceeded(
                    resource: .collectionElements,
                    actual: 2,
                    maximum: 1
                )
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Parameter payloads are rejected before recursive binding")
    func parameterPayloadIsValidatedBeforeBinding() async throws {
        let container = try await makeContainer()
        var value = FieldValue.object(FieldObject())
        for _ in 0..<7 {
            value = .array([value])
        }
        let query = SelectQuery(
            projection: .items([
                ProjectionItem(.parameter(.position(1)), alias: "value")
            ]),
            source: .table(TableRef(DatabaseEndpointEntity.persistableType))
        )
        let request = QueryExecuteOperation.Request(
            input: .ir(.select(query)),
            parameters: [
                QueryParameter(
                    position: 1,
                    name: "value",
                    value: value
                )
            ],
            page: QueryExecuteOperation.Page(limit: 1)
        )
        let handler = QueryExecuteHandler(
            runtimeLimits: try DatabaseOperationLimits(
                maximumRows: 10_000,
                maximumWorkUnits: 1_000_000,
                maximumTimeoutMilliseconds: 30_000,
                queryStructuralLimits: QueryStructuralLimits(
                    maximumNestingDepth: 6
                )
            )
        )

        do {
            _ = try await handle(request, using: handler, container: container)
            Issue.record("Expected parameter preflight to reject recursive binding")
        } catch QueryParameterBindingError.invalidStructure(let error) {
            #expect(
                error == .resourceLimitExceeded(
                    resource: .nestingDepth,
                    actual: 7,
                    maximum: 6
                )
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("SQL text parsing uses the configured structural limits")
    func sqlTextUsesConfiguredStructuralLimits() async throws {
        let container = try await makeContainer()
        let request = QueryExecuteOperation.Request(
            input: .text(
                language: .sql,
                statement: "SELECT id, title FROM DatabaseEndpointEntity"
            ),
            page: QueryExecuteOperation.Page(limit: 1)
        )
        let handler = QueryExecuteHandler(
            runtimeLimits: try DatabaseOperationLimits(
                maximumRows: 10_000,
                maximumWorkUnits: 1_000_000,
                maximumTimeoutMilliseconds: 30_000,
                queryStructuralLimits: QueryStructuralLimits(
                    maximumCollectionElements: 1
                )
            )
        )

        do {
            _ = try await handle(request, using: handler, container: container)
            Issue.record("Expected the parser collection limit to reject the query")
        } catch let error as QueryStructuralValidationError {
            #expect(
                error == .resourceLimitExceeded(
                    resource: .collectionElements,
                    actual: 2,
                    maximum: 1
                )
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Configured structural limits reach the SPARQL plan compiler")
    func configuredStructuralLimitsReachSPARQLCompiler() async throws {
        let container = try await makeContainer()
        var expression = Expression.literal(.bool(true))
        for _ in 0..<62 {
            expression = .not(expression)
        }
        let query = SelectQuery(
            projection: .items([
                ProjectionItem(expression, alias: "value")
            ]),
            source: .graphPattern(.basic([]))
        )
        #expect(
            throws: QueryStructuralValidationError.resourceLimitExceeded(
                resource: .nestingDepth,
                actual: 65,
                maximum: 64
            )
        ) {
            try QueryStructuralValidator.validate(query)
        }
        let structuralLimits = QueryStructuralLimits(maximumNestingDepth: 65)
        try QueryStructuralValidator.validate(
            query,
            limits: structuralLimits
        )
        let request = QueryExecuteOperation.Request(
            input: .ir(.select(query)),
            page: QueryExecuteOperation.Page(limit: 1)
        )
        let handler = QueryExecuteHandler(
            runtimeLimits: try DatabaseOperationLimits(
                maximumRows: 10_000,
                maximumWorkUnits: 1_000_000,
                maximumTimeoutMilliseconds: 30_000,
                queryStructuralLimits: structuralLimits
            )
        )
        let response = try await handle(
            request,
            using: handler,
            container: container
        )

        guard case .rows(let page) = response else {
            Issue.record("Expected a row page")
            return
        }
        #expect(page.rowCount == 1)
    }

    @Test("Direct QueryIR cannot hide an RDF blank node inside Literal")
    func directQueryIRRejectsNonCanonicalBlankNode() async throws {
        let container = try await makeContainer()
        let query = SelectQuery(
            projection: .all,
            source: .graphPattern(
                .basic([
                    TriplePattern(
                        subject: .variable("subject"),
                        predicate: .iri("urn:predicate"),
                        object: .literal(
                            .rdfTerm(
                                try RDFTerm.blankNode(identifier: "hidden")
                            )
                        )
                    )
                ])
            )
        )
        let request = QueryExecuteOperation.Request(
            input: .ir(.select(query)),
            page: QueryExecuteOperation.Page(limit: 1)
        )

        do {
            _ = try await handle(
                request,
                using: QueryExecuteHandler(),
                container: container
            )
            Issue.record("Expected semantic validation to reject the query")
        } catch let error as SPARQLSemanticValidationError {
            #expect(error == .nonCanonicalTermLiteral)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("table scans fail with a typed work limit before returning a partial page")
    func tableScanIsBounded() async throws {
        let container = try await makeContainer()

        do {
            _ = try await execute(
                container: container,
                pageLimit: 2,
                budget: ExecutionBudget(
                    maximumRows: 2,
                    maximumWorkUnits: 1,
                    timeoutMilliseconds: 1_000
                )
            )
            Issue.record("Expected the table scan to exhaust its work budget")
        } catch is DatabaseWorkLimitError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("table queries return only the requested page under one shared meter")
    func tablePageUsesSharedMeter() async throws {
        let container = try await makeContainer()
        let response = try await execute(
            container: container,
            pageLimit: 2,
            budget: ExecutionBudget(
                maximumRows: 2,
                maximumWorkUnits: 1_000,
                timeoutMilliseconds: 1_000
            )
        )

        guard case .rows(let page) = response else {
            Issue.record("Expected a row page")
            return
        }
        #expect(page.rowCount == 2)
        #expect(page.continuation != nil)
    }
    @Test("stable table paging scans only the visible page and one lookahead row")
    func stableTablePageDoesNotRescanTheWholeTable() async throws {
        // Work units mix row admission with the byte-processing quanta charged
        // by `DatabaseByteProcessingMeter` (one unit per 256 processed bytes),
        // so an absolute constant is not a stable statement about paging. The
        // invariant that survives an accounting change is that a stable
        // continuation resumes instead of re-scanning: reading the same two
        // pages must cost the same regardless of how large the table is.
        let smallTable = try await stableTablePagingWorkUnits(seedCount: 100)
        let largeTable = try await stableTablePagingWorkUnits(seedCount: 1_000)
        #expect(smallTable == largeTable)
    }

    /// Reads the first two stable pages of a full table scan under one shared
    /// meter and reports the work units both pages charged.
    private func stableTablePagingWorkUnits(seedCount: Int) async throws -> UInt64 {
        let container = try await makeContainer(seedCount: seedCount)
        let context = container.testBaseContext()
        let query = SelectQuery(
            projection: .all,
            source: .table(TableRef(DatabaseEndpointEntity.persistableType))
        )
        // Generous enough for two pages of any table size, but far below the
        // cost of re-scanning a 1000 row table once per page.
        let budget = ExecutionBudget(
            maximumRows: 2,
            maximumWorkUnits: 2_000,
            timeoutMilliseconds: 10_000
        )
        let workMeter = DatabaseWorkMeter(
            budget: budget,
            monotonicClock: container.monotonicClock
        )
        let pages = try await context.withReadSnapshot(workMeter: workMeter) { snapshot in
            let first = try await snapshot.session.executeCanonical(
                query,
                execution: ReadExecutionContext(
                    options: ReadExecutionOptions(
                        pageSize: 2,
                        budget: budget,
                        continuationSnapshotIsStable: true
                    ),
                    monotonicClock: container.monotonicClock,
                    workMeter: workMeter
                )
            )
            let continuation = try #require(first.continuation)
            let second = try await snapshot.session.executeCanonical(
                query,
                execution: ReadExecutionContext(
                    options: ReadExecutionOptions(
                        pageSize: 2,
                        continuation: continuation,
                        budget: budget,
                        continuationSnapshotIsStable: true
                    ),
                    monotonicClock: container.monotonicClock,
                    workMeter: workMeter
                )
            )
            return (first, second)
        }

        #expect(pages.0.rows.count == 2)
        #expect(pages.0.continuation != nil)
        #expect(pages.1.rows.count == 2)
        #expect(pages.1.continuation != nil)
        return workMeter.consumedWorkUnits
    }

    @Test("Qualified equality joins complete through the operation handler")
    func qualifiedEqualityJoinExecutesThroughTheHandler() async throws {
        let container = try await makeContainer(seedCount: 100)
        let request = QueryExecuteOperation.Request(
            input: .ir(.select(Self.selfEqualityJoin)),
            page: QueryExecuteOperation.Page(limit: 100),
            budget: ExecutionBudget(
                maximumRows: 100,
                // A guard, not a discriminator: the candidate strategy is
                // asserted by the scaling test below, which can observe the
                // meter that `QueryRowPage` does not expose.
                maximumWorkUnits: 100_000,
                timeoutMilliseconds: 10_000
            )
        )

        let response = try await handle(request, using: QueryExecuteHandler(), container: container)
        guard case .rows(let page) = response else {
            Issue.record("Expected a row page")
            return
        }
        #expect(page.rowCount == 100)
        #expect(page.continuation == nil)
    }

    @Test("Qualified equality joins use bounded hash candidates")
    func qualifiedEqualityJoinUsesBoundedHashCandidates() async throws {
        // A hash join visits each source row a bounded number of times, so its
        // cost grows with the number of rows. A nested loop compares every left
        // row against every right row, so doubling the table quadruples the
        // work. Doubling the row count therefore separates the two strategies
        // without depending on the absolute unit price of a row, which
        // `DatabaseByteProcessingMeter` changes whenever byte accounting moves.
        let half = try await equalityJoinWorkUnits(seedCount: 50)
        let full = try await equalityJoinWorkUnits(seedCount: 100)

        #expect(half.rowCount == 50)
        #expect(full.rowCount == 100)
        // Measured on database-framework 26.0902.0: 7057 and 14107 units, an
        // exactly linear 2.00x. A nested loop would land near 4x.
        #expect(full.units < half.units * 3)
    }

    /// Executes the self equality join over the complete table under one shared
    /// meter and reports the charged work units with the produced row count.
    private func equalityJoinWorkUnits(
        seedCount: Int
    ) async throws -> (units: UInt64, rowCount: Int) {
        let container = try await makeContainer(seedCount: seedCount)
        let context = container.testBaseContext()
        let budget = ExecutionBudget(
            maximumRows: UInt32(seedCount),
            maximumWorkUnits: 1_000_000,
            timeoutMilliseconds: 30_000
        )
        let workMeter = DatabaseWorkMeter(
            budget: budget,
            monotonicClock: container.monotonicClock
        )
        let page = try await context.withReadSnapshot(workMeter: workMeter) { snapshot in
            try await snapshot.session.executeCanonical(
                Self.selfEqualityJoin,
                execution: ReadExecutionContext(
                    options: ReadExecutionOptions(pageSize: seedCount, budget: budget),
                    monotonicClock: container.monotonicClock,
                    workMeter: workMeter
                )
            )
        }
        return (workMeter.consumedWorkUnits, page.rows.count)
    }

    /// An inner join of the seeded table with itself on the qualified primary
    /// key, which produces exactly one output row per stored row.
    private static var selfEqualityJoin: SelectQuery {
        let entity = DatabaseEndpointEntity.persistableType
        return SelectQuery(
            projection: .all,
            source: .join(
                JoinClause(
                    type: .inner,
                    left: .table(TableRef(table: entity, alias: "left_entity")),
                    right: .table(TableRef(table: entity, alias: "right_entity")),
                    condition: .on(
                        .equal(
                            .column(ColumnRef(table: "left_entity", column: "id")),
                            .column(ColumnRef(table: "right_entity", column: "id"))
                        )
                    )
                )
            )
        )
    }

    @Test("Outer page size does not truncate a nested relational source")
    func outerPageSizeDoesNotTruncateNestedSource() async throws {
        let container = try await makeContainer(seedCount: 100)
        let nested = SelectQuery(
            projection: .all,
            source: .table(TableRef(DatabaseEndpointEntity.persistableType))
        )
        let query = SelectQuery(
            projection: .items([
                ProjectionItem(.aggregate(.count(nil, distinct: false)), alias: "count")
            ]),
            source: .subquery(nested, alias: "entities")
        )

        let response = try await container.testBaseContext().query(
            query,
            options: ReadExecutionOptions(
                pageSize: 1,
                budget: ExecutionBudget(
                    maximumRows: 1,
                    // The invariant is the aggregate below, not this number.
                    // The budget only guards against an unbounded nested scan;
                    // the measured cost on database-framework 26.0902.0 is 6131
                    // units, which byte-processing accounting now dominates.
                    maximumWorkUnits: 12_500,
                    timeoutMilliseconds: 10_000
                )
            )
        )

        let row = try #require(response.rows.first)
        #expect(response.rows.count == 1)
        #expect(row.fields["count"] == .int64(100))
    }

    private func makeContainer(seedCount: Int = 3) async throws -> DBContainer {
        let container = try await DBContainer.open(
            for: try Schema(
                entities: [try DatabaseEndpointEntity.schemaEntity],
                version: Schema.Version(1, 0, 0)
            ),
            configuration: DBConfiguration.testing(
                storageEngine: InMemoryEngine()
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [try DatabaseFrameworkRuntime.entity(DatabaseEndpointEntity.self)]
            ),
            security: .testingDisabled
        )
        let context = container.testBaseContext()
        for index in 0..<seedCount {
            var entity = DatabaseEndpointEntity()
            entity.id = "entity-\(index)"
            entity.title = "Title \(index)"
            entity.priority = Int64(index)
            try context.insert(entity)
        }
        try await context.save()
        return container
    }

    private func execute(
        container: DBContainer,
        pageLimit: UInt32,
        budget: ExecutionBudget
    ) async throws -> QueryExecuteOperation.Response {
        let request = QueryExecuteOperation.Request(
            input: .ir(
                .select(
                    SelectQuery(
                        projection: .all,
                        source: .table(
                            TableRef(
                                DatabaseEndpointEntity.persistableType
                            )
                        )
                    )
                )
            ),
            page: QueryExecuteOperation.Page(limit: pageLimit),
            budget: budget
        )
        let baseContext = container.testBaseContext()
        return try await baseContext.withDataOperation {
            let snapshotStore = DatabaseQuerySnapshotStore(
                container: container,
                clock: AnyDatabaseWallClock(RealtimeDatabaseWallClock()),
                identifierGenerator: AnyDatabaseUUIDGenerator(
                    RandomDatabaseUUIDGenerator()
                ),
                scheduler: AnyDatabaseJobScheduler(
                    WorkBudgetSnapshotScheduler()
                ),
                wireLimits: .default
            )
            return try await QueryExecuteHandler(
                runtimeLimits: .default,
                querySnapshotStore: snapshotStore
            ).handle(
                request,
                context: try operationContext(
                    container: container,
                    request: request,
                    baseContext: baseContext
                )
            )
        }
    }

    private func handle(
        _ request: QueryExecuteOperation.Request,
        using handler: QueryExecuteHandler,
        container: DBContainer
    ) async throws -> QueryExecuteOperation.Response {
        let baseContext = container.testBaseContext()
        return try await baseContext.withDataOperation {
            try await handler.handle(
                request,
                context: try operationContext(
                    container: container,
                    request: request,
                    baseContext: baseContext
                )
            )
        }
    }

    private func operationContext(
        container: DBContainer,
        request: QueryExecuteOperation.Request,
        baseContext: DatabaseContext? = nil
    ) throws -> DatabaseOperationContext {
        let baseContext = baseContext ?? container.testBaseContext()
#if MultiBase
        return DatabaseOperationContext(
            container: container,
            target: .base(baseContext.baseID),
            baseContext: baseContext,
            composition: nil,
            requirement: .canonical(for: .queryExecute),
            requestID: 1,
            metadata: OperationRequestMetadata(),
            authorization: TestBaseEnvironment.authorization,
            requestPayload: [],
            wireLimits: .default
        )
#else
        _ = baseContext
        return DatabaseOperationContext(
            container: container,
            requirement: .canonical(for: .queryExecute),
            requestID: 1,
            metadata: OperationRequestMetadata(),
            authorization: TestBaseEnvironment.authorization,
            requestPayload: [],
            wireLimits: .default
        )
#endif
    }
}

private actor WorkBudgetSnapshotScheduler: DatabaseJobScheduler {
    func ensureWakeUp(noLaterThan deadline: Timestamp) async throws {
        _ = deadline
    }
}
