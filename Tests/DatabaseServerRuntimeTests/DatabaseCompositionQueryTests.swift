#if MultiBase
@_spi(DatabaseExecution) import DatabaseEngine
@testable import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
@testable import DatabaseServerRuntime
import DatabaseServerFoundation
import DatabaseTypes
import DatabaseWire
#if DATABASE_OPERATIONS_TEST_GRAPH_INDEXES
@testable import GraphIndex
#endif
import StorageKit
import Synchronization
import TestSupport
import Testing

/// One valid read point stands for the snapshot these builder unit tests
/// publish under. DatabaseWire rejects an empty federated read-point list, and
/// production always carries at least the domain the Composition read.
private func testReadConsistency(
    domain: Base.ID
) throws -> DatabaseKit.DatabaseReadConsistency {
    .transactional(
        try DomainReadPoint(domainID: domain.value, position: .version(1))
    )
}

@Suite("Composition query execution", .serialized)
struct DatabaseCompositionQueryTests {
    private func valueColumns() throws -> [QueryColumn] {
        [try QueryColumn(number: 1, name: "value", type: .primitive(.string), isNullable: false)]
    }

    @Test("Composition preserves duplicate column labels across durable pages")
    func duplicateColumnsPreserveProvenance() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await seed(fixture)
        let query = SelectQuery(
            projection: .items([
                ProjectionItem(.col("id"), alias: "value"),
                ProjectionItem(.col("priority"), alias: "value"),
            ]),
            source: .table(TableRef(DatabaseEndpointEntity.persistableType))
        )
        let first = try await successfulPage(
            QueryExecuteOperation.Request(input: .ir(.select(query)), page: .init(limit: 2)),
            requestID: 900, fixture: fixture
        )
        let continuation = try #require(first.continuation)
        let second = try await successfulPage(
            QueryExecuteOperation.Request(input: .ir(.select(query)), page: .init(limit: 2, continuation: continuation)),
            requestID: 901, fixture: fixture
        )
        #expect(first.columns.map(\.name) == ["value", "value"])
        #expect(first.columns.map(\.type) == [.primitive(.string), .primitive(.int64)])
        #expect(second.columns == first.columns)
        let expectedPriorities: [String: Int64] = [
            "primary-1": 1, "primary-3": 3, "other-2": 2, "other-4": 4,
        ]
        var identifiers = Set<String>()
        for page in [first, second] {
            #expect(page.provenance?.originCount == page.rowCount)
            #expect(page.rowCount == 2)
            let provenance = try #require(page.provenance)
            var origins = provenance.makeOriginIterator()
            for row in try page.materializedRows(maximumCount: 2) {
                #expect(row.values.count == 2)
                guard case .primitive(.string(let id)) = row.values[0],
                      case .primitive(.int64(let priority)) = row.values[1] else {
                    Issue.record("Expected positional identifier and priority values")
                    continue
                }
                #expect(expectedPriorities[id] == priority)
                let inserted = identifiers.insert(id).inserted
                #expect(inserted)
                let baseID = id.hasPrefix("primary-")
                    ? fixture.primaryBaseID : fixture.secondaryBaseID
                #expect(try origins.next() == .source(baseID))
            }
            #expect(try origins.next() == nil)
        }
        #expect(identifiers == Set(expectedPriorities.keys))
    }

    @Test("An empty Composition preserves its bound column schema")
    func emptyCompositionRetainsColumns() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        let query = SelectQuery(
            projection: .items([
                ProjectionItem(.col("priority"), alias: "z"),
                ProjectionItem(.col("id"), alias: "a"),
            ]),
            source: .table(TableRef(DatabaseEndpointEntity.persistableType))
        )
        let page = try await successfulPage(
            QueryExecuteOperation.Request(input: .ir(.select(query)), page: .init(limit: 2)),
            requestID: 902, fixture: fixture
        )
        #expect(page.rowCount == 0)
        #expect(page.columns.map(\.name) == ["z", "a"])
        #expect(page.columns.map(\.type) == [.primitive(.int64), .primitive(.string)])
        #expect(page.provenance?.originCount == 0)
        #expect(page.continuation == nil)
    }

    @Test("global ordering, provenance, and durable paging are fixed")
    func globalOrderAndDurablePaging() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await seed(fixture)

        let first = try await successfulPage(
            request(pageLimit: 2),
            requestID: 1,
            fixture: fixture
        )
        #expect(try priorities(first) == [1, 2])
        let continuation = try #require(first.continuation)
        #expect(
            continuation.count
                == DatabaseQuerySnapshotStore.continuationByteCount
        )
        let provenance = try #require(first.provenance)
        var origins = provenance.makeOriginIterator()
        #expect(try origins.next() == .source(fixture.primaryBaseID))
        #expect(try origins.next() == .source(fixture.secondaryBaseID))
        #expect(try origins.next() == nil)

        var later = DatabaseEndpointEntity()
        later.id = "later"
        later.title = "Inserted after snapshot publication"
        later.priority = 0
        let context = fixture.container.session(
            authorization: TestBaseEnvironment.authorization
        ).base(fixture.primaryBaseID).newContext()
        try context.insert(later)
        try await context.save()

        let second = try await successfulPage(
            request(pageLimit: 2, continuation: continuation),
            requestID: 2,
            fixture: fixture
        )
        #expect(try priorities(second) == [3, 4])
        #expect(second.continuation == nil)
    }

    @Test("Composition page size is bounded before snapshot publication")
    func pageLimitIsBoundedByMaximumRows() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await seed(fixture)
        let budget = ExecutionBudget(maximumRows: 2)

        let first = try await successfulPage(
            request(pageLimit: 10, budget: budget),
            requestID: 3,
            fixture: fixture
        )
        #expect(try priorities(first) == [1, 2])
        let continuation = try #require(first.continuation)

        let second = try await successfulPage(
            request(
                pageLimit: 10,
                continuation: continuation,
                budget: budget
            ),
            requestID: 4,
            fixture: fixture
        )
        #expect(try priorities(second) == [3, 4])
        #expect(second.continuation == nil)
    }

    @Test("the first Composition page retains its destination claim until publication")
    func firstPageRetainsTheIntermediateBudget() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        let selection = CompositionSelection.named(fixture.compositionID)
        let readMetadata = try await fixture.container.session(
            authorization: TestBaseEnvironment.authorization
        ).composition(selection).acquireReadMetadata()
        let workMeter = DatabaseWorkMeter(
            budget: ExecutionBudget(
                maximumRows: 8,
                maximumWorkUnits: 10_000,
                maximumIntermediateRows: 8,
                maximumIntermediateBytes: 1 * 1_024 * 1_024,
                timeoutMilliseconds: 30_000
            ),
            monotonicClock: fixture.container.monotonicClock
        )
        let builder = try DatabaseCompositionQueryResultBuilder(
            composition: readMetadata.resolution,
            columns: try valueColumns(),
            basePlacementGenerations: readMetadata.basePlacementGenerations,
            schemaGeneration: fixture.container.schemaGeneration,
            consistency: try testReadConsistency(
                domain: fixture.primaryBaseID
            ),
            pageLimit: 1,
            queryFingerprint: ByteString(repeating: 0x41, count: 32),
            authorization: TestBaseEnvironment.authorization,
            maximumIntermediateBytes: 1 * 1_024 * 1_024,
            snapshotStore: fixture.snapshotStore,
            workMeter: workMeter
        )

        try await builder.append(CompositionQueryRow(
            row: try DatabaseEngine.QueryRow(values: [.primitive(.string("first"))], columns: valueColumns()),
            origin: .source(fixture.primaryBaseID)
        ))
        try await builder.append(CompositionQueryRow(
            row: try DatabaseEngine.QueryRow(values: [.primitive(.string("second"))], columns: valueColumns()),
            origin: .source(fixture.secondaryBaseID)
        ))

        // Both destination page windows remain admitted until publication.
        #expect(workMeter.retainedIntermediateRows == 2)
        #expect(workMeter.retainedIntermediateBytes > 0)
        _ = try await builder.finish()
        #expect(workMeter.retainedIntermediateRows == 0)
        #expect(workMeter.retainedIntermediateBytes == 0)
    }

    @Test("first-page claims survive blocked publication commit and release on success or abort", .timeLimit(.minutes(1)))
    func firstPageReservationSurvivesBlockedPublication() async throws {
        for invalidatesTarget in [false, true] {
            let engine = CommitGatedInMemoryEngine()
            let fixture = try await makeFixture(controlEngine: engine)
            defer { await fixture.container.shutdown() }
            let metadata = try await fixture.container.session(
                authorization: TestBaseEnvironment.authorization
            ).composition(CompositionSelection.named(fixture.compositionID)).acquireReadMetadata()
            let workMeter = DatabaseWorkMeter(
                budget: ExecutionBudget(maximumRows: 8, maximumWorkUnits: 10_000,
                    maximumIntermediateRows: 8, maximumIntermediateBytes: 1 * 1_024 * 1_024,
                    timeoutMilliseconds: 30_000),
                monotonicClock: fixture.container.monotonicClock
            )
            let builder = try DatabaseCompositionQueryResultBuilder(
                composition: metadata.resolution,
                columns: valueColumns(),
                basePlacementGenerations: metadata.basePlacementGenerations,
                schemaGeneration: fixture.container.schemaGeneration,
                consistency: testReadConsistency(domain: fixture.primaryBaseID),
                pageLimit: 1,
                queryFingerprint: ByteString(repeating: 0x47, count: 32),
                authorization: TestBaseEnvironment.authorization,
                maximumIntermediateBytes: 1 * 1_024 * 1_024,
                snapshotStore: fixture.snapshotStore,
                workMeter: workMeter
            )
            for (value, origin) in [("first", fixture.primaryBaseID), ("second", fixture.secondaryBaseID)] {
                try await builder.append(CompositionQueryRow(
                    row: DatabaseEngine.QueryRow(values: [.primitive(.string(value))], columns: valueColumns()),
                    origin: .source(origin)
                ))
            }
            #expect(workMeter.retainedIntermediateRows == 2)
            let retainedBytes = workMeter.retainedIntermediateBytes
            #expect(retainedBytes > 0)

            // This small page writes one payload chunk and its descriptor.
            // The third mutating commit publishes the authoritative manifest.
            let commitsBeforeFinish = engine.mutatingCommitCount
            let gate = engine.suspendMutatingCommit(skipping: 2)
            let finish = Task { try await builder.finish() }
            defer {
                await gate.release()
                _ = await finish.result
                do { try await builder.abort() }
                catch { Issue.record("Publication cleanup failed: \(error)") }
            }
            await gate.waitUntilStarted()
            #expect(engine.mutatingCommitCount == commitsBeforeFinish + 3)
            #expect(workMeter.retainedIntermediateRows == 2)
            #expect(workMeter.retainedIntermediateBytes == retainedBytes)
            if invalidatesTarget {
                _ = try await fixture.container.withControlMetadataTransaction { transaction in
                    try await fixture.container.compositionCatalog.replace(
                        id: fixture.compositionID,
                        bases: [fixture.primaryBaseID, fixture.secondaryBaseID],
                        expectedRevision: 1,
                        transaction: transaction.executionStorageAccess
                    )
                }
            }
            await gate.release()
            if invalidatesTarget {
                let failure = await #expect(throws: DatabaseQueryExecutionError.self) {
                    try await finish.value
                }
                if case .querySnapshotStale? = failure {} else {
                    Issue.record("Expected a stale snapshot after the target changed")
                }
                try await builder.abort()
                try await builder.abort()
            } else {
                let page = try await finish.value
                #expect(page.rowCount == 1)
                #expect(page.continuation != nil)
                #expect(try page.materializedRows(maximumCount: 1).first?.values == [.primitive(.string("first"))])
            }
            #expect(workMeter.retainedIntermediateRows == 0)
            #expect(workMeter.retainedIntermediateBytes == 0)
        }
    }

    @Test("an append failure releases every staged claim after abort")
    func appendFailureReleasesStagedClaimsAfterAbort() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        let readMetadata = try await fixture.container.session(
            authorization: TestBaseEnvironment.authorization
        ).composition(CompositionSelection.named(fixture.compositionID))
            .acquireReadMetadata()
        let workMeter = DatabaseWorkMeter(
            budget: ExecutionBudget(
                maximumRows: 8,
                maximumWorkUnits: 10_000,
                maximumIntermediateRows: 8,
                maximumIntermediateBytes: 1 * 1_024 * 1_024,
                timeoutMilliseconds: 30_000
            ),
            monotonicClock: fixture.container.monotonicClock
        )
        let builder = try DatabaseCompositionQueryResultBuilder(
            composition: readMetadata.resolution,
            columns: try valueColumns(),
            basePlacementGenerations: readMetadata.basePlacementGenerations,
            schemaGeneration: fixture.container.schemaGeneration,
            consistency: try testReadConsistency(
                domain: fixture.primaryBaseID
            ),
            pageLimit: 1,
            queryFingerprint: ByteString(repeating: 0x43, count: 32),
            authorization: TestBaseEnvironment.authorization,
            maximumIntermediateBytes: 1 * 1_024 * 1_024,
            snapshotStore: nil,
            workMeter: workMeter
        )
        let row = try DatabaseEngine.QueryRow(
            values: [.primitive(.string("staged"))], columns: valueColumns()
        )
        let incompatibleRow = try DatabaseEngine.QueryRow(
            values: [.primitive(.int64(1))],
            columns: [QueryColumn(number: 1, name: "value", type: .primitive(.int64), isNullable: false)]
        )

        try await builder.append(CompositionQueryRow(
            row: row,
            origin: .source(fixture.primaryBaseID)
        ))
        do {
            try await builder.append(CompositionQueryRow(
                row: incompatibleRow,
                origin: .source(fixture.secondaryBaseID)
        ))
            Issue.record("Expected incompatible projected columns to fail append")
        } catch {
            // The builder rolls back the failed append before abort is called.
        }

        #expect(workMeter.retainedIntermediateRows == 1)
        #expect(workMeter.retainedIntermediateBytes > 0)
        try await builder.abort()
        #expect(workMeter.retainedIntermediateRows == 0)
        #expect(workMeter.retainedIntermediateBytes == 0)
        try await builder.abort()
        #expect(workMeter.retainedIntermediateRows == 0)
        #expect(workMeter.retainedIntermediateBytes == 0)
    }

    @Test("cancellation during finish releases staged claims before abort")
    func cancellationDuringFinishReleasesStagedClaims() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        let readMetadata = try await fixture.container.session(
            authorization: TestBaseEnvironment.authorization
        ).composition(CompositionSelection.named(fixture.compositionID))
            .acquireReadMetadata()
        let workMeter = DatabaseWorkMeter(
            budget: ExecutionBudget(
                maximumRows: 8,
                maximumWorkUnits: 10_000,
                maximumIntermediateRows: 8,
                maximumIntermediateBytes: 1 * 1_024 * 1_024,
                timeoutMilliseconds: 30_000
            ),
            monotonicClock: fixture.container.monotonicClock
        )
        let builder = try DatabaseCompositionQueryResultBuilder(
            composition: readMetadata.resolution,
            columns: try valueColumns(),
            basePlacementGenerations: readMetadata.basePlacementGenerations,
            schemaGeneration: fixture.container.schemaGeneration,
            consistency: try testReadConsistency(
                domain: fixture.primaryBaseID
            ),
            pageLimit: 1,
            queryFingerprint: ByteString(repeating: 0x44, count: 32),
            authorization: TestBaseEnvironment.authorization,
            maximumIntermediateBytes: 1 * 1_024 * 1_024,
            snapshotStore: fixture.snapshotStore,
            workMeter: workMeter
        )
        let row = try DatabaseEngine.QueryRow(
            values: [.primitive(.string("staged"))], columns: valueColumns()
        )
        try await builder.append(CompositionQueryRow(
            row: row,
            origin: .source(fixture.primaryBaseID)
        ))
        try await builder.append(CompositionQueryRow(
            row: row,
            origin: .source(fixture.secondaryBaseID)
        ))

        let gate = BuilderStartGate()
        let task = Task {
            await gate.enterAndWait()
            return try await builder.finish()
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation to interrupt finish")
        } catch is CancellationError {
            // Cancellation must not retain the staged page claim.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
        #expect(workMeter.retainedIntermediateRows == 0)
        #expect(workMeter.retainedIntermediateBytes == 0)
        try await builder.abort()
        #expect(workMeter.retainedIntermediateRows == 0)
        #expect(workMeter.retainedIntermediateBytes == 0)
    }

    @Test("publication failure releases staged claims after abort")
    func publicationFailureReleasesStagedClaimsAfterAbort() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        let readMetadata = try await fixture.container.session(
            authorization: TestBaseEnvironment.authorization
        ).composition(CompositionSelection.named(fixture.compositionID))
            .acquireReadMetadata()
        let workMeter = DatabaseWorkMeter(
            budget: ExecutionBudget(
                maximumRows: 8,
                maximumWorkUnits: 10_000,
                maximumIntermediateRows: 8,
                maximumIntermediateBytes: 1 * 1_024 * 1_024,
                timeoutMilliseconds: 30_000
            ),
            monotonicClock: fixture.container.monotonicClock
        )
        let builder = try DatabaseCompositionQueryResultBuilder(
            composition: readMetadata.resolution,
            columns: try valueColumns(),
            basePlacementGenerations: readMetadata.basePlacementGenerations,
            schemaGeneration: fixture.container.schemaGeneration,
            consistency: try testReadConsistency(
                domain: fixture.primaryBaseID
            ),
            pageLimit: 1,
            queryFingerprint: ByteString(repeating: 0x45, count: 32),
            authorization: TestBaseEnvironment.authorization,
            maximumIntermediateBytes: 1 * 1_024 * 1_024,
            snapshotStore: fixture.snapshotStore,
            workMeter: workMeter
        )
        let row = try DatabaseEngine.QueryRow(
            values: [.primitive(.string("staged"))], columns: valueColumns()
        )
        try await builder.append(CompositionQueryRow(
            row: row,
            origin: .source(fixture.primaryBaseID)
        ))
        try await builder.append(CompositionQueryRow(
            row: row,
            origin: .source(fixture.secondaryBaseID)
        ))

        _ = try await fixture.container.withControlMetadataTransaction {
            transaction in
            try await fixture.container.compositionCatalog.replace(
                id: fixture.compositionID,
                bases: [
                    fixture.primaryBaseID,
                    fixture.secondaryBaseID,
                ],
                expectedRevision: 1,
                transaction: transaction.executionStorageAccess
            )
        }

        do {
            _ = try await builder.finish()
            Issue.record("Expected publication to reject the stale composition")
        } catch {
            // The finish failure must release in-memory claims before abort.
        }
        #expect(workMeter.retainedIntermediateRows == 0)
        #expect(workMeter.retainedIntermediateBytes == 0)
        try await builder.abort()
        #expect(workMeter.retainedIntermediateRows == 0)
        #expect(workMeter.retainedIntermediateBytes == 0)
    }

    #if DATABASE_OPERATIONS_TEST_GRAPH_INDEXES
    @Test("the first Composition RDF page leaves the intermediate budget")
    func firstRDFPageLeavesTheIntermediateBudget() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        let selection = CompositionSelection.named(fixture.compositionID)
        let readMetadata = try await fixture.container.session(
            authorization: TestBaseEnvironment.authorization
        ).composition(selection).acquireReadMetadata()
        let workMeter = DatabaseWorkMeter(
            budget: ExecutionBudget(
                maximumRows: 8,
                maximumWorkUnits: 10_000,
                maximumIntermediateRows: 8,
                maximumIntermediateBytes: 1 * 1_024 * 1_024,
                timeoutMilliseconds: 30_000
            ),
            monotonicClock: fixture.container.monotonicClock
        )
        let builder = try DatabaseCompositionRDFResultBuilder(
            composition: readMetadata.resolution,
            basePlacementGenerations: readMetadata.basePlacementGenerations,
            consistency: try testReadConsistency(
                domain: fixture.primaryBaseID
            ),
            schemaGeneration: fixture.container.schemaGeneration,
            pageLimit: 1,
            maximumIntermediateBytes: 1 * 1_024 * 1_024,
            queryFingerprint: ByteString(repeating: 0x42, count: 32),
            authorization: TestBaseEnvironment.authorization,
            snapshotStore: fixture.snapshotStore,
            workMeter: workMeter
        )
        let predicate = try RDFPredicateIRI("urn:composition:predicate")

        try await builder.append(
            RDFQuad(
                subject: .iri(try RDFIRI("urn:composition:first")),
                predicate: predicate,
                object: .iri(try RDFIRI("urn:composition:object"))
            ),
            origin: .source(fixture.primaryBaseID)
        )
        try await builder.append(
            RDFQuad(
                subject: .iri(try RDFIRI("urn:composition:second")),
                predicate: predicate,
                object: .iri(try RDFIRI("urn:composition:object"))
            ),
            origin: .source(fixture.secondaryBaseID)
        )

        // The first full page is promoted out of the intermediate budget, so
        // one staged quad remains, plus the released framework quad footprint
        // meter's four-slot scratch worklist, which reserves its slots as
        // intermediate rows for as long as quads may still arrive.
        #expect(workMeter.retainedIntermediateRows == 5)
        _ = try await builder.finish()
        #expect(workMeter.retainedIntermediateRows == 0)
        #expect(workMeter.retainedIntermediateBytes == 0)
    }

    @Test("RDF publication failure releases staged claims after abort")
    func rdfPublicationFailureReleasesStagedClaimsAfterAbort() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        let readMetadata = try await fixture.container.session(
            authorization: TestBaseEnvironment.authorization
        ).composition(CompositionSelection.named(fixture.compositionID))
            .acquireReadMetadata()
        let workMeter = DatabaseWorkMeter(
            budget: ExecutionBudget(
                maximumRows: 8,
                maximumWorkUnits: 10_000,
                maximumIntermediateRows: 8,
                maximumIntermediateBytes: 1 * 1_024 * 1_024,
                timeoutMilliseconds: 30_000
            ),
            monotonicClock: fixture.container.monotonicClock
        )
        let builder = try DatabaseCompositionRDFResultBuilder(
            composition: readMetadata.resolution,
            basePlacementGenerations: readMetadata.basePlacementGenerations,
            consistency: try testReadConsistency(
                domain: fixture.primaryBaseID
            ),
            schemaGeneration: fixture.container.schemaGeneration,
            pageLimit: 1,
            maximumIntermediateBytes: 1 * 1_024 * 1_024,
            queryFingerprint: ByteString(repeating: 0x46, count: 32),
            authorization: TestBaseEnvironment.authorization,
            snapshotStore: fixture.snapshotStore,
            workMeter: workMeter
        )
        let predicate = try RDFPredicateIRI("urn:composition:predicate")
        let first = RDFQuad(
            subject: .iri(try RDFIRI("urn:composition:first")),
            predicate: predicate,
            object: .iri(try RDFIRI("urn:composition:object"))
        )
        let second = RDFQuad(
            subject: .iri(try RDFIRI("urn:composition:second")),
            predicate: predicate,
            object: .iri(try RDFIRI("urn:composition:object"))
        )
        try await builder.append(first, origin: .source(fixture.primaryBaseID))
        try await builder.append(
            second,
            origin: .source(fixture.secondaryBaseID)
        )

        _ = try await fixture.container.withControlMetadataTransaction {
            transaction in
            try await fixture.container.compositionCatalog.replace(
                id: fixture.compositionID,
                bases: [
                    fixture.primaryBaseID,
                    fixture.secondaryBaseID,
                ],
                expectedRevision: 1,
                transaction: transaction.executionStorageAccess
            )
        }

        do {
            _ = try await builder.finish()
            Issue.record("Expected RDF publication to reject stale composition")
        } catch {
            // The finish failure must release in-memory claims before abort.
        }
        #expect(workMeter.retainedIntermediateRows == 0)
        #expect(workMeter.retainedIntermediateBytes == 0)
        try await builder.abort()
        #expect(workMeter.retainedIntermediateRows == 0)
        #expect(workMeter.retainedIntermediateBytes == 0)
    }
    #endif

    @Test("derived Composition executes remotely without a catalog identity")
    func derivedCompositionHasNoSyntheticIdentity() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await seed(fixture)
        let selection = try CompositionSelection.derived([
            fixture.secondaryBaseID,
            fixture.primaryBaseID,
        ])

        let page = try await successfulPage(
            request(pageLimit: 4),
            requestID: 5,
            fixture: fixture,
            selection: selection
        )
        #expect(try priorities(page) == [1, 2, 3, 4])
        let provenance = try #require(page.provenance)
        #expect(provenance.composition.kind == .derived)
        #expect(provenance.composition.namedID == nil)
        #expect(provenance.composition.generation == nil)
        #expect(
            provenance.composition.bases == [
                fixture.primaryBaseID,
                fixture.secondaryBaseID,
            ].sorted()
        )
    }

    @Test("joins execute independently inside every member Base")
    func baseLocalJoinIsSupported() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await insert(
            [("shared", 1)],
            into: fixture.primaryBaseID,
            container: fixture.container
        )
        try await insert(
            [("shared", 2)],
            into: fixture.secondaryBaseID,
            container: fixture.container
        )
        let leftAliased: DataSource = .table(
            TableRef(
                schema: nil,
                table: DatabaseEndpointEntity.persistableType,
                alias: "lhs"
            )
        )
        let rightAliased: DataSource = .table(
            TableRef(
                schema: nil,
                table: DatabaseEndpointEntity.persistableType,
                alias: "rhs"
            )
        )
        let query = SelectQuery(
            projection: .items([
                ProjectionItem(
                    .column(ColumnRef(table: "lhs", column: "id")),
                    alias: "id"
                ),
                ProjectionItem(
                    .column(ColumnRef(table: "lhs", column: "priority")),
                    alias: "priority"
                ),
            ]),
            source: .join(
                JoinClause(
                    type: .inner,
                    left: leftAliased,
                    right: rightAliased,
                    condition: .on(
                        .equal(
                            .column(ColumnRef(table: "lhs", column: "id")),
                            .column(ColumnRef(table: "rhs", column: "id"))
                        )
                    )
                )
            ),
            orderBy: [
                SortKey(
                    .column(
                        ColumnRef(table: "lhs", column: "priority")
                    )
                )
            ]
        )

        let page = try await successfulPage(
            QueryExecuteOperation.Request(
                input: .ir(.select(query)),
                page: QueryExecuteOperation.Page(limit: 10)
            ),
            requestID: 10,
            fixture: fixture
        )
        #expect(try priorities(page) == [1, 2])
        let provenance = try #require(page.provenance)
        var origins = provenance.makeOriginIterator()
        #expect(try origins.next() == .source(fixture.primaryBaseID))
        #expect(try origins.next() == .source(fixture.secondaryBaseID))
        #expect(try origins.next() == nil)
    }

    @Test("explicit cross-Base INNER JOIN uses framework semantics")
    func crossBaseInnerJoinIsAdaptedWithoutServerPlanning() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await insert(
            [("shared", 1)],
            into: fixture.primaryBaseID,
            container: fixture.container
        )
        try await insert(
            [("shared", 2)],
            into: fixture.secondaryBaseID,
            container: fixture.container
        )
        let query = SelectQuery(
            projection: .items([
                ProjectionItem(
                    .column(ColumnRef(table: "lhs", column: "priority")),
                    alias: "leftPriority"
                ),
                ProjectionItem(
                    .column(ColumnRef(table: "rhs", column: "priority")),
                    alias: "rightPriority"
                ),
            ]),
            source: .join(
                JoinClause(
                    type: .inner,
                    left: .base(
                        fixture.primaryBaseID,
                        .table(
                            TableRef(
                                table: DatabaseEndpointEntity.persistableType,
                                alias: "lhs"
                            )
                        )
                    ),
                    right: .base(
                        fixture.secondaryBaseID,
                        .table(
                            TableRef(
                                table: DatabaseEndpointEntity.persistableType,
                                alias: "rhs"
                            )
                        )
                    ),
                    condition: .on(
                        .equal(
                            .column(ColumnRef(table: "lhs", column: "id")),
                            .column(ColumnRef(table: "rhs", column: "id"))
                        )
                    )
                )
            )
        )

        let page = try await successfulPage(
            QueryExecuteOperation.Request(
                input: .ir(.select(query)),
                page: QueryExecuteOperation.Page(limit: 10)
            ),
            requestID: 15,
            fixture: fixture
        )
        let row = try #require(
            page.materializedRows(maximumCount: 1).first
        )
        #expect(
            try value("leftPriority", row: row, page: page) == .int64(1)
        )
        #expect(
            try value("rightPriority", row: row, page: page) == .int64(2)
        )
        let provenance = try #require(page.provenance)
        var origins = provenance.makeOriginIterator()
        #expect(
            try origins.next() == .derived(
                contributors: [
                    fixture.primaryBaseID,
                    fixture.secondaryBaseID,
                ].sorted()
            )
        )
        #expect(try origins.next() == nil)
    }

    @Test("a Composition generation change makes a continuation stale")
    func generationChangeInvalidatesContinuation() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await seed(fixture)
        let first = try await successfulPage(
            request(pageLimit: 1),
            requestID: 20,
            fixture: fixture
        )
        let continuation = try #require(first.continuation)

        _ = try await fixture.container.withControlMetadataTransaction {
            transaction in
            try await fixture.container.compositionCatalog.replace(
                id: fixture.compositionID,
                bases: [
                    fixture.primaryBaseID,
                    fixture.secondaryBaseID,
                ],
                expectedRevision: 1,
                transaction: transaction.executionStorageAccess
            )
        }

        let error = try await remoteFailure(
            request(pageLimit: 1, continuation: continuation),
            requestID: 21,
            fixture: fixture
        )
        #expect(error.category == .conflict)
        #expect(error.code == "QUERY_SNAPSHOT_STALE")
    }

    @Test("a member Base placement change makes a derived continuation stale")
    func basePlacementChangeInvalidatesDerivedContinuation() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await seed(fixture)
        let selection = try CompositionSelection.derived([
            fixture.primaryBaseID,
            fixture.secondaryBaseID,
        ])
        let firstRequest = request(pageLimit: 1)
        let first = try await successfulPage(
            firstRequest,
            requestID: 22,
            fixture: fixture,
            selection: selection
        )
        let continuation = try #require(first.continuation)
        guard case .ir(.select(let query)) = firstRequest.input else {
            throw TestFailure.unexpectedResponse
        }
        let readMetadata = try await fixture.container.session(
            authorization: TestBaseEnvironment.authorization
        ).composition(selection).acquireReadMetadata()
        var changedGenerations = readMetadata.basePlacementGenerations
        let currentGeneration = try #require(
            changedGenerations[fixture.primaryBaseID]
        )
        changedGenerations[fixture.primaryBaseID] = currentGeneration + 1

        do {
            _ = try await fixture.snapshotStore.load(
                continuation: continuation,
                composition: readMetadata.resolution,
                basePlacementGenerations: changedGenerations,
                schemaGeneration: fixture.container.schemaGeneration,
                queryFingerprint: try DatabaseQuerySnapshotStore
                    .queryFingerprint(
                        query: query,
                        request: firstRequest,
                        limits: .default
                    ),
                authorization: TestBaseEnvironment.authorization
            )
            Issue.record("Expected the changed Base generation to be stale")
        } catch let error as DatabaseQueryExecutionError {
            guard case .querySnapshotStale = error else {
                Issue.record("Expected querySnapshotStale, got \(error)")
                return
            }
        }
    }

    @Test("decomposable aggregates reduce across every member Base")
    func decomposableAggregates() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await seed(fixture)
        let priority: Expression = .column(ColumnRef(column: "priority"))
        let query = SelectQuery(
            projection: .items([
                ProjectionItem(
                    .aggregate(.count(nil, distinct: false)),
                    alias: "count"
                ),
                ProjectionItem(
                    .aggregate(.sum(priority, distinct: false)),
                    alias: "sum"
                ),
                ProjectionItem(
                    .aggregate(.avg(priority, distinct: false)),
                    alias: "average"
                ),
                ProjectionItem(.aggregate(.min(priority)), alias: "minimum"),
                ProjectionItem(.aggregate(.max(priority)), alias: "maximum"),
            ]),
            source: .table(
                TableRef(DatabaseEndpointEntity.persistableType)
            )
        )
        let page = try await successfulPage(
            QueryExecuteOperation.Request(
                input: .ir(.select(query)),
                page: QueryExecuteOperation.Page(limit: 10)
            ),
            requestID: 25,
            fixture: fixture
        )
        let row = try #require(
            page.materializedRows(maximumCount: 1).first
        )
        #expect(page.columns.map(\.name) == ["count", "sum", "average", "minimum", "maximum"])
        #expect(page.columns.map(\.type) == [
            .sql(.bigint), .sql(.decimal(precision: nil, scale: nil)),
            .sql(.doublePrecision), .primitive(.int64), .primitive(.int64),
        ])
        let sum = try QueryNumericValue(
            value: ExactDecimal(coefficient: 10, scale: 0), displayScale: 0
        )
        #expect(try value("count", row: row, page: page) == .int64(4))
        #expect(row.values[1] == .numeric(sum))
        #expect(
            try value("average", row: row, page: page) == .float64(2.5)
        )
        #expect(try value("minimum", row: row, page: page) == .int64(1))
        #expect(try value("maximum", row: row, page: page) == .int64(4))
        let provenance = try #require(page.provenance)
        var origins = provenance.makeOriginIterator()
        #expect(
            try origins.next() == .derived(
                contributors: [
                    fixture.secondaryBaseID,
                    fixture.primaryBaseID,
                ].sorted()
            )
        )
        #expect(try origins.next() == nil)
    }

    @Test("non-numeric Composition aggregates remain typed failures")
    func nonNumericAggregateFailure() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await seed(fixture)
        let title: Expression = .column(ColumnRef(column: "title"))
        let query = SelectQuery(
            projection: .items([
                ProjectionItem(
                    .aggregate(.sum(title, distinct: false)),
                    alias: "sum"
                )
            ]),
            source: .table(
                TableRef(DatabaseEndpointEntity.persistableType)
            )
        )

        let error = try await remoteFailure(
            QueryExecuteOperation.Request(
                input: .ir(.select(query)),
                page: QueryExecuteOperation.Page(limit: 10)
            ),
            requestID: 26,
            fixture: fixture
        )

        #expect(error.category == .invalidRequest)
        #expect(error.code == "INVALID_QUERY_EXPRESSION")
        #expect(
            error.message
                == "Expression operands are incompatible with numeric expression"
        )
    }

    @Test("durable unordered paging enforces the complete Ready and destination row bound")
    func durableUnorderedPagingUsesBoundedMemory() async throws {
        let rowCount = 48
        let pageSize = 2
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await insert(
            stride(from: 0, to: rowCount, by: 2).map {
                ("primary-\($0)", Int64($0))
            },
            into: fixture.primaryBaseID,
            container: fixture.container
        )
        try await insert(
            stride(from: 1, to: rowCount, by: 2).map {
                ("secondary-\($0)", Int64($0))
            },
            into: fixture.secondaryBaseID,
            container: fixture.container
        )
        let query = SelectQuery(
            projection: .all,
            source: .table(TableRef(DatabaseEndpointEntity.persistableType))
        )
        let insufficientBudget = ExecutionBudget(
            maximumRows: 100,
            maximumWorkUnits: 1_000_000,
            maximumIntermediateRows: 8,
            maximumIntermediateBytes: 1 * 1_024 * 1_024,
            timeoutMilliseconds: 30_000
        )
        let rejected = try await remoteFailure(
            QueryExecuteOperation.Request(
                input: .ir(.select(query)),
                page: .init(limit: UInt32(pageSize)),
                budget: insufficientBudget
            ),
            requestID: 26,
            fixture: fixture
        )
        #expect(rejected.category == .resourceLimit)
        #expect(rejected.code == "QUERY_RESOURCE_LIMIT")
        #expect(rejected.message.contains("exceeding 8"))

        // Framework retains Ready rows and source/projected page owners with
        // at most one lookahead row each. Server adds two destination pages.
        let sourcePageCount = (rowCount + pageSize - 1) / pageSize
        let readyRowBound = rowCount + 2 * sourcePageCount * (pageSize + 1)
        let budget = ExecutionBudget(
            maximumRows: 100,
            maximumWorkUnits: 1_000_000,
            maximumIntermediateRows: UInt32(readyRowBound + 2 * pageSize),
            maximumIntermediateBytes: 1 * 1_024 * 1_024,
            timeoutMilliseconds: 30_000
        )
        var continuation: ByteString?
        var values: [Int64] = []
        var requestID: UInt64 = 27
        repeat {
            let page = try await successfulPage(
                QueryExecuteOperation.Request(
                    input: .ir(.select(query)),
                    page: QueryExecuteOperation.Page(
                        limit: UInt32(pageSize),
                        continuation: continuation
                    ),
                    budget: budget
                ),
                requestID: requestID,
                fixture: fixture
            )
            values.append(contentsOf: try priorities(page))
            continuation = page.continuation
            requestID += 1
        } while continuation != nil
        #expect(values.count == rowCount)
        #expect(values.sorted() == (0..<rowCount).map(Int64.init))
    }

    @Test("DISTINCT merges exact rows and retains every contributor")
    func distinctRowsRetainContributors() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await insert(
            [("primary-1", 1), ("primary-3", 3)],
            into: fixture.primaryBaseID,
            container: fixture.container
        )
        try await insert(
            [("secondary-1", 1), ("secondary-2", 2)],
            into: fixture.secondaryBaseID,
            container: fixture.container
        )

        let first = try await successfulPage(
            distinctPriorityRequest(pageLimit: 1),
            requestID: 27,
            fixture: fixture
        )
        #expect(try priorities(first) == [1])
        var firstOrigins = try #require(first.provenance)
            .makeOriginIterator()
        #expect(
            try firstOrigins.next() == .derived(
                contributors: [
                    fixture.primaryBaseID,
                    fixture.secondaryBaseID,
                ].sorted()
            )
        )
        #expect(try firstOrigins.next() == nil)

        guard let firstContinuation = first.continuation else {
            Issue.record("Expected the first DISTINCT page to continue")
            return
        }
        let second = try await successfulPage(
            distinctPriorityRequest(
                pageLimit: 1,
                continuation: firstContinuation
            ),
            requestID: 28,
            fixture: fixture
        )
        #expect(try priorities(second) == [2])
        guard let secondContinuation = second.continuation else {
            Issue.record("Expected the second DISTINCT page to continue")
            return
        }
        let third = try await successfulPage(
            distinctPriorityRequest(
                pageLimit: 1,
                continuation: secondContinuation
            ),
            requestID: 29,
            fixture: fixture
        )
        #expect(try priorities(third) == [3])
        #expect(third.continuation == nil)
    }

    @Test("single-page DISTINCT releases its unpublished snapshot slot")
    func singlePageDistinctReleasesSnapshotSlot() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await insert(
            [("primary", 1)],
            into: fixture.primaryBaseID,
            container: fixture.container
        )
        try await insert(
            [("secondary", 1)],
            into: fixture.secondaryBaseID,
            container: fixture.container
        )

        for requestID in 100..<109 {
            let page = try await successfulPage(
                distinctPriorityRequest(pageLimit: 10),
                requestID: UInt64(requestID),
                fixture: fixture
            )
            #expect(try priorities(page) == [1])
            #expect(page.continuation == nil)
        }
    }

    #if DATABASE_OPERATIONS_TEST_VECTOR_INDEXES
    @Test("vector search merges one comparable score contract globally")
    func vectorSearchMergesGlobally() async throws {
        let fixture = try await makeFixture(
            schema: try Schema(
                entities: [try DatabaseCompositionVectorEntity.schemaEntity],
                version: Schema.Version(1, 0, 0)
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        DatabaseCompositionVectorEntity.self
                    )
                ]
            )
        )
        defer { await fixture.container.shutdown() }
        try await insertVectors(
            [
                ("a-0", [0, 0]),
                ("a-4", [4, 0]),
            ],
            into: fixture.primaryBaseID,
            container: fixture.container
        )
        try await insertVectors(
            [
                ("b-1", [1, 0]),
                ("b-2", [2, 0]),
            ],
            into: fixture.secondaryBaseID,
            container: fixture.container
        )

        let first = try await successfulPage(
            vectorRequest(pageLimit: 2),
            requestID: 110,
            fixture: fixture
        )
        #expect(try strings("id", page: first) == ["a-0", "b-1"])
        #expect(try distances(first) == [0, 1])
        var firstOrigins = try #require(first.provenance)
            .makeOriginIterator()
        #expect(try firstOrigins.next() == .source(fixture.primaryBaseID))
        #expect(try firstOrigins.next() == .source(fixture.secondaryBaseID))
        #expect(try firstOrigins.next() == nil)

        guard let firstContinuation = first.continuation else {
            Issue.record("Expected the first vector page to continue")
            return
        }
        let second = try await successfulPage(
            vectorRequest(
                pageLimit: 2,
                continuation: firstContinuation
            ),
            requestID: 111,
            fixture: fixture
        )
        #expect(try strings("id", page: second) == ["b-2"])
        #expect(try distances(second) == [2])
        #expect(second.continuation == nil)
    }
    #endif

    #if DATABASE_OPERATIONS_TEST_GRAPH_INDEXES
    @Test("SPARQL DISTINCT preserves Base-qualified blank-node identity")
    func sparqlDistinctQualifiesBlankNodes() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        let predicate = try RDFTerm.iri(validating: "urn:composition:predicate")
        let object = try RDFTerm.iri(validating: "urn:composition:object")
        let sharedSubject = try RDFTerm.iri(
            validating: "urn:composition:shared-subject"
        )
        let blankSubject = RDFTerm.blankNode(
            try RDFBlankNodeIdentifier("same-local-label")
        )
        for baseID in [fixture.primaryBaseID, fixture.secondaryBaseID] {
            try await insertRDF(
                [
                    try RDFQuad(
                        validatingSubject: blankSubject,
                        predicate: predicate,
                        object: object
                    ),
                    try RDFQuad(
                        validatingSubject: sharedSubject,
                        predicate: predicate,
                        object: object
                    ),
                ],
                into: baseID,
                container: fixture.container
            )
        }
        let query = SelectQuery(
            projection: .distinctItems([
                ProjectionItem(.variable(Variable("subject"))),
                ProjectionItem(.variable(Variable("object"))),
            ]),
            source: .graphPattern(
                .bgp(
                    TriplePattern(
                        subject: .variable("subject"),
                        predicate: .iri("urn:composition:predicate"),
                        object: .variable("object")
                    )
                )
            ),
            orderBy: [
                SortKey(.variable(Variable("subject")))
            ]
        )

        let page = try await successfulPage(
            QueryExecuteOperation.Request(
                input: .ir(.select(query)),
                page: QueryExecuteOperation.Page(limit: 10)
            ),
            requestID: 112,
            fixture: fixture
        )
        let subjects = try rdfTerms("subject", page: page)
        #expect(subjects.count == 3)
        let blankIdentifiers = subjects.compactMap { term -> String? in
            guard case .blankNode(let identifier) = term else { return nil }
            return identifier.rawValue
        }
        #expect(blankIdentifiers.count == 2)
        #expect(Set(blankIdentifiers).count == 2)
        #expect(
            subjects.contains(
                try RDFTerm.iri(
                    validating: "urn:composition:shared-subject"
                )
            )
        )

        var origins = try #require(page.provenance).makeOriginIterator()
        var values: [CompositionOrigin] = []
        while let origin = try origins.next() { values.append(origin) }
        #expect(values.filter { origin in
            if case .source = origin { return true }
            return false
        }.count == 2)
        #expect(
            values.contains(
                .derived(
                    contributors: [
                        fixture.primaryBaseID,
                        fixture.secondaryBaseID,
                    ].sorted()
                )
            )
        )
    }

    @Test("SPARQL SERVICE is rejected before Composition execution")
    func sparqlServiceIsUnsupported() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        let query = SelectQuery(
            projection: .all,
            source: .service(
                endpoint: "https://example.invalid/sparql",
                pattern: .basic([]),
                silent: false
            )
        )

        let error = try await remoteFailure(
            QueryExecuteOperation.Request(
                input: .ir(.select(query)),
                page: QueryExecuteOperation.Page(limit: 10)
            ),
            requestID: 113,
            fixture: fixture
        )
        #expect(error.category == .invalidRequest)
        #expect(error.code == "COMPOSITION_PLAN_UNSUPPORTED")
    }

    @Test("SPARQL REDUCED is rejected instead of weakening semantics")
    func sparqlReducedIsUnsupported() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        let query = SelectQuery(
            projection: .all,
            source: .graphPattern(.basic([])),
            reduced: true
        )

        let error = try await remoteFailure(
            QueryExecuteOperation.Request(
                input: .ir(.select(query)),
                page: QueryExecuteOperation.Page(limit: 10)
            ),
            requestID: 114,
            fixture: fixture
        )
        #expect(error.category == .invalidRequest)
        #expect(error.code == "COMPOSITION_PLAN_UNSUPPORTED")
    }

    @Test("SPARQL ASK evaluates every Base in one federated snapshot")
    func sparqlAskUsesFederatedSnapshotAndProvenance() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await insertRDF(
            [
                try RDFQuad(
                    validatingSubject: .iri(
                        validating: "urn:composition:ask-subject"
                    ),
                    predicate: .iri(
                        validating: "urn:composition:ask-predicate"
                    ),
                    object: .iri(
                        validating: "urn:composition:ask-object"
                    )
                )
            ],
            into: fixture.secondaryBaseID,
            container: fixture.container
        )
        let matching = AskQuery(
            pattern: .basic([
                TriplePattern(
                    subject: .variable("subject"),
                    predicate: .iri("urn:composition:ask-predicate"),
                    object: .variable("object")
                )
            ])
        )
        let localResult = try await fixture.container.session(
            authorization: TestBaseEnvironment.authorization
        ).composition(fixture.compositionID).ask(matching)
        #expect(localResult.value)
        #expect(
            localResult.origin
                == .derived(contributors: [fixture.secondaryBaseID])
        )
        let matchingResponse = try await invoke(
            QueryExecuteOperation.Request(
                input: .ir(.ask(matching)),
                page: QueryExecuteOperation.Page(limit: 1)
            ),
            requestID: 115,
            fixture: fixture
        )
        let matchingResult: QueryBooleanResult
        switch matchingResponse {
        case .success(.boolean(let result)):
            matchingResult = result
        default:
            Issue.record("Expected a successful Composition ASK result")
            throw TestFailure.unexpectedResponse
        }
        #expect(matchingResult.value)
        var matchingOrigins = try #require(matchingResult.provenance)
            .makeOriginIterator()
        #expect(
            try matchingOrigins.next()
                == .derived(contributors: [fixture.secondaryBaseID])
        )
        #expect(try matchingOrigins.next() == nil)
        if case .federated(let points) = matchingResult.consistency {
            #expect(points.count == 2)
        } else {
            Issue.record("Expected federated ASK consistency")
        }

        let missing = AskQuery(
            pattern: .basic([
                TriplePattern(
                    subject: .variable("subject"),
                    predicate: .iri("urn:composition:missing-predicate"),
                    object: .variable("object")
                )
            ])
        )
        let missingResponse = try await invoke(
            QueryExecuteOperation.Request(
                input: .ir(.ask(missing)),
                page: QueryExecuteOperation.Page(limit: 1)
            ),
            requestID: 116,
            fixture: fixture
        )
        let missingResult: QueryBooleanResult
        switch missingResponse {
        case .success(.boolean(let result)):
            missingResult = result
        default:
            Issue.record("Expected a successful negative Composition ASK result")
            throw TestFailure.unexpectedResponse
        }
        #expect(!missingResult.value)
        var missingOrigins = try #require(missingResult.provenance)
            .makeOriginIterator()
        #expect(
            try missingOrigins.next()
                == .derived(
                    contributors: [
                        fixture.primaryBaseID,
                        fixture.secondaryBaseID,
                    ].sorted()
                )
        )
        #expect(try missingOrigins.next() == nil)
    }

    @Test("SPARQL ASK rejects a non-local SERVICE pattern")
    func sparqlAskServiceIsUnsupported() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        let query = AskQuery(
            pattern: .service(
                endpoint: "https://example.invalid/sparql",
                pattern: .basic([]),
                silent: false
            )
        )

        let error = try await remoteFailure(
            QueryExecuteOperation.Request(
                input: .ir(.ask(query)),
                page: QueryExecuteOperation.Page(limit: 1)
            ),
            requestID: 117,
            fixture: fixture
        )
        #expect(error.category == .invalidRequest)
        #expect(error.code == "COMPOSITION_PLAN_UNSUPPORTED")
    }

    @Test("CONSTRUCT unions exact quads with Base-qualified blank nodes and durable paging")
    func constructUnionPreservesIdentityAndSnapshot() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        let sourcePredicate = try RDFTerm.iri(
            validating: "urn:composition:construct-source"
        )
        let object = try RDFTerm.iri(
            validating: "urn:composition:construct-object"
        )
        let sharedSubject = try RDFTerm.iri(
            validating: "urn:composition:construct-shared"
        )
        let blankSubject = RDFTerm.blankNode(
            try RDFBlankNodeIdentifier("same-local-label")
        )
        for baseID in [fixture.primaryBaseID, fixture.secondaryBaseID] {
            try await insertRDF(
                [
                    try RDFQuad(
                        validatingSubject: blankSubject,
                        predicate: sourcePredicate,
                        object: object
                    ),
                    try RDFQuad(
                        validatingSubject: sharedSubject,
                        predicate: sourcePredicate,
                        object: object
                    ),
                ],
                into: baseID,
                container: fixture.container
            )
        }
        let query = ConstructQuery(
            template: [
                TriplePattern(
                    subject: .variable("subject"),
                    predicate: .iri("urn:composition:construct-derived"),
                    object: .variable("object")
                )
            ],
            pattern: .basic([
                TriplePattern(
                    subject: .variable("subject"),
                    predicate: .iri("urn:composition:construct-source"),
                    object: .variable("object")
                )
            ])
        )
        var continuation: ByteString?
        var quads: [RDFQuad] = []
        var originByQuad: [RDFQuad: CompositionOrigin] = [:]
        var requestID: UInt64 = 118

        repeat {
            let page = try await successfulGraphPage(
                QueryExecuteOperation.Request(
                    input: .ir(.construct(query)),
                    page: QueryExecuteOperation.Page(
                        limit: 1,
                        continuation: continuation
                    )
                ),
                requestID: requestID,
                fixture: fixture
            )
            var origins = try #require(page.provenance)
                .makeOriginIterator()
            let pageQuads = try page.materializedQuads(
                maximumCount: page.quadCount
            )
            for quad in pageQuads {
                quads.append(quad)
                guard let origin = try origins.next() else {
                    Issue.record("Expected provenance for every RDF quad")
                    return
                }
                originByQuad[quad] = origin
            }
            #expect(try origins.next() == nil)
            continuation = page.continuation
            if requestID == 118 {
                try await insertRDF(
                    [
                        try RDFQuad(
                            validatingSubject: .iri(
                                validating:
                                    "urn:composition:inserted-after-snapshot"
                            ),
                            predicate: sourcePredicate,
                            object: object
                        )
                    ],
                    into: fixture.primaryBaseID,
                    container: fixture.container
                )
            }
            requestID += 1
        } while continuation != nil

        #expect(quads.count == 3)
        #expect(Set(quads).count == 3)
        let blankIdentifiers = quads.compactMap { quad -> String? in
            guard case .blankNode(let identifier) = quad.subject else {
                return nil
            }
            return identifier.rawValue
        }
        #expect(blankIdentifiers.count == 2)
        #expect(Set(blankIdentifiers).count == 2)
        let sharedIRI = try RDFIRI("urn:composition:construct-shared")
        let shared = try #require(quads.first { quad in
            quad.subject == .iri(sharedIRI)
        })
        #expect(
            originByQuad[shared] == .derived(
                contributors: [
                    fixture.primaryBaseID,
                    fixture.secondaryBaseID,
                ].sorted()
            )
        )
    }

    @Test("DESCRIBE unions outgoing quads and merges exact contributors")
    func describeUnionMergesContributors() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        let subject = try RDFTerm.iri(
            validating: "urn:composition:described"
        )
        let predicate = try RDFTerm.iri(
            validating: "urn:composition:detail"
        )
        let commonObject = try RDFTerm.iri(
            validating: "urn:composition:common"
        )
        try await insertRDF(
            [
                try RDFQuad(
                    validatingSubject: subject,
                    predicate: predicate,
                    object: commonObject
                ),
                try RDFQuad(
                    validatingSubject: subject,
                    predicate: predicate,
                    object: .iri(validating: "urn:composition:primary")
                ),
            ],
            into: fixture.primaryBaseID,
            container: fixture.container
        )
        try await insertRDF(
            [
                try RDFQuad(
                    validatingSubject: subject,
                    predicate: predicate,
                    object: commonObject
                ),
                try RDFQuad(
                    validatingSubject: subject,
                    predicate: predicate,
                    object: .iri(validating: "urn:composition:secondary")
                ),
            ],
            into: fixture.secondaryBaseID,
            container: fixture.container
        )
        let page = try await successfulGraphPage(
            QueryExecuteOperation.Request(
                input: .ir(
                    .describe(
                        DescribeQuery(
                            selection: .resources(
                                first: .iri("urn:composition:described"),
                                additional: []
                            )
                        )
                    )
                ),
                page: QueryExecuteOperation.Page(limit: 10)
            ),
            requestID: 130,
            fixture: fixture
        )
        let quads = try page.materializedQuads(maximumCount: page.quadCount)
        #expect(quads.count == 3)
        var origins = try #require(page.provenance).makeOriginIterator()
        var originByObject: [RDFTerm: CompositionOrigin] = [:]
        for quad in quads {
            guard let origin = try origins.next() else {
                Issue.record("Expected provenance for every RDF quad")
                return
            }
            originByObject[quad.object] = origin
        }
        #expect(
            originByObject[commonObject] == .derived(
                contributors: [
                    fixture.primaryBaseID,
                    fixture.secondaryBaseID,
                ].sorted()
            )
        )
        #expect(try origins.next() == nil)
    }
    #endif

    @Test("expired durable snapshots are removed from every index")
    func expiredSnapshotCleanup() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await seed(fixture)
        let first = try await successfulPage(
            request(pageLimit: 1),
            requestID: 30,
            fixture: fixture
        )
        let continuation = try #require(first.continuation)

        try fixture.clock.advance(seconds: 15 * 60 + 1)
        try await fixture.snapshotStore.cleanupExpired()

        let error = try await remoteFailure(
            request(pageLimit: 1, continuation: continuation),
            requestID: 31,
            fixture: fixture
        )
        #expect(error.category == .invalidRequest)
        #expect(error.code == "INVALID_CONTINUATION")
    }

    @Test("concurrent snapshot creation atomically enforces eight slots")
    func concurrentSnapshotLimit() async throws {
        let fixture = try await makeFixture()
        defer { await fixture.container.shutdown() }
        try await seed(fixture)

        let outcomes = try await withThrowingTaskGroup(
            of: SnapshotCreationOutcome.self
        ) { group in
            for requestID in 40..<49 {
                group.addTask {
                    let response = try await invoke(
                        request(pageLimit: 1),
                        requestID: UInt64(requestID),
                        fixture: fixture
                    )
                    switch response {
                    case .success:
                        return .success
                    case .failure(let error):
                        guard error.category == .resourceLimit,
                              error.code == "QUERY_SNAPSHOT_LIMIT" else {
                            throw TestFailure.unexpectedRemoteFailure(error)
                        }
                        return .limit
                    }
                }
            }
            var values: [SnapshotCreationOutcome] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }
        #expect(outcomes.filter { $0 == .success }.count == 8)
        #expect(outcomes.filter { $0 == .limit }.count == 1)
    }

    private struct Fixture {
        let container: DBContainer
        let endpoint: DatabaseWireEndpoint
        let primaryBaseID: Base.ID
        let secondaryBaseID: Base.ID
        let compositionID: Base.Composition.ID
        let snapshotStore: DatabaseQuerySnapshotStore
        let clock: Clock
    }

    private enum SnapshotCreationOutcome: Sendable {
        case success
        case limit
    }

    private final class Clock: WallClock, Sendable {
        private let timestamp = Mutex(Timestamp(secondsSinceUnixEpoch: 0))

        var now: Timestamp {
            timestamp.withLock { $0 }
        }

        func advance(seconds: Int64) throws {
            try timestamp.withLock { timestamp in
                let next = timestamp.secondsSinceUnixEpoch
                    .addingReportingOverflow(seconds)
                guard !next.overflow else {
                    throw TestFailure.unexpectedResponse
                }
                timestamp = try Timestamp(
                    secondsSinceUnixEpoch:
                        next.partialValue,
                    nanoseconds: timestamp.nanoseconds
                )
            }
        }
    }

    private actor Scheduler: DatabaseJobScheduler {
        private var earliest: Timestamp?

        func ensureWakeUp(noLaterThan timestamp: Timestamp) async throws {
            earliest = earliest.map { min($0, timestamp) } ?? timestamp
        }
    }

    private func makeFixture(
        schema: Schema? = nil,
        runtimeConfiguration: DatabaseRuntimeConfiguration? = nil,
        controlEngine: any StorageEngine = InMemoryEngine()
    ) async throws -> Fixture {
        let controlDomainID = try DatabaseStorageDomain.ID("control")
        let dataDomainID = try DatabaseStorageDomain.ID("secondary-data")
        let primaryPlacementID = try Base.Placement.ID("primary")
        let secondaryPlacementID = try Base.Placement.ID("secondary")
        let primaryBaseID = try TestBaseEnvironment.id()
        let principal = Principal(
            identifier: "test-runner",
            roles: ["test-runner"]
        )
        let topology = try DatabaseStorageTopology(
            controlDomainID: controlDomainID,
            domains: [
                try DatabaseStorageDomain(
                    id: controlDomainID,
                    rootPath: ["database", "control"],
                    storageEngine: controlEngine
                ),
                try DatabaseStorageDomain(
                    id: dataDomainID,
                    rootPath: ["database", "secondary-data"],
                    storageEngine: InMemoryEngine()
                ),
            ],
            placements: [
                DatabaseStoragePlacement(
                    id: primaryPlacementID,
                    domainID: controlDomainID
                ),
                DatabaseStoragePlacement(
                    id: secondaryPlacementID,
                    domainID: dataDomainID
                ),
            ],
            defaultPlacementID: primaryPlacementID
        )
        let resolvedSchema = try schema ?? Schema(
            entities: [try DatabaseEndpointEntity.schemaEntity],
            version: Schema.Version(1, 0, 0)
        )
        let resolvedRuntime = try runtimeConfiguration
            ?? DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        DatabaseEndpointEntity.self
                    )
                ]
            )
        let container = try await DBContainer.open(
            for: resolvedSchema,
            configuration: DBConfiguration(
                name: "composition-multi-domain",
                storageTopology: topology,
                monotonicClock: TestProcessMonotonicClock(),
                wallClock: FixedTestWallClock()
            ),
            runtimeConfiguration: resolvedRuntime,
            security: .testingDisabled
        )
        _ = try await container.provisionBase(
            primaryBaseID,
            placementID: primaryPlacementID,
            initialGrants: [
                Security.Grant(
                    subject: .principal(principal.identifier),
                    resource: .base(primaryBaseID),
                    access: .all
                )
            ],
            expectedRevision: 0
        )
        let secondaryBaseID = try Base.ID("other")
        _ = try await container.provisionBase(
            secondaryBaseID,
            placementID: secondaryPlacementID,
            initialGrants: [
                Security.Grant(
                    subject: .principal("test-runner"),
                    resource: .base(secondaryBaseID),
                    access: .all
                )
            ],
            expectedRevision: 0
        )
        let compositionID = try Base.Composition.ID("shared")
        _ = try await container.withControlMetadataTransaction {
            transaction in
            try await container.compositionCatalog.create(
                try Base.Composition(
                    id: compositionID,
                    bases: [primaryBaseID, secondaryBaseID]
                ),
                expectedRevision: 0,
                transaction: transaction.executionStorageAccess
            )
        }
        let clock = Clock()
        let snapshotStore = DatabaseQuerySnapshotStore(
            container: container,
            clock: AnyDatabaseWallClock(clock),
            identifierGenerator: AnyDatabaseUUIDGenerator(
                RandomDatabaseUUIDGenerator()
            ),
            scheduler: AnyDatabaseJobScheduler(Scheduler()),
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
        return Fixture(
            container: container,
            endpoint: DatabaseWireEndpoint(
                container: container,
                registry: registry,
                admissionPolicy: AnyDatabaseOperationAdmissionPolicy(
                    UnrestrictedDatabaseOperationAdmissionPolicy()
                )
            ),
            primaryBaseID: primaryBaseID,
            secondaryBaseID: secondaryBaseID,
            compositionID: compositionID,
            snapshotStore: snapshotStore,
            clock: clock
        )
    }

    private func seed(_ fixture: Fixture) async throws {
        try await insert(
            [("primary-1", 1), ("primary-3", 3)],
            into: fixture.primaryBaseID,
            container: fixture.container
        )
        try await insert(
            [("other-2", 2), ("other-4", 4)],
            into: fixture.secondaryBaseID,
            container: fixture.container
        )
    }

    private func insert(
        _ values: [(String, Int64)],
        into baseID: Base.ID,
        container: DBContainer
    ) async throws {
        let context = container.session(
            authorization: TestBaseEnvironment.authorization
        ).base(baseID).newContext()
        for (id, priority) in values {
            var entity = DatabaseEndpointEntity()
            entity.id = id
            entity.title = id
            entity.priority = priority
            try context.insert(entity)
        }
        try await context.save()
    }

    #if DATABASE_OPERATIONS_TEST_VECTOR_INDEXES
    private func insertVectors(
        _ values: [(String, [Float])],
        into baseID: Base.ID,
        container: DBContainer
    ) async throws {
        let context = container.session(
            authorization: TestBaseEnvironment.authorization
        ).base(baseID).newContext()
        for (id, embedding) in values {
            try context.insert(
                DatabaseCompositionVectorEntity(
                    id: id,
                    title: id,
                    embedding: try Vector(float32: embedding)
                )
            )
        }
        try await context.save()
    }
    #endif

    #if DATABASE_OPERATIONS_TEST_GRAPH_INDEXES
    private func insertRDF(
        _ quads: [RDFQuad],
        into baseID: Base.ID,
        container: DBContainer
    ) async throws {
        let context = container.session(
            authorization: TestBaseEnvironment.authorization
        ).base(baseID).newContext()
        try await context.withDataOperation {
            let lease = try context.executionStorage()
            let store = CanonicalRDFGraphStore(
                rootSubspace: CanonicalRDFGraphStore.rootSubspace(
                    forDataRoot: lease.dataRoot
                )
            )
            _ = try await context.container.transactionExecutor
                .withTransaction(
                    configuration: .batch,
                    clock: context.container.monotonicClock
                ) { transaction in
                    let workMeter = DatabaseWorkMeter(
                        budget: ExecutionBudget(),
                        monotonicClock: context.container.monotonicClock
                    )
                    for quad in quads {
                        _ = try await store.insert(
                            quad,
                            transaction: transaction,
                            workMeter: workMeter
                        )
                    }
                }
        }
    }

    private func rdfTerms(
        _ name: String,
        page: QueryRowPage
    ) throws -> [RDFTerm] {
        let index = try #require(page.columns.firstIndex { $0.name == name })
        return try page.materializedRows(maximumCount: page.rowCount).map {
            row in
            guard case .primitive(.rdfTerm(let term)) = row.values[index] else {
                throw TestFailure.unexpectedResponse
            }
            return term
        }
    }

    private func successfulGraphPage(
        _ request: QueryExecuteOperation.Request,
        requestID: UInt64,
        fixture: Fixture
    ) async throws -> RDFGraphPage {
        let response = try await invoke(
            request,
            requestID: requestID,
            fixture: fixture
        )
        switch response {
        case .success(.rdfGraph(let page)):
            return page
        case .failure(let error):
            Issue.record(
                "Expected a successful Composition RDF graph page, got \(error.code): \(error.message)"
            )
            throw TestFailure.unexpectedResponse
        default:
            Issue.record("Expected a successful Composition RDF graph page")
            throw TestFailure.unexpectedResponse
        }
    }
    #endif

    private func request(
        pageLimit: UInt32,
        continuation: ByteString? = nil,
        budget: ExecutionBudget = ExecutionBudget()
    ) -> QueryExecuteOperation.Request {
        QueryExecuteOperation.Request(
            input: .ir(
                .select(
                    SelectQuery(
                        projection: .all,
                        source: .table(
                            TableRef(DatabaseEndpointEntity.persistableType)
                        ),
                        orderBy: [SortKey(.col("priority"))]
                    )
                )
            ),
            page: QueryExecuteOperation.Page(
                limit: pageLimit,
                continuation: continuation
            ),
            budget: budget
        )
    }

    private func distinctPriorityRequest(
        pageLimit: UInt32,
        continuation: ByteString? = nil
    ) -> QueryExecuteOperation.Request {
        QueryExecuteOperation.Request(
            input: .ir(
                .select(
                    SelectQuery(
                        projection: .distinctItems([
                            .column("priority")
                        ]),
                        source: .table(
                            TableRef(DatabaseEndpointEntity.persistableType)
                        ),
                        orderBy: [SortKey(.col("priority"))]
                    )
                )
            ),
            page: QueryExecuteOperation.Page(
                limit: pageLimit,
                continuation: continuation
            )
        )
    }

    #if DATABASE_OPERATIONS_TEST_VECTOR_INDEXES
    private func vectorRequest(
        pageLimit: UInt32,
        continuation: ByteString? = nil
    ) throws -> QueryExecuteOperation.Request {
        QueryExecuteOperation.Request(
            input: .ir(
                .select(
                    SelectQuery(
                        projection: .all,
                        source: .table(
                            TableRef(
                                DatabaseCompositionVectorEntity.persistableType
                            )
                        ),
                        accessPath: .index(
                            IndexScanSource(
                                indexName:
                                    "DatabaseCompositionVectorEntity_embedding",
                                indexType: .vector,
                                parameters: [
                                    "fieldName": .string("embedding"),
                                    "dimensions": .int64(2),
                                    "queryVector": .vector(
                                        try Vector(float32: [0, 0])
                                    ),
                                    "k": .int64(3),
                                    "metric": .string("euclidean"),
                                ]
                            )
                        ),
                        limit: 3
                    )
                )
            ),
            page: QueryExecuteOperation.Page(
                limit: pageLimit,
                continuation: continuation
            )
        )
    }

    private func strings(
        _ name: String,
        page: QueryRowPage
    ) throws -> [String] {
        let index = try #require(page.columns.firstIndex { $0.name == name })
        return try page.materializedRows(maximumCount: page.rowCount).map {
            row in
            guard case .primitive(.string(let value)) = row.values[index] else {
                throw TestFailure.unexpectedResponse
            }
            return value
        }
    }

    private func distances(_ page: QueryRowPage) throws -> [Double] {
        try page.materializedRows(maximumCount: page.rowCount).map { row in
            guard case .float64(let value)? = row.annotations["distance"] else {
                throw TestFailure.unexpectedResponse
            }
            return value
        }
    }
    #endif

    private func successfulPage(
        _ request: QueryExecuteOperation.Request,
        requestID: UInt64,
        fixture: Fixture,
        selection: CompositionSelection? = nil
    ) async throws -> QueryRowPage {
        let response = try await invoke(
            request,
            requestID: requestID,
            fixture: fixture,
            selection: selection
        )
        switch response {
        case .success(.rows(let page)):
            return page
        case .failure(let error):
            Issue.record(
                "Expected a successful Composition row page, got \(error.code): \(error.message)"
            )
            throw TestFailure.unexpectedResponse
        default:
            Issue.record("Expected a successful Composition row page")
            throw TestFailure.unexpectedResponse
        }
    }

    private func remoteFailure(
        _ request: QueryExecuteOperation.Request,
        requestID: UInt64,
        fixture: Fixture
    ) async throws -> RemoteOperationError {
        let response = try await invoke(
            request,
            requestID: requestID,
            fixture: fixture
        )
        guard case .failure(let error) = response else {
            Issue.record("Expected a typed Composition query failure")
            throw TestFailure.unexpectedResponse
        }
        return error
    }

    private func invoke(
        _ request: QueryExecuteOperation.Request,
        requestID: UInt64,
        fixture: Fixture,
        selection: CompositionSelection? = nil
    ) async throws -> Result<
        QueryExecuteOperation.Response,
        RemoteOperationError
    > {
        let bytes = try DatabaseWireEncoder().encodeRequest(
            DatabaseOperationCatalog.queryExecute,
            requestID: requestID,
            target: .composition(
                selection ?? .named(fixture.compositionID)
            ),
            request: request
        )
        return try DatabaseWireDecoder().decodeResponse(
            DatabaseOperationCatalog.queryExecute,
            from: try await fixture.endpoint.execute(
                bytes,
                context: DatabaseRequestExecutionContext(
                    authorization: TestBaseEnvironment.authorization
                )
            ),
            matching: requestID
        )
    }

    private func priorities(_ page: QueryRowPage) throws -> [Int64] {
        let index = try #require(
            page.columns.firstIndex { $0.name == "priority" }
        )
        return try page.materializedRows(maximumCount: page.rowCount).map {
            row in
            guard case .primitive(.int64(let value)) = row.values[index] else {
                throw TestFailure.unexpectedResponse
            }
            return value
        }
    }

    private func value(
        _ name: String,
        row: DatabaseWire.QueryRow,
        page: QueryRowPage
    ) throws -> FieldValue {
        let index = try #require(page.columns.firstIndex { $0.name == name })
        guard case .primitive(let value) = row.values[index] else {
            throw TestFailure.unexpectedResponse
        }
        return value
    }

    private enum TestFailure: Error {
        case unexpectedResponse
        case unexpectedRemoteFailure(RemoteOperationError)
    }
}

private actor BuilderStartGate {
    private var didEnter = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { continuation in
            startWaiter = continuation
        }
    }

    func enterAndWait() async {
        didEnter = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
#endif
