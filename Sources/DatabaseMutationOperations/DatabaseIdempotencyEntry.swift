import DatabaseOperationCore
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire

package struct DatabaseIdempotencyEntry: Sendable, Hashable {
    package let operation: DatabaseOperationIdentifier
    package let requestDigest: ByteString
    package let responseDigest: ByteString
    package let responsePayload: ByteString

    package init(
        operation: DatabaseOperationIdentifier,
        requestDigest: ByteString,
        responseDigest: ByteString,
        responsePayload: ByteString
    ) {
        self.operation = operation
        self.requestDigest = requestDigest
        self.responseDigest = responseDigest
        self.responsePayload = responsePayload
    }

    var replayRecord: DatabaseMutationReplayRecord {
        DatabaseMutationReplayRecord(
            discriminator: Self.discriminator(for: operation),
            requestFingerprint: requestDigest,
            outcomeFingerprint: responseDigest,
            outcome: responsePayload
        )
    }

    static func reconstruct(
        record: DatabaseMutationReplayRecord,
        limits: DatabaseWireLimits
    ) throws -> Self {
        guard record.outcome.count <= limits.maximumFrameBytes,
              record.requestFingerprint.count == DatabaseRequestDigest.byteCount,
              record.outcomeFingerprint.count == DatabaseRequestDigest.byteCount,
              let operation = operation(from: record.discriminator),
              record.outcomeFingerprint == DatabaseRequestDigest.compute(
                  operation: operation,
                  payload: record.outcome
              ) else {
            throw DatabaseMutationError.idempotencyEntryCorrupted
        }
        return Self(
            operation: operation,
            requestDigest: record.requestFingerprint,
            responseDigest: record.outcomeFingerprint,
            responsePayload: record.outcome
        )
    }

    package static func discriminator(
        for operation: DatabaseOperationIdentifier
    ) -> ByteString {
        ByteString([
            UInt8(truncatingIfNeeded: operation.rawValue),
            UInt8(truncatingIfNeeded: operation.rawValue >> 8),
        ])
    }

    private static func operation(
        from discriminator: ByteString
    ) -> DatabaseOperationIdentifier? {
        guard discriminator.count == 2 else { return nil }
        let rawValue = UInt16(discriminator[discriminator.startIndex])
            | UInt16(discriminator[discriminator.startIndex + 1]) << 8
        return DatabaseOperationIdentifier(rawValue: rawValue)
    }
}
