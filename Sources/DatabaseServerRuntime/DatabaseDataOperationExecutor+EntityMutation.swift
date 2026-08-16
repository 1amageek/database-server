import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseOperationCore
@_spi(DatabaseExecution) import DatabaseEngine

package extension DatabaseDataOperationExecutor {
    func makeEntityMutationExecutor(
        runtimeLimits: DatabaseOperationLimits
    ) throws -> DatabaseEntityMutationExecutor {
        DatabaseEntityMutationExecutor(
            container: container,
            limits: try DatabaseEntityMutationLimits(
                maximumChanges: runtimeLimits.maximumMutations,
                maximumPreconditions: runtimeLimits.maximumPreconditions
            )
        )
    }

    func makeEntityStatementMutationExecutor(
        runtimeLimits: DatabaseOperationLimits
    ) throws -> DatabaseEntityStatementMutationExecutor {
        DatabaseEntityStatementMutationExecutor(
            container: container,
            limits: try DatabaseEntityMutationLimits(
                maximumChanges: runtimeLimits.maximumMutations,
                maximumPreconditions: runtimeLimits.maximumPreconditions
            )
        )
    }
}
