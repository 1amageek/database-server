import DatabaseOperationCore
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import Testing

@testable import DatabaseMutationOperations

@Suite("Database idempotency wire adapter")
struct DatabaseIdempotencyEntryTests {
    @Test("a mismatched outcome fingerprint is rejected")
    func rejectsOutcomeFingerprintMismatch() throws {
        let record = DatabaseMutationReplayRecord(
            discriminator: [
                UInt8(
                    truncatingIfNeeded:
                        DatabaseOperationIdentifier.mutationExecute.rawValue
                ),
                UInt8(
                    truncatingIfNeeded:
                        DatabaseOperationIdentifier.mutationExecute.rawValue >> 8
                ),
            ],
            requestFingerprint: ByteString(repeating: 1, count: 32),
            outcomeFingerprint: ByteString(repeating: 2, count: 32),
            outcome: [3]
        )

        do {
            _ = try DatabaseIdempotencyEntry.reconstruct(
                record: record,
                limits: .default
            )
            Issue.record("Expected a corrupted idempotency entry failure")
        } catch DatabaseMutationError.idempotencyEntryCorrupted {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("non-canonical wire fingerprint lengths are rejected")
    func rejectsNonCanonicalFingerprintLengths() throws {
        let record = DatabaseMutationReplayRecord(
            discriminator: [
                UInt8(
                    truncatingIfNeeded:
                        DatabaseOperationIdentifier.mutationExecute.rawValue
                ),
                UInt8(
                    truncatingIfNeeded:
                        DatabaseOperationIdentifier.mutationExecute.rawValue >> 8
                ),
            ],
            requestFingerprint: [1],
            outcomeFingerprint: [2],
            outcome: []
        )

        do {
            _ = try DatabaseIdempotencyEntry.reconstruct(
                record: record,
                limits: .default
            )
            Issue.record("Expected a corrupted idempotency entry failure")
        } catch DatabaseMutationError.idempotencyEntryCorrupted {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
