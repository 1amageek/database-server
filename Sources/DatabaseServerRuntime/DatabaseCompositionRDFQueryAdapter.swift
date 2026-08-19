import DatabaseQueryOperations
#if DATABASE_SERVER_MULTI_BASE
#if DATABASE_OPERATIONS_GRAPH_INDEXES
@_spi(DatabaseExecution) import DatabaseEngine
@_spi(DatabaseExecution) import GraphIndex
import DatabaseKit
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import StorageKit

/// Adapts GraphIndex-owned Composition RDF execution to DatabaseWire paging.
package struct DatabaseCompositionRDFQueryAdapter: Sendable {
    package enum Statement: Sendable {
        case construct(ConstructQuery)
        case describe(DescribeQuery)

        var queryStatement: QueryStatement {
            switch self {
            case .construct(let query): .construct(query)
            case .describe(let query): .describe(query)
            }
        }

        var semanticStatement: CompositionRDFStatement {
            switch self {
            case .construct(let query): .construct(query)
            case .describe(let query): .describe(query)
            }
        }
    }

    private actor ResultAdapter {
        private let pageLimit: Int
        private let maximumIntermediateBytes: UInt64
        private let queryFingerprint: ByteString
        private let authorization: AuthorizationContext
        private let snapshotStore: DatabaseQuerySnapshotStore
        private let workMeter: DatabaseWorkMeter
        private var builder: DatabaseCompositionRDFResultBuilder?

        init(
            pageLimit: Int,
            maximumIntermediateBytes: UInt64,
            queryFingerprint: ByteString,
            authorization: AuthorizationContext,
            snapshotStore: DatabaseQuerySnapshotStore,
            workMeter: DatabaseWorkMeter
        ) {
            self.pageLimit = pageLimit
            self.maximumIntermediateBytes = maximumIntermediateBytes
            self.queryFingerprint = queryFingerprint
            self.authorization = authorization
            self.snapshotStore = snapshotStore
            self.workMeter = workMeter
        }

        func receive(_ event: CompositionRDFQueryEvent) async throws {
            switch event {
            case .began(let metadata):
                guard builder == nil else {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                builder = try DatabaseCompositionRDFResultBuilder(
                    composition: metadata.composition,
                    basePlacementGenerations: metadata
                        .basePlacementGenerations,
                    consistency: metadata.consistency,
                    schemaGeneration: metadata.schemaGeneration,
                    pageLimit: pageLimit,
                    maximumIntermediateBytes: maximumIntermediateBytes,
                    queryFingerprint: queryFingerprint,
                    authorization: authorization,
                    snapshotStore: snapshotStore,
                    workMeter: workMeter
                )
            case .quad(let result):
                guard let builder else {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                try await builder.append(result.quad, origin: result.origin)
            }
        }

        func finish() async throws -> RDFGraphPage {
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

    package init(structuralLimits: QueryStructuralLimits) {
        self.structuralLimits = structuralLimits
    }

    package func execute(
        _ statement: Statement,
        request: QueryExecuteOperation.Request,
        context: DatabaseOperationContext,
        workMeter: DatabaseWorkMeter,
        queryFingerprint: ByteString,
        snapshotStore: DatabaseQuerySnapshotStore
    ) async throws -> RDFGraphPage {
        guard request.page.limit <= request.budget.maximumRows,
              let pageLimit = Int(exactly: request.page.limit),
              pageLimit > 0 else {
            throw DatabaseGraphQueryError.pageLimitExceedsMaximum(
                requested: request.page.limit,
                maximum: request.budget.maximumRows
            )
        }
        let source = try context.requireCompositionExecutor().dataSource
        let adapter = ResultAdapter(
            pageLimit: pageLimit,
            maximumIntermediateBytes: request.budget.maximumIntermediateBytes,
            queryFingerprint: queryFingerprint,
            authorization: context.authorization,
            snapshotStore: snapshotStore,
            workMeter: workMeter
        )
        let readContext = ReadExecutionContext(
            options: ReadExecutionOptions(budget: request.budget),
            monotonicClock: context.executor.monotonicClock,
            workMeter: workMeter,
            queryStructuralLimits: structuralLimits
        )
        do {
            try await CompositionRDFQueryPlanner().execute(
                statement.semanticStatement,
                source: source,
                graphPartitions: request.graphPartitions,
                nodeNamespace: try GraphResultNodeNamespace(queryFingerprint),
                readContext: readContext
            ) { event in
                try await adapter.receive(event)
                return true
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
}
#endif

#endif
