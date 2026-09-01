import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
#if DATABASE_OPERATIONS_GRAPH_INDEXES
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import DatabaseKit
import StorageKit

private enum DatabaseGraphInitialPlan: Sendable {
    case page(
        DatabaseSharedRetainedRDFGraph,
        DatabaseTransactionReadPoint.Value
    )
    case historical(
        DatabaseSharedRetainedRDFGraph,
        UInt64,
        ByteString,
        DatabaseTransactionReadPoint.Value
    )
    case captured(
        DatabaseSharedRetainedRDFGraph,
        DatabaseTransactionReadPoint.Value
    )
}

struct DatabaseGraphQueryService: Sendable {
    private let wireLimits: DatabaseWireLimits
    private let queryStructuralLimits: QueryStructuralLimits
    private let querySnapshotStore: DatabaseQuerySnapshotStore?

    init(
        wireLimits: DatabaseWireLimits = .default,
        queryStructuralLimits: QueryStructuralLimits = .default,
        querySnapshotStore: DatabaseQuerySnapshotStore? = nil
    ) {
        self.wireLimits = wireLimits
        self.queryStructuralLimits = queryStructuralLimits
        self.querySnapshotStore = querySnapshotStore
    }

    func executeConstruct(
        _ query: ConstructQuery,
        request: QueryExecuteOperation.Request,
        context: DatabaseOperationContext,
        workMeter: DatabaseWorkMeter
    ) async throws -> RDFGraphPage {
        return try await execute(
            statement: .construct(query),
            request: request,
            context: context,
            workMeter: workMeter
        ) { session, requestFingerprint in
            return try await session.executeSPARQLConstruct(
                query,
                nodeNamespace: try GraphResultNodeNamespace(
                    requestFingerprint
                ),
                options: readExecution(
                    for: request,
                    workMeter: workMeter,
                    context: context
                ),
                partitions: request.graphPartitions
            )
        }
    }

    func executeDescribe(
        _ query: DescribeQuery,
        request: QueryExecuteOperation.Request,
        context: DatabaseOperationContext,
        workMeter: DatabaseWorkMeter
    ) async throws -> RDFGraphPage {
        return try await execute(
            statement: .describe(query),
            request: request,
            context: context,
            workMeter: workMeter
        ) { session, _ in
            return try await session.executeSPARQLDescribe(
                query,
                options: readExecution(
                    for: request,
                    workMeter: workMeter,
                    context: context
                ),
                partitions: request.graphPartitions
            )
        }
    }

    private func execute(
        statement: QueryStatement,
        request: QueryExecuteOperation.Request,
        context: DatabaseOperationContext,
        workMeter: DatabaseWorkMeter,
        materialize: @escaping @Sendable (
            _ session: DatabaseReadSession,
            _ requestFingerprint: ByteString
        ) async throws -> DatabaseRetainedRDFGraph
    ) async throws -> RDFGraphPage {
        guard request.page.limit <= request.budget.maximumRows else {
            throw DatabaseGraphQueryError.pageLimitExceedsMaximum(
                requested: request.page.limit,
                maximum: request.budget.maximumRows
            )
        }
        let requestFingerprint = try fingerprint(
            statement: statement,
            request: request
        )
        let databaseContext = try context.requireDataContext()
        let lease = try databaseContext.executionStorage()
        let queryFingerprint = try DatabaseQuerySnapshotStore.queryFingerprint(
            statement: statement,
            request: request,
            limits: wireLimits
        )
        guard let pageLimit = Int(exactly: request.page.limit) else {
            throw DatabaseGraphQueryError.pageLimitExceedsPlatformCapacity(
                requested: request.page.limit
            )
        }
        if let continuation = request.page.continuation {
            guard continuation.count == DatabaseQuerySnapshotStore
                    .continuationByteCount,
                  continuation.first == DatabaseQuerySnapshotStore
                    .continuationMarker else {
                throw DatabaseGraphQueryError.invalidContinuation
            }
            guard let querySnapshotStore else {
                throw DatabaseQueryExecutionError.invalidContinuation
            }
            if let historical = try await querySnapshotStore
                .loadHistoricalGraph(
                    continuation: continuation,
                    lease: lease,
                    schemaGeneration: context.executor.schemaGeneration,
                    queryFingerprint: queryFingerprint,
                    authorization: context.authorization
                ) {
                let resumed: (
                    graph: DatabaseSharedRetainedRDFGraph,
                    readPoint: DatabaseTransactionReadPoint.Value
                )
                do {
                    resumed = try await databaseContext.withReadSnapshot(
                        restoring: .version(historical.readVersion),
                        workMeter: workMeter
                    ) { snapshot in
                        guard snapshot.position
                            == .version(historical.readVersion) else {
                            throw DatabaseQueryExecutionError
                                .querySnapshotCorrupted
                        }
                        var graph = try await materialize(
                            snapshot.session,
                            requestFingerprint
                        )
                        graph = try canonicalize(
                            consume graph,
                            workMeter: workMeter
                        )
                        let sharedGraph = try graph.moveToSharedOwnership(
                            at: .resultMaterialization
                        )
                        let resultFingerprint = try
                            DatabaseGraphQueryResultFingerprint.compute(
                                graph: sharedGraph,
                                wireLimits: wireLimits,
                                workMeter: workMeter
                            )
                        guard resultFingerprint
                            == historical.resultFingerprint else {
                            throw DatabaseGraphQueryError
                                .continuationSnapshotChanged
                        }
                        return (
                            sharedGraph,
                            DatabaseTransactionReadPoint.value(
                                domainID: lease.domainIdentifier,
                                snapshot: snapshot
                            )
                        )
                    }
                } catch {
                    throw mapHistoricalReadFailure(error)
                }
                let graphCount = resumed.graph.count
                guard let offset = Int(exactly: historical.offset),
                      offset < graphCount else {
                    throw DatabaseGraphQueryError.continuationOffsetOutOfRange(
                        offset: historical.offset,
                        count: graphCount
                    )
                }
                let end = min(offset + pageLimit, graphCount)
                let next = end < graphCount
                    ? try await querySnapshotStore.advanceHistoricalGraph(
                        historical,
                        toOffset: UInt64(end)
                    )
                    : nil
                let page = try makeOutputPage(
                    resumed.graph,
                    range: offset..<end,
                    continuation: next,
                    readPoint: resumed.readPoint
                )
                try workMeter.recordOutput(page)
                if next == nil {
                    try await querySnapshotStore.completeHistoricalGraph(
                        historical
                    )
                }
                return page
            }
            let page = try await querySnapshotStore.loadRDFGraph(
                continuation: continuation,
                lease: lease,
                schemaGeneration: context.executor.schemaGeneration,
                queryFingerprint: queryFingerprint,
                authorization: context.authorization
            )
            try workMeter.recordOutput(page)
            return page
        }
        let plan = try await databaseContext.withReadSnapshot(
            workMeter: workMeter
        ) { snapshot in
                let readPoint = DatabaseTransactionReadPoint.value(
                    domainID: lease.domainIdentifier,
                    snapshot: snapshot
                )

                var graph = try await materialize(
                    snapshot.session,
                    requestFingerprint
                )
                graph = try canonicalize(
                    consume graph,
                    workMeter: workMeter
                )
                let graphCount = graph.count
                let sharedGraph = try graph.moveToSharedOwnership(
                    at: .resultMaterialization
                )
                if graphCount <= pageLimit {
                    return DatabaseGraphInitialPlan.page(
                        sharedGraph,
                        readPoint
                    )
                }
                if snapshot.supportsPositionRestoration,
                   case .version(let readVersion) = snapshot.position {
                    let resultFingerprint = try
                        DatabaseGraphQueryResultFingerprint.compute(
                            graph: sharedGraph,
                            wireLimits: wireLimits,
                            workMeter: workMeter
                        )
                    return DatabaseGraphInitialPlan.historical(
                        sharedGraph,
                        readVersion,
                        resultFingerprint,
                        readPoint
                    )
                }
                precondition(graphCount > pageLimit)
                return DatabaseGraphInitialPlan.captured(
                    sharedGraph,
                    readPoint
                )
        }
        let page: RDFGraphPage
        switch plan {
        case .page(let graph, let readPoint):
            let graphCount = graph.count
            page = try makeOutputPage(
                graph,
                range: 0..<graphCount,
                continuation: nil,
                readPoint: readPoint
            )
            try workMeter.recordOutput(page)
        case .historical(
            let graph,
            let readVersion,
            let resultFingerprint,
            let readPoint
        ):
            guard let querySnapshotStore else {
                throw DatabaseQueryExecutionError.querySnapshotUnavailable(
                    "the host did not provide durable continuation storage"
                )
            }
            let reservation = try await querySnapshotStore.beginWrite(
                for: lease,
                schemaGeneration: context.executor.schemaGeneration,
                queryFingerprint: queryFingerprint,
                authorization: context.authorization
            )
            do {
                let opaqueContinuation = try await querySnapshotStore
                    .publishHistoricalGraph(
                        readVersion: readVersion,
                        resultFingerprint: resultFingerprint,
                        offset: UInt64(pageLimit),
                        in: reservation
                    )
                // The published continuation is the page's own identity, so the
                // response can only be built and accounted for after the
                // manifest exists. Both stay inside the guarded region: a
                // cancelled or refused claim here must release the snapshot
                // instead of leaving a manifest no caller can ever resume.
                let published = try makeOutputPage(
                    graph,
                    range: 0..<pageLimit,
                    continuation: opaqueContinuation,
                    readPoint: readPoint
                )
                try workMeter.recordOutput(published)
                page = published
            } catch {
                let operationError = error
                do {
                    try await querySnapshotStore.abortWrite(reservation)
                } catch {
                    throw StorageTransactionCleanupError(
                        operationError: operationError,
                        cancellationError: error
                    )
                }
                throw operationError
            }
        case .captured(let graph, let readPoint):
            page = try await spoolNonHistoricalGraph(
                graph,
                pageLimit: pageLimit,
                queryFingerprint: queryFingerprint,
                request: request,
                context: context,
                lease: lease,
                readPoint: readPoint,
                workMeter: workMeter
            )
        }
        return page
    }

    private func spoolNonHistoricalGraph(
        _ graph: DatabaseSharedRetainedRDFGraph,
        pageLimit: Int,
        queryFingerprint: ByteString,
        request: QueryExecuteOperation.Request,
        context: DatabaseOperationContext,
        lease: DatabaseExecutionStorage,
        readPoint: DatabaseTransactionReadPoint.Value,
        workMeter: DatabaseWorkMeter
    ) async throws -> RDFGraphPage {
        guard let querySnapshotStore else {
            throw DatabaseQueryExecutionError.querySnapshotUnavailable(
                "the host did not provide durable query snapshot storage"
            )
        }
        let reservation = try await querySnapshotStore.beginWrite(
            for: lease,
            schemaGeneration: context.executor.schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: context.authorization
        )
        do {
            let firstContinuationPageID = try await querySnapshotStore
                .reservePage(in: reservation)
            var currentPageID = firstContinuationPageID
            var continuationPageCount: UInt32 = 0
            var totalPayloadBytes: UInt64 = 0
            var offset = pageLimit

            let graphCount = graph.count
            while offset < graphCount {
                let remaining = graphCount - offset
                let end = remaining <= pageLimit
                    ? graphCount
                    : offset + pageLimit
                let nextPageID = end < graphCount
                    ? try await querySnapshotStore.reservePage(in: reservation)
                    : nil
                let page = try Self.page(
                    graph.materializePage(offset..<end),
                    continuation: nextPageID.map {
                        reservation.continuation(pageID: $0)
                    },
                    readPoint: readPoint
                )
                totalPayloadBytes = try await querySnapshotStore.appendPage(
                    page,
                    pageID: currentPageID,
                    to: reservation,
                    consumedPayloadBytes: totalPayloadBytes,
                    maximumIntermediateBytes: request.budget
                        .maximumIntermediateBytes,
                    workMeter: workMeter
                )
                let nextCount = continuationPageCount
                    .addingReportingOverflow(1)
                guard !nextCount.overflow else {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                continuationPageCount = nextCount.partialValue
                offset = end
                if let nextPageID {
                    currentPageID = nextPageID
                }
            }

            try await querySnapshotStore.commitWrite(
                reservation,
                pageCount: continuationPageCount,
                totalPayloadBytes: totalPayloadBytes
            )
            let firstPage = try makeOutputPage(
                graph,
                range: 0..<pageLimit,
                continuation: reservation.continuation(
                    pageID: firstContinuationPageID
                ),
                readPoint: readPoint
            )
            try workMeter.recordOutput(firstPage)
            return firstPage
        } catch {
            let operationError = error
            do {
                try await querySnapshotStore.abortWrite(reservation)
            } catch {
                throw StorageTransactionCleanupError(
                    operationError: operationError,
                    cancellationError: error
                )
            }
            throw operationError
        }
    }

    private func makeOutputPage(
        _ graph: DatabaseSharedRetainedRDFGraph,
        range: Range<Int>,
        continuation: ByteString?,
        readPoint: DatabaseTransactionReadPoint.Value
    ) throws -> RDFGraphPage {
        return try Self.page(
            graph.materializePage(range),
            continuation: continuation,
            readPoint: readPoint
        )
    }

    private static func page(
        _ quads: consuming [RDFQuad],
        continuation: ByteString?,
        readPoint: DatabaseTransactionReadPoint.Value
    ) throws -> RDFGraphPage {
        #if DATABASE_SERVER_MULTI_BASE
        return try RDFGraphPage(
            quads: consume quads,
            continuation: continuation,
            provenance: nil,
            consistency: .transactional(try readPoint.domainReadPoint)
        )
        #else
        return RDFGraphPage(
            quads: consume quads,
            continuation: continuation,
            snapshotVersion: readPoint.restorableVersion.flatMap {
                Int64(exactly: $0)
            }
        )
        #endif
    }

    private func mapHistoricalReadFailure(
        _ error: any Error
    ) -> any Error {
        if let error = error as? DatabaseQueryExecutionError {
            return error
        }
        if let error = error as? DatabaseGraphQueryError {
            return error
        }
        if let error = error as? DatabaseReadPositionError {
            switch error {
            case .positionIsNotRestorable:
                return DatabaseQueryExecutionError.querySnapshotExpired
            case .versionExceedsStorageRange,
                 .invalidStorageVersion,
                 .restoredPositionChanged:
                return DatabaseQueryExecutionError.querySnapshotCorrupted
            }
        }
        if let error = error as? StorageError,
           error.code == .transactionTooOld
            || error.code == .transactionFutureVersion
        {
            return DatabaseQueryExecutionError.querySnapshotExpired
        }
        return error
    }

    private func canonicalize(
        _ graph: consuming DatabaseRetainedRDFGraph,
        workMeter: DatabaseWorkMeter
    ) throws -> DatabaseRetainedRDFGraph {
        try workMeter.consume(UInt64(graph.count), at: .sortInput)
        let sorted = try graph.sorting { lhs, rhs in
            try workMeter.consume(2, at: .sortComparison)
            return Self.isCanonicalPredecessor(lhs, rhs)
        }
        return try sorted.removingAdjacentDuplicates { lhs, rhs in
            try workMeter.consume(at: .deduplication)
            return lhs == rhs
        }
    }

    private static func isCanonicalPredecessor(
        _ lhs: borrowing RDFQuad,
        _ rhs: borrowing RDFQuad
    ) -> Bool {
        if lhs.subject != rhs.subject {
            return lhs.subject < rhs.subject
        }
        if lhs.predicate != rhs.predicate {
            return lhs.predicate < rhs.predicate
        }
        if lhs.object != rhs.object {
            return lhs.object < rhs.object
        }
        switch (lhs.graph, rhs.graph) {
        case (.none, .some):
            return true
        case (.some, .none), (.none, .none):
            return false
        case (.some(let left), .some(let right)):
            return left < right
        }
    }

    private func fingerprint(
        statement: QueryStatement,
        request: QueryExecuteOperation.Request
    ) throws -> ByteString {
        let normalized = QueryExecuteOperation.Request(
            input: .ir(statement),
            graphPartitions: request.graphPartitions,
            page: QueryExecuteOperation.Page(
                limit: request.page.limit,
                continuation: nil
            ),
            budget: request.budget
        )
        let payload = try DatabaseWireEncoder(
            limits: wireLimits
        ).encodeRequestPayload(
            DatabaseOperationCatalog.queryExecute,
            request: normalized
        )
        return DatabaseRequestDigest.compute(
            operation: .queryExecute,
            prefix: [0x47, 0x51, 0x01],
            payload: payload
        )
    }

    private func readExecution(
        for request: QueryExecuteOperation.Request,
        workMeter: DatabaseWorkMeter,
        context: DatabaseOperationContext
    ) -> ReadExecutionContext {
        ReadExecutionContext(
            options: ReadExecutionOptions(budget: request.budget),
            monotonicClock: context.executor.monotonicClock,
            workMeter: workMeter,
            queryStructuralLimits: queryStructuralLimits
        )
    }

}

#endif
