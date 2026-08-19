import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire

/// Executes one already-decoded database operation against a target-bound
/// container. Wire framing is owned by `DatabaseWireEndpoint`.
package final class DatabaseOperationDispatcher: Sendable {
    private let container: DBContainer
    private let registry: DatabaseOperationRegistry
    private let admissionPolicy: AnyDatabaseOperationAdmissionPolicy
    private let middlewares: [AnyDatabaseRequestMiddleware]

    package init(
        container: DBContainer,
        registry: DatabaseOperationRegistry,
        admissionPolicy: AnyDatabaseOperationAdmissionPolicy,
        middlewares: [AnyDatabaseRequestMiddleware] = []
    ) {
        self.container = container
        self.registry = registry
        self.admissionPolicy = admissionPolicy
        self.middlewares = middlewares
    }

    package func execute(
        _ request: DatabaseWireRequestEnvelope,
        context executionContext: DatabaseRequestExecutionContext,
        requestLimits: DatabaseWireLimits,
        responseLimits: DatabaseWireLimits
    ) async throws -> DatabaseOperationDispatchOutcome {
        try await container.withSchemaLease { _ in
            try await RequestAuthorization.$context.withValue(
                executionContext.authorization
            ) {
                try await executePreparedRequest(
                    request,
                    executionContext: executionContext,
                    requestLimits: requestLimits,
                    responseLimits: responseLimits
                )
            }
        }
    }

    private func executePreparedRequest(
        _ request: DatabaseWireRequestEnvelope,
        executionContext: DatabaseRequestExecutionContext,
        requestLimits: DatabaseWireLimits,
        responseLimits: DatabaseWireLimits
    ) async throws -> DatabaseOperationDispatchOutcome {
        guard let operationHandler = registry.resolve(request.operation) else {
            let requirement = DatabaseOperationRequirement.canonical(
                for: request.operation
            )
            let context = makeContext(
                request: request,
                executionContext: executionContext,
                requirement: requirement,
                wireLimits: responseLimits
            )
            return .failure(
                DatabaseOperationDispatchFailure(
                    error: DatabaseOperationError.missingHandler(
                        request.operation
                    ),
                    context: context
                )
            )
        }
        let prepared: PreparedDatabaseOperation
        do {
            prepared = try operationHandler.prepare(
                envelope: request,
                limits: requestLimits
            )
        } catch {
            let context = makeContext(
                request: request,
                executionContext: executionContext,
                requirement: DatabaseOperationRequirement.canonical(
                    for: request.operation
                ),
                wireLimits: responseLimits
            )
            return .failure(
                DatabaseOperationDispatchFailure(
                    error: error,
                    context: context
                )
            )
        }
        #if DATABASE_SERVER_MULTI_BASE
        guard prepared.requirement.acceptedTargets.accepts(request.target) else {
            let context = makeContext(
                request: request,
                executionContext: executionContext,
                requirement: prepared.requirement,
                wireLimits: responseLimits
            )
            return .failure(
                DatabaseOperationDispatchFailure(
                    error: DatabaseOperationError.targetKindNotAccepted(
                        request.target
                    ),
                    context: context
                )
            )
        }
        #endif
        #if DATABASE_SERVER_MULTI_BASE
        let admissionRequest = DatabaseOperationAdmissionRequest(
            requestID: request.requestID,
            operation: request.operation,
            target: request.target,
            metadata: request.metadata,
            authorization: executionContext.authorization
        )
        #else
        let admissionRequest = DatabaseOperationAdmissionRequest(
            requestID: request.requestID,
            operation: request.operation,
            metadata: request.metadata,
            authorization: executionContext.authorization
        )
        #endif
        if case .deny(let denial) = admissionPolicy.decision(
            for: admissionRequest
        ) {
            let context = makeContext(
                request: request,
                executionContext: executionContext,
                requirement: prepared.requirement,
                wireLimits: responseLimits
            )
            return .failure(
                DatabaseOperationDispatchFailure(
                    error: RemoteOperationError(
                        category: .authorization,
                        code: denial.code,
                        message: denial.message,
                        retryability: denial.retryability,
                        details: denial.details
                    ),
                    context: context
                )
            )
        }
        return try await execute(
            prepared,
            request: request,
            executionContext: executionContext,
            wireLimits: responseLimits
        )
    }

    private func execute(
        _ prepared: PreparedDatabaseOperation,
        request: DatabaseWireRequestEnvelope,
        executionContext: DatabaseRequestExecutionContext,
        wireLimits: DatabaseWireLimits
    ) async throws -> DatabaseOperationDispatchOutcome {
        #if DATABASE_SERVER_MULTI_BASE
        switch request.target {
        case .database:
            let context = makeContext(
                request: request,
                executionContext: executionContext,
                requirement: prepared.requirement,
                wireLimits: wireLimits
            )
            return try await container.withExecutionDataRoot {
                try await self.invoke(
                    prepared,
                    request: request,
                    context: context
                )
            }
        case .base(let baseID):
            let lease: DatabaseBaseLease
            do {
                lease = try container.executionAcquireBaseLease(
                    baseID,
                    permitsInactiveMaintenance:
                        prepared.requirement.baseAdmission != .activeData
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if prepared.requirement.baseAdmission == .lifecycleJob {
                    let context = self.makeContext(
                        request: request,
                        executionContext: executionContext,
                        requirement: prepared.requirement,
                        wireLimits: wireLimits
                    )
                    return try await self.invoke(
                        prepared,
                        request: request,
                        context: context
                    )
                }
                let context = self.makeContext(
                    request: request,
                    executionContext: executionContext,
                    requirement: prepared.requirement,
                    wireLimits: wireLimits
                )
                return .failure(
                    DatabaseOperationDispatchFailure(
                        error: Self.baseUnavailableError(),
                        context: context
                    )
                )
            }
            return try await container.executionWithBaseLease(lease) {
                let baseContext = self.container.session(
                    authorization: executionContext.authorization
                ).base(baseID).newContext()
                let context = self.makeBaseContext(
                    request: request,
                    executionContext: executionContext,
                    baseContext: baseContext,
                    requirement: prepared.requirement,
                    wireLimits: wireLimits
                )
                return try await self.invoke(
                    prepared,
                    request: request,
                    context: context
                )
            }
        case .composition(let selection):
            let source = container.session(
                authorization: executionContext.authorization
            ).composition(selection)
            let context = makeCompositionContext(
                request: request,
                executionContext: executionContext,
                composition: source,
                requirement: prepared.requirement,
                wireLimits: wireLimits
            )
            return try await invoke(
                prepared,
                request: request,
                context: context
            )
        }
        #else
        let context = makeContext(
            request: request,
            executionContext: executionContext,
            requirement: prepared.requirement,
            wireLimits: wireLimits
        )
        return try await invoke(
            prepared,
            request: request,
            context: context
        )
        #endif
    }

    #if DATABASE_SERVER_MULTI_BASE
    private static func baseUnavailableError() -> RemoteOperationError {
        RemoteOperationError(
            category: .authorization,
            code: "BASE_UNAVAILABLE",
            message: "The Base is unavailable",
            retryability: .never
        )
    }
    #endif

    private func makeContext(
        request: DatabaseWireRequestEnvelope,
        executionContext: DatabaseRequestExecutionContext,
        requirement: DatabaseOperationRequirement,
        wireLimits: DatabaseWireLimits
    ) -> DatabaseOperationContext {
        #if DATABASE_SERVER_MULTI_BASE
        return DatabaseOperationContext(
            container: container,
            target: request.target,
            baseContext: nil,
            composition: nil,
            requirement: requirement,
            requestID: request.requestID,
            metadata: request.metadata,
            authorization: executionContext.authorization,
            jobAuthorizationReference:
                executionContext.jobAuthorizationReference,
            requestPayload: request.payload,
            wireLimits: wireLimits
        )
        #else
        DatabaseOperationContext(
            container: container,
            requirement: requirement,
            requestID: request.requestID,
            metadata: request.metadata,
            authorization: executionContext.authorization,
            jobAuthorizationReference:
                executionContext.jobAuthorizationReference,
            requestPayload: request.payload,
            wireLimits: wireLimits
        )
        #endif
    }

    #if DATABASE_SERVER_MULTI_BASE
    private func makeBaseContext(
        request: DatabaseWireRequestEnvelope,
        executionContext: DatabaseRequestExecutionContext,
        baseContext: DatabaseContext,
        requirement: DatabaseOperationRequirement,
        wireLimits: DatabaseWireLimits
    ) -> DatabaseOperationContext {
        DatabaseOperationContext(
            container: container,
            target: request.target,
            baseContext: baseContext,
            composition: nil,
            requirement: requirement,
            requestID: request.requestID,
            metadata: request.metadata,
            authorization: executionContext.authorization,
            jobAuthorizationReference:
                executionContext.jobAuthorizationReference,
            requestPayload: request.payload,
            wireLimits: wireLimits
        )
    }

    private func makeCompositionContext(
        request: DatabaseWireRequestEnvelope,
        executionContext: DatabaseRequestExecutionContext,
        composition: CompositionDataSource,
        requirement: DatabaseOperationRequirement,
        wireLimits: DatabaseWireLimits
    ) -> DatabaseOperationContext {
        DatabaseOperationContext(
            container: container,
            target: request.target,
            baseContext: nil,
            composition: composition,
            requirement: requirement,
            requestID: request.requestID,
            metadata: request.metadata,
            authorization: executionContext.authorization,
            jobAuthorizationReference:
                executionContext.jobAuthorizationReference,
            requestPayload: request.payload,
            wireLimits: wireLimits
        )
    }
    #endif

    private func invoke(
        _ prepared: PreparedDatabaseOperation,
        request: DatabaseWireRequestEnvelope,
        context: DatabaseOperationContext
    ) async throws -> DatabaseOperationDispatchOutcome {
        let result: DatabaseOperationResult
        do {
            result = try await handlerChain(prepared: prepared)(request, context)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(
                DatabaseOperationDispatchFailure(
                    error: error,
                    context: context
                )
            )
        }

        guard result.operation == request.operation else {
            return .failure(
                DatabaseOperationDispatchFailure(
                    error: DatabaseOperationError.responseOperationMismatch(
                        expected: request.operation,
                        actual: result.operation
                    ),
                    context: context
                )
            )
        }
        return .success(result, context: context)
    }

    private func handlerChain(
        prepared: PreparedDatabaseOperation
    ) -> DatabaseRequestHandler {
        var handler: DatabaseRequestHandler = { request, context in
            _ = request
            return try await prepared.invoke(context)
        }
        for middleware in middlewares.reversed() {
            let next = handler
            handler = { request, context in
                try await middleware.handle(
                    request: request,
                    context: context,
                    next: next
                )
            }
        }
        return handler
    }

}
