import DatabaseOperationCore
import DatabaseKit
@_spi(DatabaseExecution) import Database
@_spi(DatabaseExecution) import DatabaseEngine
@_spi(DatabaseExecution) import DatabaseWire
import StorageKit

/// Adapts one complete SQL request without taking ownership of data execution.
public struct SQLExecuteHandler: DatabaseOperationEndpointHandler {
    public typealias Operation = SQLExecuteOperation

    private let runtimeLimits: DatabaseOperationLimits
    private let checkpointLimits: TransactionCheckpointLimits?

    public init(
        runtimeLimits: DatabaseOperationLimits = .default,
        checkpointLimits: TransactionCheckpointLimits? = nil
    ) {
        self.runtimeLimits = runtimeLimits
        self.checkpointLimits = checkpointLimits
    }

    public func invoke(
        request: SQLExecuteOperation.Request,
        context: DatabaseOperationContext,
        limits: DatabaseWireLimits
    ) async throws -> DatabaseOperationResult {
        try runtimeLimits.validate(request.budget)
        let options = SQLBlockExecutionOptions(
            checkpointLimits: try SQLCheckpointPolicy.limits(
                for: request.budget,
                structuralLimits: runtimeLimits.queryStructuralLimits,
                ceiling: checkpointLimits
            ),
            budget: request.budget,
            structuralLimits: runtimeLimits.queryStructuralLimits,
            configuration: TransactionConfiguration(
                maximumMutationAggregateBytes: runtimeLimits.maximumMutationAggregateBytes
            )
        )
        let dataContext = try context.requireDataContext()
        let encoder = SQLResponseEncoder(requestID: context.requestID, limits: limits)
        do {
            let response: SQLEncodedResponse
            switch request.input {
            case .text(let sql):
                response = try await dataContext.executeEncodedSQLBlock(
                    sql, parameters: request.parameters, options: options, encoder: encoder)
            case .statement(let statement):
                response = try await dataContext.executeEncodedStatement(
                    statement, parameters: request.parameters, options: options, encoder: encoder)
            case .block(let block):
                response = try await dataContext.executeEncodedSQLBlock(
                    block, parameters: request.parameters, options: options, encoder: encoder)
            }
            return DatabaseOperationResult(requestID: context.requestID, sqlFrame: response)
        } catch let failure as SQLExecutionFailure where failure.underlyingError is CancellationError {
            throw CancellationError()
        }
    }
}
