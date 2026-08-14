import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
@_spi(DatabaseExecution) import DatabaseWire

/// Owns the cross-domain sequencing required by one database-scoped schema
/// transition. Each callback receives an executor fixed to one data root.
package final class DatabaseSchemaTransitionExecutor: Sendable {
    private let container: DBContainer
    private let authorization: AuthorizationContext
    private let runtimeFactory: AnyDatabaseSchemaRuntimeFactory

    package init(
        container: DBContainer,
        authorization: AuthorizationContext,
        runtimeFactory: AnyDatabaseSchemaRuntimeFactory
    ) {
        self.container = container
        self.authorization = authorization
        self.runtimeFactory = runtimeFactory
    }

    func withDataTarget<Result: Sendable>(
        _ target: DatabaseSchemaApplyJobPlan.DataTarget,
        _ operation: @Sendable @escaping (
            DatabaseDataOperationExecutor
        ) async throws -> Result
    ) async throws -> Result {
        #if DATABASE_SERVER_MULTIPLE_BASES
        switch target.resource {
        case .database:
            guard target.generation == 0 else {
                throw DatabaseSchemaApplyJobError.corruptedPlan
            }
            return try await container.withExecutionDataRoot {
                let context = self.container.makeExecutionContext(
                    authorization: self.authorization
                )
                #if DATABASE_SERVER_MULTIPLE_BASES
                let executor = DatabaseDataOperationExecutor(
                    resource: .database,
                    container: self.container,
                    authorization: self.authorization,
                    dataContext: context
                )
                #else
                let executor = DatabaseDataOperationExecutor(
                    container: self.container,
                    authorization: self.authorization,
                    dataContext: context
                )
                #endif
                return try await operation(executor)
            }
        case .base(let id):
            let lease = try container
                .executionAcquireBaseSchemaMaintenanceLease(id)
            guard lease.placementGeneration == target.generation else {
                throw DatabaseSchemaApplyJobError.baseGenerationChanged(id)
            }
            return try await container.executionWithBaseLease(lease) {
                let context = self.container.session(
                    authorization: self.authorization
                ).base(id).newContext()
                return try await operation(
                    DatabaseDataOperationExecutor(
                        resource: .base(id),
                        container: self.container,
                        authorization: self.authorization,
                        dataContext: context
                    )
                )
            }
        }
        #else
        guard target.generation == 0 else {
            throw DatabaseSchemaApplyJobError.corruptedPlan
        }
        let context = container.makeExecutionContext(
            authorization: authorization
        )
        return try await operation(
            DatabaseDataOperationExecutor(
                container: container,
                authorization: authorization,
                dataContext: context
            )
        )
        #endif
    }

    func stage(
        _ target: DatabaseSchemaApplyJobPlan.DataTarget,
        previousSchema: Schema,
        targetSchema: Schema
    ) async throws {
        try await withDataTarget(target) { executor in
            try await executor.withDataTransaction(
                requiredAccess: .administer,
                configuration: .batch
            ) { transaction in
                _ = try await self.container.initializeNewSchemaIndexStates(
                    from: previousSchema,
                    to: targetSchema,
                    transaction: transaction.serverStorageAccess
                )
            }
        }
    }

    func installSnapshot(
        _ target: DatabaseSchemaApplyJobPlan.DataTarget,
        schema: Schema
    ) async throws {
        try await withDataTarget(target) { executor in
            try await executor.withDataTransaction(
                requiredAccess: .administer,
                configuration: .batch
            ) { transaction in
                try executor.installSchemaSnapshot(
                    schema,
                    transaction: transaction.serverStorageAccess
                )
            }
        }
    }

    package func publish(
        manifest: SchemaManifest,
        expectedFingerprint: SchemaFingerprint,
        targetFingerprint: SchemaFingerprint,
        idempotencyKey: String
    ) async throws -> DatabaseSchemaPublicationResult {
        let runtimeConfiguration = try await runtimeFactory
            .makeOperationConfiguration(for: manifest.schema)
        try container.validateSchemaGeneration(
            manifest.schema,
            runtimeConfiguration: runtimeConfiguration
        )
        return try await container.publishSchema(
            manifest.schema,
            fingerprint: targetFingerprint,
            expectedFingerprint: expectedFingerprint,
            idempotencyKey: idempotencyKey,
            authorization: authorization,
            runtimeConfiguration: runtimeConfiguration
        )
    }

    package func finish(job: JobIdentity) async throws {
        try await container.withServerControlTransaction(
            requiredAccess: .administer,
            authorization: authorization,
            configuration: .batch
        ) { transaction in
            try await DatabaseSchemaApplicationStore(
                controlRoot: self.container.controlStorage().root
            ).finish(
                job: job,
                transaction: transaction.serverStorageAccess
            )
        }
    }
}
