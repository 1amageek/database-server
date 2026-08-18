import DatabaseQueryOperations
#if DATABASE_SERVER_MULTIPLE_BASES
@_spi(DatabaseExecution) import DatabaseEngine
#if DATABASE_OPERATIONS_GRAPH_INDEXES
@_spi(DatabaseExecution) import GraphIndex
#endif
import DatabaseKit
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import StorageKit

/// Adapts the framework-owned Composition planner to DatabaseWire paging.
struct DatabaseCompositionQueryAdapter {
    private actor ResultAdapter {
        private let pageLimit: Int
        private let queryFingerprint: ByteString
        private let authorization: AuthorizationContext
        private let maximumIntermediateBytes: UInt64
        private let snapshotStore: DatabaseQuerySnapshotStore?
        private let workMeter: DatabaseWorkMeter
        private var builder: DatabaseCompositionQueryResultBuilder?

        init(
            pageLimit: Int,
            queryFingerprint: ByteString,
            authorization: AuthorizationContext,
            maximumIntermediateBytes: UInt64,
            snapshotStore: DatabaseQuerySnapshotStore?,
            workMeter: DatabaseWorkMeter
        ) {
            self.pageLimit = pageLimit
            self.queryFingerprint = queryFingerprint
            self.authorization = authorization
            self.maximumIntermediateBytes = maximumIntermediateBytes
            self.snapshotStore = snapshotStore
            self.workMeter = workMeter
        }

        func receive(_ event: CompositionQueryEvent) async throws {
            switch event {
            case .began(let metadata):
                guard builder == nil else {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                builder = DatabaseCompositionQueryResultBuilder(
                    composition: metadata.composition,
                    basePlacementGenerations: metadata
                        .basePlacementGenerations,
                    schemaGeneration: metadata.schemaGeneration,
                    consistency: metadata.consistency,
                    pageLimit: pageLimit,
                    queryFingerprint: queryFingerprint,
                    authorization: authorization,
                    maximumIntermediateBytes: maximumIntermediateBytes,
                    snapshotStore: snapshotStore,
                    workMeter: workMeter
                )
            case .row(let result):
                guard let builder else {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                try await builder.append(
                    result.row,
                    origin: result.origin,
                    footprint: try DatabaseCompositionQueryAdapter
                        .rowFootprint(result.row)
                )
            }
        }

        func finish() async throws -> QueryRowPage {
            guard let builder else {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            return try await builder.finish()
        }

        func abort() async throws {
            try await builder?.abort()
        }
    }

    private let structuralLimits: QueryStructuralLimits

    init(structuralLimits: QueryStructuralLimits) {
        self.structuralLimits = structuralLimits
    }

    func execute(
        _ query: SelectQuery,
        request: QueryExecuteOperation.Request,
        context: DatabaseOperationContext,
        workMeter: DatabaseWorkMeter,
        queryFingerprint: ByteString,
        snapshotStore: DatabaseQuerySnapshotStore?
    ) async throws -> QueryRowPage {
        guard request.page.continuation == nil else {
            throw DatabaseQueryExecutionError.invalidContinuation
        }
        guard request.page.limit > 0 else {
            throw DatabaseQueryExecutionError.pageLimitMustBePositive
        }
        let boundedPageLimit = min(
            request.page.limit,
            request.budget.maximumRows
        )
        guard let pageLimit = Int(exactly: boundedPageLimit),
              pageLimit > 0 else {
            throw DatabaseQueryExecutionError.pageLimitMustBePositive
        }
        let source = try context.requireCompositionExecutor().dataSource
        let execution = ReadExecutionContext(
            options: ReadExecutionOptions(
                budget: request.budget,
                continuationSnapshotIsStable: true
            ),
            monotonicClock: context.executor.monotonicClock,
            workMeter: workMeter,
            queryStructuralLimits: structuralLimits
        )
        let adapter = ResultAdapter(
            pageLimit: pageLimit,
            queryFingerprint: queryFingerprint,
            authorization: context.authorization,
            maximumIntermediateBytes: request.budget.maximumIntermediateBytes,
            snapshotStore: snapshotStore,
            workMeter: workMeter
        )
        do {
            if Self.isSPARQLSource(query.source) {
                #if DATABASE_OPERATIONS_GRAPH_INDEXES
                try await CompositionSPARQLQueryPlanner(
                    structuralLimits: structuralLimits
                ).execute(
                    query,
                    source: source,
                    graphPartitions: request.graphPartitions,
                    pageSize: pageLimit,
                    readContext: execution
                ) { event in
                    try await adapter.receive(event)
                    return true
                }
                #else
                throw DatabaseQueryExecutionError.featureUnavailable(
                    "SPARQL SELECT requires the GraphIndexes package trait"
                )
                #endif
            } else {
                guard request.graphPartitions.isEmpty else {
                    throw DatabaseQueryExecutionError
                        .compositionPlanUnsupported(
                            "graph partitions require a SPARQL source"
                        )
                }
                try await CompositionQueryPlanner(
                    structuralLimits: structuralLimits
                ).execute(
                    query,
                    source: source,
                    options: CompositionQueryExecutionOptions(
                        pageSize: pageLimit,
                        readContext: execution
                    )
                ) { event in
                    try await adapter.receive(event)
                    return true
                }
            }
            return try await adapter.finish()
        } catch {
            let operationError: any Error
            if let compositionError = error as? CompositionQueryError {
                operationError = Self.map(compositionError)
            } else {
                operationError = error
            }
            do {
                try await adapter.abort()
            } catch {
                throw StorageTransactionCleanupError(
                    operationError: operationError,
                    cancellationError: error
                )
            }
            throw operationError
        }
    }

    private static func map(
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

    private static func isSPARQLSource(_ source: DataSource) -> Bool {
        switch source {
        case .graphPattern, .namedGraph, .service:
            return true
        default:
            return false
        }
    }

    private static func rowFootprint(
        _ row: DatabaseEngine.QueryRow
    ) throws -> UInt64 {
        var bytes: UInt64 = 128
        for (key, value) in row.fields.sorted(by: { $0.key < $1.key }) {
            bytes = try adding(bytes, UInt64(key.utf8.count))
            bytes = try adding(
                bytes,
                UInt64(try FieldValueTupleCodec.encodedByteCount(for: value))
            )
        }
        for (key, value) in row.annotations.sorted(by: { $0.key < $1.key }) {
            bytes = try adding(bytes, UInt64(key.utf8.count))
            bytes = try adding(
                bytes,
                UInt64(try FieldValueTupleCodec.encodedByteCount(for: value))
            )
        }
        if let version = row.version {
            bytes = try adding(bytes, UInt64(version.value.utf8.count))
        }
        return bytes
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw DatabaseIntermediateFootprintError.byteAdditionOverflow(
                left: lhs,
                right: rhs
            )
        }
        return result.partialValue
    }
}

#endif
