import DatabaseCommandOperations
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseGraphOperations
import DatabaseJobRuntime
import DatabaseKit
import DatabaseMaintenanceOperations
import DatabaseMutationOperations
import DatabaseOperationCore
import DatabaseQueryOperations
import DatabaseSchemaOperations
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire

/// Owns the cross-domain sequencing required by one database-scoped schema
/// transition. Each callback receives an executor fixed to one data root.
package final class DatabaseSchemaTransitionExecutor: Sendable {
    package struct PreparedRuntime: Sendable {
        package let configuration: DatabaseRuntimeConfiguration
        package let generation: DatabasePreparedSchemaGeneration
    }

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
        #if DATABASE_SERVER_MULTI_BASE
        switch target.resource {
        case .database:
            guard target.generation == 0 else {
                throw DatabaseSchemaApplyJobError.corruptedPlan
            }
            return try await container.withExecutionDataRoot {
                let context = self.container.makeExecutionContext(
                    authorization: self.authorization
                )
                let executor = DatabaseDataOperationExecutor(
                    resource: .database,
                    container: self.container,
                    authorization: self.authorization,
                    dataContext: context
                )
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
        targetSchema: Schema,
        physicalLayouts: [String: IndexPhysicalLayout],
        retirements: [DatabaseIndexTransitionPlan.Target]
    ) async throws {
        try await withDataTarget(target) { executor in
            try await executor.withDataTransaction(
                requiredAccess: .administer,
                configuration: .batch
            ) { transaction in
                _ = try await self.container.initializeSchemaIndexStates(
                    for: targetSchema,
                    indexPhysicalLayouts: physicalLayouts,
                    transaction: transaction.executionStorageAccess
                )
                try await self.container.stageSchemaIndexRetirements(
                    retirements.map(DatabasePendingIndexRetirement.init),
                    validFor: targetSchema,
                    indexPhysicalLayouts: physicalLayouts,
                    transaction: transaction.executionStorageAccess
                )
            }
        }
    }

    package func preflight(
        schema: Schema,
        expectedIndexPhysicalFingerprint: ByteString? = nil
    ) async throws -> PreparedRuntime {
        let configuration =
            try await runtimeFactory
            .makeOperationConfiguration(for: schema)
        let generation = try container.prepareSchemaGeneration(
            schema,
            runtimeConfiguration: configuration
        )
        if let expectedIndexPhysicalFingerprint,
            generation.indexPhysicalFingerprint
                != expectedIndexPhysicalFingerprint
        {
            throw DatabaseSchemaApplyJobError.physicalLayoutChanged
        }
        return PreparedRuntime(
            configuration: configuration,
            generation: generation
        )
    }

    package func planIndexTransition(
        targetSchema: Schema,
        preparedGeneration: DatabasePreparedSchemaGeneration
    ) throws -> DatabaseIndexTransitionPlan {
        try container.planIndexTransition(
            to: targetSchema,
            preparedGeneration: preparedGeneration
        )
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
                    transaction: transaction.executionStorageAccess
                )
            }
        }
    }

    package func publish(
        manifest: SchemaManifest,
        expectedFingerprint: SchemaFingerprint,
        targetFingerprint: SchemaFingerprint,
        expectedIndexPhysicalFingerprint: ByteString,
        idempotencyKey: String
    ) async throws -> DatabaseSchemaPublicationResult {
        let prepared = try await preflight(
            schema: manifest.schema,
            expectedIndexPhysicalFingerprint:
                expectedIndexPhysicalFingerprint
        )
        return try await container.publishSchema(
            manifest.schema,
            fingerprint: targetFingerprint,
            expectedFingerprint: expectedFingerprint,
            idempotencyKey: idempotencyKey,
            authorization: authorization,
            runtimeConfiguration: prepared.configuration
        )
    }

    package func waitForRetiredSchemaRequestsToDrain(
        expectedFingerprint: SchemaFingerprint,
        expectedVersion: Schema.Version,
        expectedIndexPhysicalFingerprint: ByteString
    ) async throws {
        try Task.checkCancellation()
        let lease = container.acquirePublishedSchemaLease()
        guard lease.fingerprint == expectedFingerprint,
            lease.schema.version == expectedVersion,
            lease.indexPhysicalFingerprint
                == expectedIndexPhysicalFingerprint
        else {
            throw DatabaseSchemaApplyJobError.publishedSchemaMismatch
        }
        try await container.waitForSchemaLeases(
            olderThan: lease.generation
        )
        try Task.checkCancellation()
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
                transaction: transaction.executionStorageAccess
            )
        }
    }
}
