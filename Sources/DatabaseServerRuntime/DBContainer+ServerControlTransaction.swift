import DatabaseOperationCore
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit

extension DBContainer {
    /// Adapts server operation authorization to the selected framework build.
    /// Persisted Grant evaluation exists only with `MultipleBases`; the
    /// ordinary runtime binds the authenticated principal solely for entity
    /// and field policy evaluation.
    package func withServerControlTransaction<Result: Sendable>(
        requiredAccess: Security.Access,
        authorization: AuthorizationContext,
        configuration: TransactionConfiguration = .default,
        executionDeadline: TransactionExecutionDeadline? = nil,
        _ operation: @Sendable @escaping (
            DatabaseTransaction
        ) async throws -> Result
    ) async throws -> Result {
        #if DATABASE_SERVER_MULTIPLE_BASES
        try await withControlTransaction(
            requiredAccess: requiredAccess,
            authorization: authorization,
            configuration: configuration,
            executionDeadline: executionDeadline,
            operation
        )
        #else
        _ = requiredAccess
        return try await withControlTransaction(
            authorization: authorization,
            configuration: configuration,
            executionDeadline: executionDeadline,
            operation
        )
        #endif
    }
}
