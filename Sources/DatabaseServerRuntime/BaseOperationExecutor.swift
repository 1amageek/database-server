import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
#if DATABASE_SERVER_MULTIPLE_BASES
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import StorageKit
#if DATABASE_OPERATIONS_GRAPH_INDEXES
import GraphIndex
#endif

/// Executes operations fixed to one Base identity. It exposes no API for
/// resolving a different Base.
package final class BaseOperationExecutor: Sendable {
    package let baseID: Base.ID
    package let authorization: AuthorizationContext
    package let dataExecutor: DatabaseDataOperationExecutor
    private let container: DBContainer
    private let dataContext: DatabaseContext?

    package init(
        baseID: Base.ID,
        container: DBContainer,
        authorization: AuthorizationContext,
        dataContext: DatabaseContext?
    ) {
        self.baseID = baseID
        self.container = container
        self.authorization = authorization
        self.dataContext = dataContext
        self.dataExecutor = dataContext.map {
            DatabaseDataOperationExecutor(
                resource: .base(baseID),
                container: container,
                authorization: authorization,
                dataContext: $0
            )
        } ?? DatabaseDataOperationExecutor(
            resource: .base(baseID),
            container: container,
            authorization: authorization,
            dataContext: container.session(
                authorization: authorization
            ).base(baseID).newContext()
        )
    }

    package var monotonicClock: any StorageMonotonicClock {
        container.monotonicClock
    }

    package var wallClock: any WallClock { container.wallClock }
    package var schema: Schema { container.schema }
    package var schemaGeneration: UInt64 { container.schemaGeneration }
    package var runtimeConfiguration: DatabaseRuntimeConfiguration {
        container.runtimeConfiguration
    }
    package var containerIdentity: ObjectIdentifier {
        ObjectIdentifier(container)
    }

    package func requireDataContext() throws -> DatabaseContext {
        guard let dataContext else {
            throw DatabaseOperationError.targetKindNotAccepted(.base(baseID))
        }
        return dataContext
    }

    package func withAdministrationTransaction<Result: Sendable>(
        requiredAccess: Security.Access,
        configuration: TransactionConfiguration = .default,
        executionDeadline: TransactionExecutionDeadline? = nil,
        _ operation: @Sendable @escaping (
            DatabaseTransaction
        ) async throws -> Result
    ) async throws -> Result {
        try await container.executionWithBaseAdministrationTransaction(
            baseID: baseID,
            requiredAccess: requiredAccess,
            authorization: authorization,
            configuration: configuration,
            executionDeadline: executionDeadline,
            operation
        )
    }

    package func withStorageTransaction<Result: Sendable>(
        requiredAccess: Security.Access = .read,
        configuration: TransactionConfiguration = .default,
        executionDeadline: TransactionExecutionDeadline? = nil,
        _ operation: @Sendable @escaping (
            any TransactionAccess
        ) async throws -> Result
    ) async throws -> Result {
        let context = try requireDataContext()
        return try await context.withExecutionTransaction(
            requiredAccess: requiredAccess,
            configuration: configuration,
            executionDeadline: executionDeadline
        ) { transaction in
            try await operation(transaction.executionStorageAccess)
        }
    }

    /// Runs work inside the selected active Base while requiring an
    /// administrative Grant. Unlike `withAdministrationTransaction`, this
    /// preserves data admission and may therefore execute index or migration
    /// work that reads and writes the Base's data namespace.
    package func withActiveDataTransaction<Result: Sendable>(
        requiredAccess: Security.Access,
        configuration: TransactionConfiguration = .default,
        executionDeadline: TransactionExecutionDeadline? = nil,
        _ operation: @Sendable @escaping (
            DatabaseTransaction
        ) async throws -> Result
    ) async throws -> Result {
        let context = try requireDataContext()
        return try await context.withExecutionTransaction(
            requiredAccess: requiredAccess,
            configuration: configuration,
            executionDeadline: executionDeadline,
            operation
        )
    }

    package func makeIndexMaintenanceRuntime()
        -> DatabaseIndexMaintenanceRuntime {
        DatabaseIndexMaintenanceRuntime(container: container)
    }

    package func pendingSchemaIndexBuilds(
        in schema: Schema,
        transaction: any TransactionAccess
    ) async throws -> [String: Set<String>] {
        try await container.pendingSchemaIndexBuilds(
            in: schema,
            transaction: transaction
        )
    }

    package func partitionCatalogPage(
        entity: String,
        continuation: ByteString?,
        limit: Int,
        transaction: any TransactionAccess
    ) async throws -> DatabasePartitionCatalogPage {
        try await container.executionPartitionCatalogPage(
            entity: entity,
            continuation: continuation,
            limit: limit,
            transaction: transaction
        )
    }

    package func completeSchemaIndexBuild(
        entity: String,
        index: String,
        transaction: any TransactionAccess
    ) throws {
        try container.completeSchemaIndexBuild(
            entity: entity,
            index: index,
            transaction: transaction
        )
    }

    package func installSchemaSnapshot(
        _ schema: Schema,
        transaction: any TransactionAccess
    ) throws {
        try container.installDataRootSchemaSnapshot(
            schema,
            transaction: transaction
        )
    }

    func indexStatusPage(
        entity: String?,
        index: String?,
        partitions: FieldObject,
        continuation: ByteString?,
        budget: ExecutionBudget,
        wireLimits: DatabaseWireLimits,
        transaction: any TransactionAccess
    ) async throws -> DatabaseIndexStatusTargetPage {
        try await DatabaseIndexStatusPager(
            container: container,
            wireLimits: wireLimits
        ).page(
            entity: entity,
            index: index,
            partitions: partitions,
            continuation: continuation,
            budget: budget,
            transaction: transaction
        )
    }

    package func migrationStatus(
        targetVersion: Schema.Version? = nil,
        transaction: any TransactionAccess
    ) async throws -> DatabaseMigrationStatus {
        let context = try requireDataContext()
        return try await context.withExecutionDataOperation {
            try await self.container.migrationStatus(
                targetVersion: targetVersion,
                transaction: transaction
            )
        }
    }

    package func migrationStatus(
        targetVersion: Schema.Version? = nil
    ) async throws -> DatabaseMigrationStatus {
        try await withStorageTransaction(
            requiredAccess: .administer,
            configuration: .readOnly
        ) { transaction in
            try await self.container.migrationStatus(
                targetVersion: targetVersion,
                transaction: transaction
            )
        }
    }

    package func runMigrations(
        targetVersion: Schema.Version? = nil,
        maximumStageCount: UInt64
    ) async throws -> DatabaseMigrationExecutionResult {
        try await authorize(.administer)
        let context = try requireDataContext()
        return try await context.withExecutionDataOperation {
            try await self.container.runMigrations(
                targetVersion: targetVersion,
                maximumStageCount: maximumStageCount
            )
        }
    }

    package func authorize(_ access: Security.Access) async throws {
        try await withAdministrationTransaction(
            requiredAccess: access,
            configuration: .readOnly
        ) { _ in () }
    }

    package func grantStore() throws -> DatabaseGrantStore {
        try container.executionBoundBaseGrantStore(
            expectedBaseID: baseID
        )
    }

    package func maintenanceCheckpoint(
        for jobID: DatabaseTypes.UUID,
        transaction: any TransactionAccess
    ) async throws -> ByteString? {
        try await transaction.getValue(
            for: try maintenanceCheckpointKey(for: jobID),
            snapshot: false
        )
    }

    package func storeMaintenanceCheckpoint(
        _ value: ByteString,
        for jobID: DatabaseTypes.UUID,
        transaction: any TransactionAccess
    ) throws {
        try transaction.setValue(
            value,
            for: try maintenanceCheckpointKey(for: jobID)
        )
    }

    package func clearMaintenanceCheckpoint(
        for jobID: DatabaseTypes.UUID,
        transaction: any TransactionAccess
    ) throws {
        try transaction.clear(key: maintenanceCheckpointKey(for: jobID))
    }

    private func maintenanceCheckpointKey(
        for jobID: DatabaseTypes.UUID
    ) throws -> ByteString {
        return try container.executionBoundBaseMetadataSubspace(
            expectedBaseID: baseID,
            component: "maintenance-job-checkpoints"
        )
            .pack(Tuple(jobID))
    }

    package func loadRecord() async throws -> DatabaseBaseRecord {
        try await container.executionLoadBaseRecord(baseID)
    }

    package func requirePlacement(_ id: Base.Placement.ID) throws {
        try container.executionRequireBasePlacement(id)
    }

    package func retire(
        expectedRevision: UInt64
    ) async throws -> DatabaseBaseRecord {
        try await container.executionRetireBaseRecord(
            baseID,
            expectedRevision: expectedRevision
        )
    }

    package func activate(
        expectedRevision: UInt64
    ) async throws -> DatabaseBaseRecord {
        try await container.executionActivateBaseRecord(
            baseID,
            expectedRevision: expectedRevision,
            authorization: authorization
        )
    }

    package func prepareDeletion(
        expectedRevision: UInt64,
        owner: DatabaseTypes.ByteString
    ) async throws -> DatabaseBaseRecord {
        try await container.executionPrepareBaseDeletion(
            baseID,
            expectedRevision: expectedRevision,
            owner: owner
        )
    }

    package func clearForDeletion(
        owner: DatabaseTypes.ByteString
    ) async throws -> DatabaseBaseRecord {
        try await container.executionClearBaseForDeletion(
            baseID,
            owner: owner,
            authorization: authorization
        )
    }

    package func finishDeletion(
        owner: DatabaseTypes.ByteString
    ) async throws -> DatabaseBaseRecord {
        try await container.executionFinishBaseDeletion(
            baseID,
            owner: owner
        )
    }

    package func prepareUnsuccessfulDeletionRecovery(
        owner: DatabaseTypes.ByteString
    ) async throws -> DatabaseBaseRecord {
        try await container.executionPrepareUnsuccessfulBaseDeletionRecovery(
            baseID,
            owner: owner
        )
    }

    package func finalizeSuccessfulDeletion(
        owner: DatabaseTypes.ByteString,
        controlTransaction: any TransactionAccess
    ) async throws {
        try await container.executionFinalizeSuccessfulBaseDeletion(
            baseID,
            owner: owner,
            controlTransaction: controlTransaction
        )
    }

    package func finalizeUnsuccessfulDeletion(
        owner: DatabaseTypes.ByteString,
        controlTransaction: any TransactionAccess
    ) async throws {
        try await container.executionFinalizeUnsuccessfulBaseDeletion(
            baseID,
            owner: owner,
            controlTransaction: controlTransaction
        )
    }

    package func permitsDeletionFinalization(
        owner: DatabaseTypes.ByteString
    ) async throws -> Bool {
        try await container.executionPermitsBaseDeletionFinalization(
            baseID,
            owner: owner
        )
    }

    package func preparePlacementMove(
        destinationPlacementID: Base.Placement.ID,
        expectedRevision: UInt64,
        owner: DatabaseTypes.ByteString
    ) async throws -> DatabaseBasePlacementMoveDescriptor {
        try await container.executionPrepareBasePlacementMove(
            baseID,
            destinationPlacementID: destinationPlacementID,
            expectedRevision: expectedRevision,
            owner: owner
        )
    }

    package func copyPlacementBatch(
        _ descriptor: DatabaseBasePlacementMoveDescriptor,
        continuation: DatabaseTypes.ByteString?,
        digest: DatabaseTypes.ByteString?,
        keyCount: UInt64,
        byteCount: UInt64
    ) async throws -> DatabaseBasePlacementTransferProgress {
        try requireMatchingBase(descriptor)
        return try await container.executionCopyBasePlacementBatch(
            descriptor,
            continuation: continuation,
            digest: digest,
            keyCount: keyCount,
            byteCount: byteCount
        )
    }

    package func verifyPlacementBatch(
        _ descriptor: DatabaseBasePlacementMoveDescriptor,
        destination: Bool,
        continuation: DatabaseTypes.ByteString?,
        digest: DatabaseTypes.ByteString?,
        keyCount: UInt64,
        byteCount: UInt64
    ) async throws -> DatabaseBasePlacementTransferProgress {
        try requireMatchingBase(descriptor)
        return try await container.executionVerifyBasePlacementBatch(
            descriptor,
            destination: destination,
            continuation: continuation,
            digest: digest,
            keyCount: keyCount,
            byteCount: byteCount
        )
    }

    package func cutOverPlacementMove(
        _ descriptor: DatabaseBasePlacementMoveDescriptor
    ) async throws -> DatabaseBaseRecord {
        try requireMatchingBase(descriptor)
        return try await container.executionCutOverBasePlacementMove(
            descriptor
        )
    }

    package func finishPlacementMove(
        _ descriptor: DatabaseBasePlacementMoveDescriptor,
        owner: DatabaseTypes.ByteString
    ) async throws -> DatabaseBaseRecord {
        try requireMatchingBase(descriptor)
        return try await container.executionFinishBasePlacementMove(
            descriptor,
            owner: owner
        )
    }

    package func prepareUnsuccessfulPlacementMoveRecovery(
        _ descriptor: DatabaseBasePlacementMoveDescriptor,
        owner: DatabaseTypes.ByteString
    ) async throws -> DatabaseBaseRecord {
        try requireMatchingBase(descriptor)
        return try await container.executionPrepareUnsuccessfulBasePlacementMoveRecovery(
            descriptor,
            owner: owner
        )
    }

    package func finalizeSuccessfulPlacementMove(
        _ descriptor: DatabaseBasePlacementMoveDescriptor,
        owner: DatabaseTypes.ByteString,
        controlTransaction: any TransactionAccess
    ) async throws {
        try requireMatchingBase(descriptor)
        try await container.executionFinalizeSuccessfulBasePlacementMove(
            descriptor,
            owner: owner,
            controlTransaction: controlTransaction
        )
    }

    package func finalizeUnsuccessfulPlacementMove(
        _ descriptor: DatabaseBasePlacementMoveDescriptor,
        owner: DatabaseTypes.ByteString,
        controlTransaction: any TransactionAccess
    ) async throws {
        try requireMatchingBase(descriptor)
        try await container.executionFinalizeUnsuccessfulBasePlacementMove(
            descriptor,
            owner: owner,
            controlTransaction: controlTransaction
        )
    }

    private func requireMatchingBase(
        _ descriptor: DatabaseBasePlacementMoveDescriptor
    ) throws {
        guard descriptor.baseID == baseID else {
            throw DatabaseAdministrationError.targetMismatch(.base(baseID))
        }
    }

    #if DATABASE_OPERATIONS_GRAPH_INDEXES
    package func makeSPARQLQueryExecutor(
        datasetScanner: any RDFDatasetScanner,
        readMode: RDFDatasetReadMode,
        dataset: SPARQLExecutionDataset,
        functionRegistry: SPARQLFunctionRegistry
    ) throws -> SPARQLQueryExecutor {
        SPARQLQueryExecutor(
            database: try container.executionStorage().engine,
            monotonicClock: container.monotonicClock,
            wallClock: container.wallClock,
            datasetScanner: datasetScanner,
            readMode: readMode,
            dataset: dataset,
            functionRegistry: functionRegistry
        )
    }
    #endif
}
#endif
