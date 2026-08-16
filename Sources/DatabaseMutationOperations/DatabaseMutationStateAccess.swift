import DatabaseOperationCore
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import StorageKit

package struct DatabaseMutationStateAccess: Sendable {
    private let stateStore: DatabaseMutationStateStore

    package init(_ stateStore: DatabaseMutationStateStore) {
        self.stateStore = stateStore
    }

    package func replayEntry(
        for key: String,
        operation: DatabaseOperationIdentifier,
        requestDigest: ByteString,
        in binding: DatabaseMutationStateBinding,
        transaction: any TransactionAccess,
        limits: DatabaseWireLimits
    ) async throws -> DatabaseIdempotencyEntry? {
        guard let record = try await stateStore.replay(
            for: key,
            discriminator: DatabaseIdempotencyEntry.discriminator(
                for: operation
            ),
            requestFingerprint: requestDigest,
            in: binding,
            transaction: transaction,
            limits: try serverLimits(from: limits)
        ) else {
            return nil
        }
        return try DatabaseIdempotencyEntry.reconstruct(
            record: record,
            limits: limits
        )
    }

    package func idempotencyEntry(
        for key: String,
        in binding: DatabaseMutationStateBinding,
        transaction: any TransactionAccess,
        limits: DatabaseWireLimits
    ) async throws -> DatabaseIdempotencyEntry? {
        guard let record = try await stateStore.record(
            for: key,
            in: binding,
            transaction: transaction,
            limits: try serverLimits(from: limits)
        ) else {
            return nil
        }
        return try DatabaseIdempotencyEntry.reconstruct(
            record: record,
            limits: limits
        )
    }

    package func store(
        _ entry: DatabaseIdempotencyEntry,
        for key: String,
        in binding: DatabaseMutationStateBinding,
        transaction: any TransactionAccess,
        limits: DatabaseWireLimits
    ) throws {
        try stateStore.store(
            entry.replayRecord,
            for: key,
            in: binding,
            transaction: transaction,
            limits: try serverLimits(from: limits)
        )
    }

    #if DATABASE_SERVER_MULTIPLE_BASES
    package func binding(
        for target: DatabaseOperationTarget
    ) throws -> DatabaseMutationStateBinding {
        switch target {
        case .database:
            return stateStore.controlBinding()
        case .base:
            return stateStore.binding(
                for: try stateStore.boundContainer.executionStorage()
            )
        case .composition:
            throw DatabaseMutationError.featureUnavailable(
                "A Composition cannot own mutation state"
            )
        }
    }
    #else
    package func binding() -> DatabaseMutationStateBinding {
        stateStore.controlBinding()
    }
    #endif

    private func serverLimits(
        from wireLimits: DatabaseWireLimits
    ) throws -> DatabaseMutationStateLimits {
        try DatabaseMutationStateLimits(
            maximumKeyBytes: wireLimits.maximumStringBytes,
            maximumOutcomeBytes: wireLimits.maximumFrameBytes,
            maximumChunkCount: wireLimits.maximumCollectionCount
        )
    }
}
