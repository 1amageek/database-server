import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
import DatabaseKit
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire

public struct JobStartHandler: DatabaseOperationEndpointHandler {
    public typealias Operation = JobStartOperation

    private let service: AnyDatabaseJobService
    private let runtimeLimits: DatabaseOperationLimits

    public init(
        service: AnyDatabaseJobService,
        runtimeLimits: DatabaseOperationLimits = .default
    ) {
        self.service = service
        self.runtimeLimits = runtimeLimits
    }

    public func requirement(
        for request: JobStartOperation.Request
    ) throws -> DatabaseOperationRequirement {
        #if DATABASE_SERVER_MULTI_BASE
        DatabaseOperationRequirement(
            acceptedTargets: [.database, .base],
            access: .administer,
            transaction: .write,
            baseAdmission: try service.startBaseAdmission(for: request.operation)
        )
        #else
        _ = request
        return DatabaseOperationRequirement(
            access: .administer,
            transaction: .write
        )
        #endif
    }

    public func invoke(
        request: JobStartOperation.Request,
        context: DatabaseOperationContext,
        limits: DatabaseWireLimits
    ) async throws -> DatabaseOperationResult {
        guard request.maximumSliceWorkUnits > 0,
              request.maximumSliceWorkUnits <= runtimeLimits.maximumWorkUnits else {
            throw DatabaseOperationLimitError.invalidMaximumWorkUnits(
                requested: request.maximumSliceWorkUnits,
                maximum: runtimeLimits.maximumWorkUnits
            )
        }
        return try await service.start(request, context: context)
            .operationResult
    }
}
