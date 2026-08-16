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
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import StorageKit

/// Executes database-scoped control metadata operations. Data-domain access
/// is intentionally absent from this boundary.
package final class DatabaseControlExecutor: Sendable {
    private let container: DBContainer
    package let authorization: AuthorizationContext
    #if DATABASE_SERVER_MULTIPLE_BASES
    package let dataExecutor: DatabaseDataOperationExecutor?
    #else
    package let dataExecutor: DatabaseDataOperationExecutor
    #endif

    package init(
        container: DBContainer,
        authorization: AuthorizationContext
    ) {
        self.container = container
        self.authorization = authorization
        #if DATABASE_SERVER_MULTIPLE_BASES
        self.dataExecutor = nil
        #else
        let context = container.makeExecutionContext(
            authorization: authorization
        )
        self.dataExecutor = DatabaseDataOperationExecutor(
            container: container,
            authorization: authorization,
            dataContext: context
        )
        #endif
    }

    package var monotonicClock: any StorageMonotonicClock {
        container.monotonicClock
    }

    package var wallClock: any WallClock { container.wallClock }
    package var schema: Schema { container.schema }
    package var schemaFingerprint: SchemaFingerprint {
        container.schemaFingerprint
    }
    package var schemaGeneration: UInt64 { container.schemaGeneration }
    package var runtimeConfiguration: DatabaseRuntimeConfiguration {
        container.runtimeConfiguration
    }
    package var containerIdentity: ObjectIdentifier {
        ObjectIdentifier(container)
    }

    package func withTransaction<Result: Sendable>(
        requiredAccess: Security.Access,
        configuration: TransactionConfiguration = .default,
        executionDeadline: TransactionExecutionDeadline? = nil,
        _ operation: @Sendable @escaping (
            DatabaseTransaction
        ) async throws -> Result
    ) async throws -> Result {
        try await container.withServerControlTransaction(
            requiredAccess: requiredAccess,
            authorization: authorization,
            configuration: configuration,
            executionDeadline: executionDeadline,
            operation
        )
    }

    package func withMetadataTransaction<Result: Sendable>(
        configuration: TransactionConfiguration = .default,
        executionDeadline: TransactionExecutionDeadline? = nil,
        _ operation: @Sendable @escaping (
            DatabaseTransaction
        ) async throws -> Result
    ) async throws -> Result {
        try await container.withControlMetadataTransaction(
            configuration: configuration,
            executionDeadline: executionDeadline,
            operation
        )
    }

    #if DATABASE_SERVER_MULTIPLE_BASES
    package var grantStore: DatabaseGrantStore {
        container.executionDatabaseGrantStore
    }

    package var defaultPlacementID: Base.Placement.ID {
        container.executionDefaultBasePlacementID
    }

    package func placementIDs() -> [Base.Placement.ID] {
        container.executionBasePlacementIDs()
    }

    package func requirePlacement(_ id: Base.Placement.ID) throws {
        try container.executionRequireBasePlacement(id)
    }

    package func loadBases() async throws -> [DatabaseBaseRecord] {
        try await withTransaction(
            requiredAccess: .read,
            configuration: .readOnly
        ) {
            transaction in
            try await self.container.executionLoadBaseRecords(
                transaction: transaction.executionStorageAccess
            )
        }
    }

    package func loadBases(
        transaction: DatabaseTransaction
    ) async throws -> [DatabaseBaseRecord] {
        try await container.executionLoadBaseRecords(
            transaction: transaction.executionStorageAccess
        )
    }
    #endif

    package func schemaApplication(
        idempotencyKey: String,
        transaction: DatabaseTransaction
    ) async throws -> DatabaseSchemaApplicationRecord? {
        try await DatabaseSchemaApplicationStore(
            controlRoot: container.controlStorage().root
        ).load(
            idempotencyKey: idempotencyKey,
            transaction: transaction.executionStorageAccess
        )
    }

    package func insertSchemaApplication(
        _ record: DatabaseSchemaApplicationRecord,
        transaction: DatabaseTransaction
    ) async throws {
        try await DatabaseSchemaApplicationStore(
            controlRoot: container.controlStorage().root
        ).insert(record, transaction: transaction.executionStorageAccess)
    }

    package func finishSchemaApplication(
        job: JobIdentity,
        transaction: DatabaseTransaction
    ) async throws {
        try await DatabaseSchemaApplicationStore(
            controlRoot: container.controlStorage().root
        ).finish(job: job, transaction: transaction.executionStorageAccess)
    }

    package func makeSchemaTransitionExecutor(
        runtimeFactory: AnyDatabaseSchemaRuntimeFactory
    ) -> DatabaseSchemaTransitionExecutor {
        DatabaseSchemaTransitionExecutor(
            container: container,
            authorization: authorization,
            runtimeFactory: runtimeFactory
        )
    }

    #if DATABASE_SERVER_MULTIPLE_BASES
    package func loadBase(_ id: Base.ID) async throws -> DatabaseBaseRecord? {
        try await withMetadataTransaction(configuration: .readOnly) {
            transaction in
            try await self.container.executionLoadBaseRecord(
                id,
                transaction: transaction.executionStorageAccess
            )
        }
    }

    package func provisionBase(
        _ id: Base.ID,
        placementID: Base.Placement.ID,
        initialGrants: [Security.Grant],
        expectedRevision: UInt64
    ) async throws -> DatabaseBaseRecord {
        try await container.executionProvisionBaseRecord(
            id,
            placementID: placementID,
            initialGrants: initialGrants,
            expectedRevision: expectedRevision
        )
    }

    package func visibleCompositions() async throws
        -> [DatabaseCompositionRecord] {
        let records = try await withTransaction(
            requiredAccess: .read,
            configuration: .readOnly
        ) { transaction in
            try await self.container.executionLoadCompositionRecords(
                transaction: transaction.executionStorageAccess
            )
        }
        var visible: [DatabaseCompositionRecord] = []
        visible.reserveCapacity(records.count)
        for record in records {
            do {
                _ = try await container.session(
                    authorization: authorization
                ).composition(record.composition.id).resolve()
                visible.append(record)
            } catch is DatabaseCompositionAccessError {
                continue
            }
        }
        return visible
    }

    package func createComposition(
        _ composition: Base.Composition,
        expectedRevision: UInt64,
        transaction: DatabaseTransaction
    ) async throws -> DatabaseCompositionRecord {
        return try await container.executionCreateCompositionRecord(
            composition,
            expectedRevision: expectedRevision,
            transaction: transaction.executionStorageAccess
        )
    }

    package func replaceComposition(
        id: Base.Composition.ID,
        bases: [Base.ID],
        expectedRevision: UInt64,
        transaction: DatabaseTransaction
    ) async throws -> DatabaseCompositionRecord {
        return try await container.executionReplaceCompositionRecord(
            id: id,
            bases: bases,
            expectedRevision: expectedRevision,
            transaction: transaction.executionStorageAccess
        )
    }

    package func deleteComposition(
        _ id: Base.Composition.ID,
        expectedRevision: UInt64,
        transaction: DatabaseTransaction
    ) async throws -> (revision: UInt64, generation: UInt64) {
        try await container.executionDeleteCompositionRecord(
            id,
            expectedRevision: expectedRevision,
            transaction: transaction.executionStorageAccess
        )
    }

    #endif
}
