import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
@_spi(DatabaseExecution) import DatabaseWire

public protocol DatabaseJobService: Sendable {
    var jobOperations: [JobOperationIdentifier] { get }

    #if DATABASE_SERVER_MULTI_BASE
    /// Resolves the Base lifecycle admission required while a concrete durable
    /// operation is validated and compiled.
    func startBaseAdmission(
        for operation: JobOperationIdentifier
    ) throws -> DatabaseBaseAdmissionKind
    #endif

    func start(
        _ request: JobStartOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobStartExecutionResult

    func status(
        _ request: JobStatusOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobStatusOperation.Response

    func result(
        _ request: JobResultOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobResultOperation.Response

    func cancel(
        _ request: JobCancelOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobCancellationExecutionResult

    /// Processes due work and persists the next required scheduler wake-up.
    ///
    /// Phase failures are reported as `PersistentJobScheduledWorkError`.
    /// Task cancellation is propagated directly as `CancellationError`.
    func runScheduledWork() async throws
}
