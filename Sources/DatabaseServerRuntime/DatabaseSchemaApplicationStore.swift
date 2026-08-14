import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
@_spi(DatabaseExecution) import DatabaseEngine
import StorageKit

/// Serializes server-owned online schema transitions in control storage.
package struct DatabaseSchemaApplicationStore: Sendable {
    private let applications: Subspace
    private let activeKey: ByteString

    package init(controlRoot: Subspace) {
        let root = controlRoot
            .subspace("_metadata")
            .subspace("schema")
            .subspace("applications")
        self.applications = root.subspace("records")
        self.activeKey = root.pack(Tuple("active"))
    }

    package func load(
        idempotencyKey: String,
        transaction: any TransactionAccess
    ) async throws -> DatabaseSchemaApplicationRecord? {
        try await load(
            key: applications.pack(Tuple(idempotencyKey)),
            transaction: transaction
        )
    }

    package func insert(
        _ record: DatabaseSchemaApplicationRecord,
        transaction: any TransactionAccess
    ) async throws {
        guard !record.idempotencyKey.isEmpty else {
            throw DatabaseSchemaPublicationError.invalidIdempotencyKey
        }
        if let existing = try await load(
            idempotencyKey: record.idempotencyKey,
            transaction: transaction
        ) {
            guard existing.expectedFingerprint == record.expectedFingerprint,
                  existing.targetFingerprint == record.targetFingerprint else {
                throw DatabaseSchemaPublicationError.idempotencyKeyReused(
                    record.idempotencyKey
                )
            }
            guard existing.job == record.job else {
                throw DatabaseSchemaPublicationError.corruptedState(
                    "schema application identity changed"
                )
            }
            return
        }
        if try await load(key: activeKey, transaction: transaction) != nil {
            throw DatabaseSchemaPublicationError.transitionInProgress
        }
        let encoded = try DatabaseServerFrameCodec.encode(record)
        try transaction.setValue(
            encoded,
            for: applications.pack(Tuple(record.idempotencyKey))
        )
        try transaction.setValue(encoded, for: activeKey)
    }

    package func finish(
        job: JobIdentity,
        transaction: any TransactionAccess
    ) async throws {
        guard let active = try await load(
            key: activeKey,
            transaction: transaction
        ) else {
            return
        }
        guard active.job == job else {
            throw DatabaseSchemaPublicationError.corruptedState(
                "active schema transition is owned by another job"
            )
        }
        try transaction.clear(key: activeKey)
    }

    private func load(
        key: ByteString,
        transaction: any TransactionAccess
    ) async throws -> DatabaseSchemaApplicationRecord? {
        guard let bytes = try await transaction.getValue(
            for: key,
            snapshot: false
        ) else {
            return nil
        }
        do {
            return try DatabaseServerFrameCodec.decode(
                DatabaseSchemaApplicationRecord.self,
                from: bytes
            )
        } catch {
            throw DatabaseSchemaPublicationError.corruptedState(
                "schema application record cannot be decoded"
            )
        }
    }
}
