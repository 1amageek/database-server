#if DATABASE_OPERATIONS_GRAPH_INDEXES
import DatabaseKit
@_spi(DatabaseExecution) import GraphIndex

@_spi(DatabaseExecution)
extension DatabaseOperationContext: SPARQLUpdateExecutionContext {
    public var idempotencyKey: String? {
        metadata.idempotencyKey
    }

    public func makeSPARQLQueryExecutor(
        datasetScanner: any RDFDatasetScanner,
        readMode: RDFDatasetReadMode,
        dataset: SPARQLExecutionDataset,
        functionRegistry: SPARQLFunctionRegistry
    ) throws -> SPARQLQueryExecutor {
        try requireDataExecutor().makeSPARQLQueryExecutor(
            datasetScanner: datasetScanner,
            readMode: readMode,
            dataset: dataset,
            functionRegistry: functionRegistry
        )
    }
}
#endif
