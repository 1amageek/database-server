import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
@_spi(DatabaseExecution) import Database
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import DatabaseKit
import StorageKit
#if DATABASE_OPERATIONS_GRAPH_INDEXES && DATABASE_SERVER_MULTI_BASE
@_spi(DatabaseExecution) import GraphIndex
#endif

#if DATABASE_SERVER_MULTI_BASE
private typealias DatabaseQueryBooleanResponse = QueryBooleanResult
#else
private typealias DatabaseQueryBooleanResponse = Bool
#endif

private enum DatabaseSelectInitialPlan: Sendable {
    case page(QueryResponse, DatabaseTransactionReadPoint.Value)
    case historical(
        QueryResponse,
        QueryContinuation,
        UInt64,
        DatabaseTransactionReadPoint.Value
    )
    case captured(
        DatabaseSharedRetainedQueryRows,
        DatabaseTransactionReadPoint.Value
    )
}

public struct QueryExecuteHandler: DatabaseOperationHandler {
    public typealias Operation = QueryExecuteOperation

    private let runtimeLimits: DatabaseOperationLimits
    private let querySnapshotStore: DatabaseQuerySnapshotStore?

    public init(runtimeLimits: DatabaseOperationLimits = .default) {
        self.runtimeLimits = runtimeLimits
        self.querySnapshotStore = nil
    }

    package init(
        runtimeLimits: DatabaseOperationLimits,
        querySnapshotStore: DatabaseQuerySnapshotStore?
    ) {
        self.runtimeLimits = runtimeLimits
        self.querySnapshotStore = querySnapshotStore
    }

    public func handle(
        _ request: QueryExecuteOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> QueryExecuteOperation.Response {
        try runtimeLimits.validate(request.budget)
        guard request.page.limit > 0 else {
            throw DatabaseQueryExecutionError.pageLimitMustBePositive
        }
        return try await DatabaseExecutionTimeout.run(
            milliseconds: request.budget.timeoutMilliseconds,
            clock: context.executor.monotonicClock
        ) {
            let workMeter = DatabaseWorkMeter(
                budget: request.budget,
                monotonicClock: context.executor.monotonicClock
            )
            let admittedStatement = try DatabaseStatementAdmission(
                structuralLimits: runtimeLimits.queryStructuralLimits
            ).admit(
                request.input,
                parameters: request.parameters
            )
            return try await execute(
                admittedStatement.statement,
                request: request,
                context: context,
                workMeter: workMeter,
                structuralLimits: admittedStatement.structuralLimits
            )
        }
    }

    private func execute(
        _ statement: QueryStatement,
        request: QueryExecuteOperation.Request,
        context: DatabaseOperationContext,
        workMeter: DatabaseWorkMeter,
        structuralLimits: QueryStructuralLimits
    ) async throws -> QueryExecuteOperation.Response {
        #if DATABASE_SERVER_MULTI_BASE
        if case .composition = context.target {
            switch statement {
            case .select, .ask, .construct, .describe:
                break
            default:
                throw DatabaseQueryExecutionError.compositionPlanUnsupported(
                    "this query statement is not advertised for Composition targets"
                )
            }
        }
        #endif
        switch statement {
        case .select(let query):
            return .rows(
                try await executeSelect(
                    query,
                    request: request,
                    context: context,
                    workMeter: workMeter,
                    structuralLimits: structuralLimits
                )
            )
        case .ask(let query):
            #if DATABASE_OPERATIONS_GRAPH_INDEXES
            return .boolean(
                try await Self.executeAsk(
                    query,
                    request: request,
                    context: context,
                    workMeter: workMeter,
                    structuralLimits: structuralLimits
                )
            )
            #else
            _ = query
            throw DatabaseQueryExecutionError.featureUnavailable(
                "ASK requires the GraphIndexes package trait"
            )
            #endif
        case .construct(let query):
            #if DATABASE_OPERATIONS_GRAPH_INDEXES
            #if DATABASE_SERVER_MULTI_BASE
            if case .composition = context.target {
                return .rdfGraph(
                    try await executeCompositionRDFGraph(
                        .construct(query),
                        request: request,
                        context: context,
                        workMeter: workMeter,
                        structuralLimits: structuralLimits
                    )
                )
            }
            #endif
            return .rdfGraph(
                try await DatabaseGraphQueryService(
                    queryStructuralLimits: structuralLimits,
                    querySnapshotStore: querySnapshotStore
                ).executeConstruct(
                    query,
                    request: request,
                    context: context,
                    workMeter: workMeter
                )
            )
            #else
            _ = query
            throw DatabaseQueryExecutionError.featureUnavailable(
                "CONSTRUCT requires the GraphIndexes package trait"
            )
            #endif
        case .describe(let query):
            #if DATABASE_OPERATIONS_GRAPH_INDEXES
            #if DATABASE_SERVER_MULTI_BASE
            if case .composition = context.target {
                return .rdfGraph(
                    try await executeCompositionRDFGraph(
                        .describe(query),
                        request: request,
                        context: context,
                        workMeter: workMeter,
                        structuralLimits: structuralLimits
                    )
                )
            }
            #endif
            return .rdfGraph(
                try await DatabaseGraphQueryService(
                    queryStructuralLimits: structuralLimits,
                    querySnapshotStore: querySnapshotStore
                ).executeDescribe(
                    query,
                    request: request,
                    context: context,
                    workMeter: workMeter
                )
            )
            #else
            _ = query
            throw DatabaseQueryExecutionError.featureUnavailable(
                "DESCRIBE requires the GraphIndexes package trait"
            )
            #endif
        default:
            throw DatabaseQueryExecutionError.mutationRequiresMutationOperation
        }
    }

    private func executeSelect(
        _ query: SelectQuery,
        request: QueryExecuteOperation.Request,
        context: DatabaseOperationContext,
        workMeter: DatabaseWorkMeter,
        structuralLimits: QueryStructuralLimits
    ) async throws -> QueryRowPage {
        #if DATABASE_SERVER_MULTI_BASE
        if case .composition = context.target {
            let queryFingerprint = try DatabaseQuerySnapshotStore
                .queryFingerprint(
                    query: query,
                    request: request,
                    limits: context.wireLimits
            )
            if let continuation = request.page.continuation {
                guard let querySnapshotStore else {
                    throw DatabaseQueryExecutionError
                        .querySnapshotUnavailable(
                            "the host did not provide an opaque identifier generator"
                        )
                }
                let source = try context.requireCompositionExecutor()
                let readMetadata = try await source.acquireReadMetadata()
                let page = try await querySnapshotStore.load(
                    continuation: continuation,
                    composition: readMetadata.resolution,
                    basePlacementGenerations: readMetadata
                        .basePlacementGenerations,
                    schemaGeneration: context.executor.schemaGeneration,
                    queryFingerprint: queryFingerprint,
                    authorization: context.authorization
                )
                try workMeter.recordOutput(page)
                return page
            }
            let page = try await DatabaseCompositionQueryAdapter(
                structuralLimits: structuralLimits
            ).execute(
                query,
                request: request,
                context: context,
                workMeter: workMeter,
                queryFingerprint: queryFingerprint,
                snapshotStore: querySnapshotStore
            )
            return page
        }
        #endif
        let databaseContext = try context.requireDataContext()
        let lease = try databaseContext.executionStorage()
        if let continuation = request.page.continuation {
            guard continuation.count == DatabaseQuerySnapshotStore
                    .continuationByteCount,
                  continuation.first == DatabaseQuerySnapshotStore
                    .continuationMarker else {
                throw DatabaseQueryExecutionError.invalidContinuation
            }
            guard let querySnapshotStore else {
                throw DatabaseQueryExecutionError.invalidContinuation
            }
            let queryFingerprint = try Self.queryFingerprint(
                query,
                request: request,
                context: context
            )
            if let historical = try await querySnapshotStore
                .loadHistoricalQuery(
                    continuation: continuation,
                    lease: lease,
                    schemaGeneration: context.executor.schemaGeneration,
                    queryFingerprint: queryFingerprint,
                    authorization: context.authorization
                ) {
                let executed: (
                    response: QueryResponse,
                    readPoint: DatabaseTransactionReadPoint.Value
                )
                do {
                    executed = try await databaseContext.withReadSnapshot(
                        restoring: .version(historical.readVersion),
                        workMeter: workMeter
                    ) { snapshot in
                        guard snapshot.position
                            == .version(historical.readVersion) else {
                            throw DatabaseQueryExecutionError
                                .querySnapshotCorrupted
                        }
                        let prepared = try await databaseContext
                            .prepareSQLSelectForCanonicalExecution(
                                query,
                                workMeter: workMeter,
                                session: snapshot.session,
                                structuralLimits: structuralLimits
                            )
                        let response = try await prepared.execute(
                            in: snapshot.session,
                            execution: try Self.readExecution(
                                for: request,
                                continuation: historical.continuation,
                                workMeter: workMeter,
                                structuralLimits: structuralLimits,
                                monotonicClock: context.executor.monotonicClock,
                                continuationSnapshotIsStable: true
                            ),
                            graphPartitions: request.graphPartitions
                        )
                        return (
                            response,
                            DatabaseTransactionReadPoint.value(
                                domainID: lease.domainIdentifier,
                                snapshot: snapshot
                            )
                        )
                    }
                } catch {
                    throw Self.mapHistoricalReadFailure(error)
                }
                let next: ByteString?
                if let engineContinuation = executed.response.continuation {
                    next = try await querySnapshotStore.advanceHistoricalQuery(
                        historical,
                        to: engineContinuation
                    )
                } else {
                    next = nil
                }
                let page = try Self.rowPage(
                    executed.response,
                    continuation: next,
                    readPoint: executed.readPoint
                )
                try workMeter.recordOutput(page)
                if executed.response.continuation == nil {
                    try await querySnapshotStore.completeHistoricalQuery(
                        historical
                    )
                }
                return page
            }
            let page = try await querySnapshotStore.load(
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
            let preparedQuery = try await databaseContext
                .prepareSQLSelectForCanonicalExecution(
                    query,
                    workMeter: workMeter,
                    session: snapshot.session,
                    structuralLimits: structuralLimits
                )
            let readPoint = DatabaseTransactionReadPoint.value(
                domainID: lease.domainIdentifier,
                snapshot: snapshot
            )
            if snapshot.supportsPositionRestoration,
               case .version(let readVersion) = snapshot.position {
                let response = try await preparedQuery.execute(
                    in: snapshot.session,
                    execution: try Self.readExecution(
                        for: request,
                        continuation: nil,
                        workMeter: workMeter,
                        structuralLimits: structuralLimits,
                        monotonicClock: context.executor.monotonicClock,
                        continuationSnapshotIsStable: true
                    ),
                    graphPartitions: request.graphPartitions
                )
                guard let continuation = response.continuation else {
                    return DatabaseSelectInitialPlan.page(
                        response,
                        readPoint
                    )
                }
                if querySnapshotStore?.canPersistHistoricalContinuation(
                    continuation
                ) == true {
                    return DatabaseSelectInitialPlan.historical(
                        response,
                        continuation,
                        readVersion,
                        readPoint
                    )
                }
            }
            let stagedRows = try await preparedQuery.stageCompleteRows(
                in: snapshot.session,
                execution: ReadExecutionContext(
                    options: ReadExecutionOptions(budget: request.budget),
                    monotonicClock: context.executor.monotonicClock,
                    workMeter: workMeter,
                    queryStructuralLimits: structuralLimits
                ),
                graphPartitions: request.graphPartitions
            )
            return DatabaseSelectInitialPlan.captured(stagedRows, readPoint)
        }
        let page: QueryRowPage
        switch plan {
        case .page(let response, let readPoint):
            page = try Self.rowPage(
                response,
                continuation: nil,
                readPoint: readPoint
            )
            try workMeter.recordOutput(page)
        case .historical(
            let response,
            let continuation,
            let readVersion,
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
                queryFingerprint: try Self.queryFingerprint(
                    query,
                    request: request,
                    context: context
                ),
                authorization: context.authorization
            )
            do {
                let opaqueContinuation = try await querySnapshotStore
                    .publishHistoricalQuery(
                        continuation,
                        readVersion: readVersion,
                        in: reservation
                    )
                // The published continuation is the page's own identity, so the
                // response can only be built and accounted for after the
                // manifest exists. Both stay inside the guarded region: a
                // cancelled or refused claim here must release the snapshot
                // instead of leaving a manifest no caller can ever resume.
                let published = try Self.rowPage(
                    response,
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
        case .captured(let rows, let readPoint):
            page = try await executeDurableSnapshotSelect(
                rows: rows,
                readPoint: readPoint,
                query: query,
                request: request,
                context: context,
                lease: lease,
                workMeter: workMeter
            )
        }
        return page
    }

    /// Binds a durable continuation to the query that produced it.
    ///
    /// The fingerprint is derived only when a continuation is stored or
    /// resumed. A single-page result never reaches durable continuation
    /// storage, so it must not pay this encode or be rejected by a wire limit
    /// that the request never crossed.
    private static func queryFingerprint(
        _ query: SelectQuery,
        request: QueryExecuteOperation.Request,
        context: DatabaseOperationContext
    ) throws -> ByteString {
        try DatabaseQuerySnapshotStore.queryFingerprint(
            query: query,
            request: request,
            limits: context.wireLimits
        )
    }

    private func executeDurableSnapshotSelect(
        rows: DatabaseSharedRetainedQueryRows,
        readPoint: DatabaseTransactionReadPoint.Value,
        query: SelectQuery,
        request: QueryExecuteOperation.Request,
        context: DatabaseOperationContext,
        lease: DatabaseExecutionStorage,
        workMeter: DatabaseWorkMeter
    ) async throws -> QueryRowPage {
        guard let pageLimit = Int(exactly: request.page.limit) else {
            throw DatabaseQueryExecutionError.pageLimitExceedsPlatformCapacity(
                requested: request.page.limit
            )
        }
        let rowCount = rows.count
        let firstEnd = min(pageLimit, rowCount)
        guard firstEnd < rowCount else {
            let response = QueryResponse(
                rows: rows.materializePage(0..<firstEnd)
            )
            let page = try Self.rowPage(
                response,
                continuation: nil,
                readPoint: readPoint
            )
            try workMeter.recordOutput(page)
            return page
        }
        guard let querySnapshotStore else {
            throw DatabaseQueryExecutionError.querySnapshotUnavailable(
                "the host did not provide durable query snapshot storage"
            )
        }
        let reservation = try await querySnapshotStore.beginWrite(
            for: lease,
            schemaGeneration: context.executor.schemaGeneration,
            queryFingerprint: try Self.queryFingerprint(
                query,
                request: request,
                context: context
            ),
            authorization: context.authorization
        )
        do {
            let firstContinuationPageID = try await querySnapshotStore
                .reservePage(in: reservation)
            var currentPageID = firstContinuationPageID
            var continuationPageCount: UInt32 = 0
            var totalPayloadBytes: UInt64 = 0
            var offset = firstEnd

            while offset < rowCount {
                let end = min(offset + pageLimit, rowCount)
                let nextPageID = end < rowCount
                    ? try await querySnapshotStore.reservePage(in: reservation)
                    : nil
                let page = try Self.rowPage(
                    QueryResponse(
                        rows: rows.materializePage(offset..<end)
                    ),
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
                let incremented = continuationPageCount
                    .addingReportingOverflow(1)
                guard !incremented.overflow else {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                continuationPageCount = incremented.partialValue
                offset = end
                if let nextPageID { currentPageID = nextPageID }
            }

            try await querySnapshotStore.commitWrite(
                reservation,
                pageCount: continuationPageCount,
                totalPayloadBytes: totalPayloadBytes
            )
            let firstResponse = QueryResponse(
                rows: rows.materializePage(0..<firstEnd)
            )
            let firstPage = try Self.rowPage(
                firstResponse,
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

    private static func readExecution(
        for request: QueryExecuteOperation.Request,
        continuation: QueryContinuation?,
        workMeter: DatabaseWorkMeter,
        structuralLimits: QueryStructuralLimits,
        monotonicClock: any StorageMonotonicClock,
        continuationSnapshotIsStable: Bool
    ) throws -> ReadExecutionContext {
        guard let pageSize = Int(exactly: request.page.limit) else {
            throw DatabaseQueryExecutionError.pageLimitExceedsPlatformCapacity(
                requested: request.page.limit
            )
        }
        let continuationScope = try DatabaseWireWriter.encode {
            (writer: inout DatabaseWireWriter) throws(DatabaseWireError) in
            try request.graphPartitions.encode(into: &writer)
        }
        return ReadExecutionContext(
            options: ReadExecutionOptions(
                pageSize: pageSize,
                continuation: continuation,
                budget: request.budget,
                continuationScope: continuationScope,
                continuationSnapshotIsStable:
                    continuationSnapshotIsStable
            ),
            monotonicClock: monotonicClock,
            workMeter: workMeter,
            queryStructuralLimits: structuralLimits
        )
    }

    private static func mapHistoricalReadFailure(
        _ error: any Error
    ) -> any Error {
        if let error = error as? DatabaseQueryExecutionError {
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

    #if DATABASE_OPERATIONS_GRAPH_INDEXES && DATABASE_SERVER_MULTI_BASE
    private func executeCompositionRDFGraph(
        _ statement: DatabaseCompositionRDFQueryAdapter.Statement,
        request: QueryExecuteOperation.Request,
        context: DatabaseOperationContext,
        workMeter: DatabaseWorkMeter,
        structuralLimits: QueryStructuralLimits
    ) async throws -> RDFGraphPage {
        guard let querySnapshotStore else {
            throw DatabaseQueryExecutionError.querySnapshotUnavailable(
                "the host did not provide durable Composition snapshot storage"
            )
        }
        let queryFingerprint = try DatabaseQuerySnapshotStore
            .queryFingerprint(
                statement: statement.queryStatement,
                request: request,
                limits: context.wireLimits
            )
        if let continuation = request.page.continuation {
            let source = try context.requireCompositionExecutor()
            let readMetadata = try await source.acquireReadMetadata()
            let page = try await querySnapshotStore.loadRDFGraph(
                continuation: continuation,
                composition: readMetadata.resolution,
                basePlacementGenerations: readMetadata.basePlacementGenerations,
                schemaGeneration: context.executor.schemaGeneration,
                queryFingerprint: queryFingerprint,
                authorization: context.authorization
            )
            try workMeter.recordOutput(page)
            return page
        }
        let page = try await DatabaseCompositionRDFQueryAdapter(
            structuralLimits: structuralLimits
        ).execute(
            statement,
            request: request,
            context: context,
            workMeter: workMeter,
            queryFingerprint: queryFingerprint,
            snapshotStore: querySnapshotStore
        )
        return page
    }

    #endif

    #if DATABASE_OPERATIONS_GRAPH_INDEXES
    private static func executeAsk(
        _ query: AskQuery,
        request: QueryExecuteOperation.Request,
        context: DatabaseOperationContext,
        workMeter: DatabaseWorkMeter,
        structuralLimits: QueryStructuralLimits
    ) async throws -> DatabaseQueryBooleanResponse {
        guard request.page.continuation == nil else {
            throw DatabaseQueryExecutionError.continuationNotSupported("ASK")
        }
        #if DATABASE_SERVER_MULTI_BASE
        if case .composition = context.target {
            let source = try context.requireCompositionExecutor()
            let result: CompositionAskResult
            do {
                result = try await CompositionRDFQueryPlanner().executeAsk(
                    query,
                    source: source.dataSource,
                    graphPartitions: request.graphPartitions,
                    readContext: ReadExecutionContext(
                        options: ReadExecutionOptions(budget: request.budget),
                        monotonicClock: context.executor.monotonicClock,
                        workMeter: workMeter,
                        queryStructuralLimits: structuralLimits
                    )
                )
            } catch let error as CompositionQueryError {
                throw mapCompositionError(error)
            }
            try workMeter.recordOutputRows(1)
            return try QueryBooleanResult(
                value: result.value,
                provenance: CompositionPageProvenance(
                    composition: result.metadata.composition,
                    origins: [result.origin]
                ),
                consistency: result.metadata.consistency
            )
        }
        #endif
        let databaseContext = try context.requireDataContext()
        let lease = try databaseContext.executionStorage()
        let response = try await databaseContext.withReadSnapshot(
            workMeter: workMeter
        ) {
            snapshot in
            let value = try await snapshot.session.executeSPARQLAsk(
                query,
                options: ReadExecutionContext(
                    options: ReadExecutionOptions(budget: request.budget),
                    monotonicClock: context.executor.monotonicClock,
                    workMeter: workMeter,
                    queryStructuralLimits: structuralLimits
                ),
                partitions: request.graphPartitions
            )
            let readPoint = DatabaseTransactionReadPoint.value(
                domainID: lease.domainIdentifier,
                snapshot: snapshot
            )
            #if DATABASE_SERVER_MULTI_BASE
            return try QueryBooleanResult(
                value: value,
                provenance: nil,
                consistency: .transactional(try readPoint.domainReadPoint)
            )
            #else
            _ = readPoint
            return value
            #endif
        }
        try workMeter.recordOutputRows(1)
        return response
    }

    #if DATABASE_SERVER_MULTI_BASE
    private static func mapCompositionError(
        _ error: CompositionQueryError
    ) -> DatabaseQueryExecutionError {
        switch error {
        case .unsupportedPlan(let reason):
            return .compositionPlanUnsupported(reason)
        case .aggregateFailure(let reason):
            return .compositionAggregateFailure(reason)
        case .invalidExecutionConfiguration(let reason):
            return .compositionPlanUnsupported(reason)
        case .workspaceCorrupted:
            return .querySnapshotCorrupted
        }
    }
    #endif

    #endif

    private static func rowPage(
        _ response: QueryResponse,
        continuation: ByteString?,
        readPoint: DatabaseTransactionReadPoint.Value
    ) throws -> QueryRowPage {
        let columnNames = Set(
            response.rows.flatMap { $0.fields.keys }
        ).sorted()
        let columns = try columnNames.enumerated().map {
            offset,
            name -> QueryColumn in
            guard let number = UInt32(exactly: offset + 1) else {
                throw DatabaseWireError.byteCountOverflow
            }
            return QueryColumn(number: number, name: name)
        }
        #if DATABASE_SERVER_MULTI_BASE
        return try QueryRowPage(
            columns: columns,
            rows: try response.rows.map {
                try DatabaseQueryRowEncoder.encode(
                    $0,
                    columnNames: columnNames
                )
            },
            continuation: continuation,
            provenance: nil,
            consistency: .transactional(try readPoint.domainReadPoint)
        )
        #else
        return try QueryRowPage(
            columns: columns,
            rows: try response.rows.map {
                try DatabaseQueryRowEncoder.encode(
                    $0,
                    columnNames: columnNames
                )
            },
            continuation: continuation,
            snapshotVersion: readPoint.restorableVersion
        )
        #endif
    }

}
