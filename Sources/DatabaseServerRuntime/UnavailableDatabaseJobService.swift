import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
@_spi(DatabaseExecution) import DatabaseWire

/// Explicitly unadvertised job service used when the host cannot revalidate
/// authentication authority across process-lifetime job slices.
package struct UnavailableDatabaseJobService: DatabaseJobService {
    package let jobOperations: [JobOperationIdentifier] = []

    #if DATABASE_SERVER_MULTI_BASE
    package func startBaseAdmission(
        for operation: JobOperationIdentifier
    ) throws -> DatabaseBaseAdmissionKind {
        _ = operation
        throw DatabaseJobAuthorizationError.validatorUnavailable
    }
    #endif

    package func start(
        _ request: JobStartOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobStartExecutionResult {
        _ = request
        _ = context
        throw DatabaseJobAuthorizationError.validatorUnavailable
    }

    package func status(
        _ request: JobStatusOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobStatusOperation.Response {
        _ = request
        _ = context
        throw DatabaseJobAuthorizationError.validatorUnavailable
    }

    package func result(
        _ request: JobResultOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobResultOperation.Response {
        _ = request
        _ = context
        throw DatabaseJobAuthorizationError.validatorUnavailable
    }

    package func cancel(
        _ request: JobCancelOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobCancellationExecutionResult {
        _ = request
        _ = context
        throw DatabaseJobAuthorizationError.validatorUnavailable
    }

    package func runScheduledWork() async throws {}
}
