import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
import DatabaseKit
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
#if DATABASE_OPERATIONS_GRAPH_INDEXES
@_spi(DatabaseExecution) import GraphIndex
#endif
import StorageKit

public struct CanonicalDatabaseStatementMutationExecutor:
    DatabaseStatementMutationExecutor {
    private let runtimeLimits: DatabaseOperationLimits
    #if DATABASE_OPERATIONS_GRAPH_INDEXES
    private let graphStoreOverride: (any RDFGraphMutationStore)?
    private let loadSource: AnySPARQLLoadSource
    private let functionRegistry: SPARQLFunctionRegistry
    private let graphOperationLimits: GraphOperationLimits
    #endif

    public init(runtimeLimits: DatabaseOperationLimits = .default) {
        self.runtimeLimits = runtimeLimits
        #if DATABASE_OPERATIONS_GRAPH_INDEXES
        self.graphStoreOverride = nil
        self.loadSource = .unconfigured
        self.functionRegistry = .empty
        self.graphOperationLimits = .default
        #endif
    }

    #if DATABASE_OPERATIONS_GRAPH_INDEXES
    public init(
        runtimeLimits: DatabaseOperationLimits = .default,
        loadSource: AnySPARQLLoadSource,
        functionRegistry: SPARQLFunctionRegistry = .empty,
        graphOperationLimits: GraphOperationLimits = .default
    ) {
        self.runtimeLimits = runtimeLimits
        self.graphStoreOverride = nil
        self.loadSource = loadSource
        self.functionRegistry = functionRegistry
        self.graphOperationLimits = graphOperationLimits
    }

    public init(
        runtimeLimits: DatabaseOperationLimits = .default,
        graphStore: any RDFGraphMutationStore,
        loadSource: AnySPARQLLoadSource = .unconfigured,
        functionRegistry: SPARQLFunctionRegistry = .empty,
        graphOperationLimits: GraphOperationLimits = .default
    ) {
        self.runtimeLimits = runtimeLimits
        self.graphStoreOverride = graphStore
        self.loadSource = loadSource
        self.functionRegistry = functionRegistry
        self.graphOperationLimits = graphOperationLimits
    }
    #endif

    public func prepare(
        _ validatedStatement: ValidatedDatabaseStatement,
        budget: ExecutionBudget = ExecutionBudget(),
        context: DatabaseOperationContext
    ) async throws -> CanonicalPreparedStatementMutation {
        let statement = validatedStatement.statement
        let workMeter = DatabaseWorkMeter(
            budget: budget,
            monotonicClock: context.executor.monotonicClock
        )
        guard case .sparqlUpdate(let request) = statement else {
            return CanonicalPreparedStatementMutation(
                payload: .statement(statement),
                workMeter: workMeter,
                structuralLimits: validatedStatement.structuralLimits
            )
        }
        #if DATABASE_OPERATIONS_GRAPH_INDEXES
        return CanonicalPreparedStatementMutation(
            payload: .sparql(
                try await prepareSPARQLUpdate(
                    request,
                    context: context,
                    workMeter: workMeter
                )
            ),
            workMeter: workMeter,
            structuralLimits: validatedStatement.structuralLimits
        )
        #else
        _ = request
        throw DatabaseMutationError.featureUnavailable(
            "SPARQL updates require the GraphIndexes package trait"
        )
        #endif
    }

    public func execute(
        _ prepared: CanonicalPreparedStatementMutation,
        preconditions: [EntityMutationPrecondition] = [],
        graphPartitions: FieldObject = FieldObject(),
        context: DatabaseOperationContext,
        transaction: DatabaseTransaction
    ) async throws -> MutationExecuteOperation.Result {
        let dataExecutor = try context.requireDataExecutor()
        switch prepared.payload {
        #if DATABASE_OPERATIONS_GRAPH_INDEXES
        case .sparql(let request):
            try requireNoRDFGraphPartitions(graphPartitions)
            return .rdf(
                try await SPARQLUpdateExecutor(
                    graphStore: try graphStore(for: context),
                    runtimeLimits: try SPARQLUpdateLimits(
                        maximumMutations: runtimeLimits.maximumMutations
                    ),
                    structuralLimits: prepared.structuralLimits,
                    functionRegistry: functionRegistry
                ).execute(
                    request,
                    preconditions: preconditions,
                    context: context,
                    transaction: transaction,
                    entities: try dataExecutor.makeEntityMutationExecutor(
                        runtimeLimits: runtimeLimits
                    ),
                    workMeter: prepared.workMeter
                )
            )
        #endif
        case .statement(let statement):
            try requireNoGraphPartitions(graphPartitions)
            return .entities(
                try await dataExecutor.makeEntityStatementMutationExecutor(
                    runtimeLimits: runtimeLimits
                ).execute(
                    statement,
                    preconditions: preconditions,
                    transaction: transaction,
                    workMeter: prepared.workMeter
                )
            )
        }
    }

    #if DATABASE_OPERATIONS_GRAPH_INDEXES
    private func graphStore(
        for context: DatabaseOperationContext
    ) throws -> any RDFGraphMutationStore {
        if let graphStoreOverride {
            return graphStoreOverride
        }
        return CanonicalRDFGraphStore(
            rootSubspace: CanonicalRDFGraphStore.rootSubspace(
                forBaseRoot: try context.requireDataContext()
                    .executionStorage().root
            )
        )
    }

    private func prepareSPARQLUpdate(
        _ request: SPARQLUpdateRequest,
        context: DatabaseOperationContext,
        workMeter: DatabaseWorkMeter
    ) async throws -> PreparedSPARQLUpdateRequest {
        let first = try await prepareSPARQLOperation(
            request.firstOperation,
            ordinal: 0,
            context: context,
            workMeter: workMeter
        )
        var additional: [PreparedSPARQLUpdateOperation] = []
        additional.reserveCapacity(request.additionalOperations.count)
        for (index, operation) in request.additionalOperations.enumerated() {
            additional.append(
                try await prepareSPARQLOperation(
                    operation,
                    ordinal: UInt64(index + 1),
                    context: context,
                    workMeter: workMeter
                )
            )
        }
        return PreparedSPARQLUpdateRequest(
            firstOperation: first,
            additionalOperations: consume additional
        )
    }

    private func prepareSPARQLOperation(
        _ operation: SPARQLUpdateOperation,
        ordinal: UInt64,
        context: DatabaseOperationContext,
        workMeter: DatabaseWorkMeter
    ) async throws -> PreparedSPARQLUpdateOperation {
        switch operation {
        case .insertData(let query):
            return .insertData(query)
        case .deleteData(let query):
            return .deleteData(query)
        case .modify(let query):
            return .modify(query)
        case .deleteWhere(let query):
            return .deleteWhere(query)
        case .load(let query):
            return try await prepareLoad(
                query,
                operationOrdinal: ordinal,
                context: context,
                workMeter: workMeter
            )
        case .clear(let query):
            return .clear(query)
        case .createGraph(let query):
            return .createGraph(query)
        case .drop(let query):
            return .drop(query)
        case .graphTransfer(let query):
            return .graphTransfer(query)
        }
    }

    private func prepareLoad(
        _ query: LoadQuery,
        operationOrdinal: UInt64,
        context: DatabaseOperationContext,
        workMeter: DatabaseWorkMeter
    ) async throws -> PreparedSPARQLUpdateOperation {
        guard let idempotencyKey = context.metadata.idempotencyKey,
              !idempotencyKey.isEmpty else {
            throw SPARQLUpdateError.idempotencyKeyRequired
        }
        do {
            let document = try await loadSource.load(
                SPARQLLoadRequest(
                    sourceIRI: query.source,
                    maximumDocumentBytes:
                        graphOperationLimits.maximumLoadDocumentBytes,
                    maximumTriples: runtimeLimits.maximumMutations,
                    workMeter: workMeter
                )
            )
            guard document.byteCount
                    <= UInt64(
                        graphOperationLimits.maximumLoadDocumentBytes
                    ) else {
                throw SPARQLLoadSourceError.documentTooLarge(
                    actual: document.byteCount,
                    maximum: graphOperationLimits.maximumLoadDocumentBytes
                )
            }
            guard document.tripleCount <= runtimeLimits.maximumMutations else {
                throw SPARQLLoadSourceError.tripleLimitExceeded(
                    actual: document.tripleCount,
                    maximum: runtimeLimits.maximumMutations
                )
            }

            var triples = document.takeTriples()
            let blankNodeResolver = SPARQLUpdateBlankNodeResolver(
                idempotencyKey: idempotencyKey,
                operationOrdinal: operationOrdinal,
                solutionOrdinal: 0
            )
            for index in triples.indices {
                try workMeter.consume(at: .validation)
                let triple = triples[index]
                let scoped = RDFTriple(
                    subject: try resolveBlankNodes(
                        triple.subject,
                        blankNodeResolver: blankNodeResolver
                    ),
                    predicate: triple.predicate,
                    object: try resolveBlankNodes(
                        triple.object,
                        blankNodeResolver: blankNodeResolver
                    )
                )
                do {
                    try scoped.quad.validate()
                } catch {
                    throw SPARQLLoadSourceError.invalidDocument(
                        "Loaded RDF document is invalid"
                    )
                }
                triples[index] = scoped
            }
            return .load(
                PreparedSPARQLLoad(
                    destination: query.destination,
                    triples: consume triples
                )
            )
        } catch let error as SPARQLLoadSourceError {
            if query.silent, error.isSilentSuppressible {
                return .silentLoadNoOp
            }
            throw error
        }
    }

    private func resolveBlankNodes(
        _ subject: RDFSubject,
        blankNodeResolver: SPARQLUpdateBlankNodeResolver
    ) throws -> RDFSubject {
        switch subject {
        case .blankNode(let identifier):
            return .blankNode(
                try RDFBlankNodeIdentifier(
                    blankNodeResolver.identifier(for: identifier.rawValue)
                )
            )
        case .iri:
            return subject
        }
    }

    private func resolveBlankNodes(
        _ term: RDFTerm,
        blankNodeResolver: SPARQLUpdateBlankNodeResolver
    ) throws -> RDFTerm {
        switch term {
        case .blankNode(let identifier):
            return .blankNode(
                try RDFBlankNodeIdentifier(
                    blankNodeResolver.identifier(for: identifier.rawValue)
                )
            )
        case .tripleTerm(let subject, let predicate, let object):
            return .tripleTerm(
                subject: try resolveBlankNodes(
                    subject,
                    blankNodeResolver: blankNodeResolver
                ),
                predicate: predicate,
                object: try resolveBlankNodes(
                    object,
                    blankNodeResolver: blankNodeResolver
                )
            )
        case .iri, .literal:
            return term
        }
    }
    #endif

    private func requireNoGraphPartitions(
        _ graphPartitions: FieldObject
    ) throws {
        guard graphPartitions.isEmpty else {
            throw DatabaseMutationError.invalidGraphPartitions(
                "SQL statements do not consume graph partitions"
            )
        }
    }

    #if DATABASE_OPERATIONS_GRAPH_INDEXES
    private func requireNoRDFGraphPartitions(
        _ graphPartitions: FieldObject
    ) throws {
        guard graphPartitions.isEmpty else {
            throw DatabaseMutationError.invalidGraphPartitions(
                "authoritative RDF graph mutations do not consume entity partitions"
            )
        }
    }
    #endif
}

#if DATABASE_OPERATIONS_GRAPH_INDEXES
extension CanonicalDatabaseStatementMutationExecutor:
    GraphStatementMutationExecutor {}
#endif
