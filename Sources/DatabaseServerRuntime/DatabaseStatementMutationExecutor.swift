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

public protocol DatabaseStatementMutationExecutor: Sendable {
    associatedtype PreparedStatementMutation: Sendable

    func prepare(
        _ statement: ValidatedDatabaseStatement,
        budget: ExecutionBudget,
        context: DatabaseOperationContext
    ) async throws -> PreparedStatementMutation

    func execute(
        _ prepared: PreparedStatementMutation,
        preconditions: [EntityMutationPrecondition],
        graphPartitions: FieldObject,
        context: DatabaseOperationContext,
        transaction: DatabaseTransaction
    ) async throws -> MutationExecuteOperation.Result
}
