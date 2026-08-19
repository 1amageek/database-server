import DatabaseKit
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseEngine
@_spi(DatabaseExecution) import DatabaseWire

/// Durable identity of one server-owned online schema transition.
package struct DatabaseSchemaApplicationRecord:
    Sendable,
    Hashable,
    DatabaseServerFrameValue
{
    package let idempotencyKey: String
    package let expectedFingerprint: SchemaFingerprint
    package let targetFingerprint: SchemaFingerprint
    package let job: JobIdentity

    package init(
        idempotencyKey: String,
        expectedFingerprint: SchemaFingerprint,
        targetFingerprint: SchemaFingerprint,
        job: JobIdentity
    ) {
        self.idempotencyKey = idempotencyKey
        self.expectedFingerprint = expectedFingerprint
        self.targetFingerprint = targetFingerprint
        self.job = job
    }

    package func encode(
        to encoder: inout DatabaseServerFrameEncoder
    ) throws(StorageFrameError) {
        try encoder.writeString(idempotencyKey)
        try encoder.writeBytes(expectedFingerprint.bytes)
        try encoder.writeBytes(targetFingerprint.bytes)
        encoder.writeUInt64(job.jobID.high)
        encoder.writeUInt64(job.jobID.low)
        encoder.writeUInt32(UInt32(job.operation.family.rawValue))
        try encoder.writeString(job.operation.kind)
        #if DATABASE_SERVER_MULTI_BASE
        guard job.target == .database else { throw .invalidValue }
        #endif
    }

    package init(
        from decoder: inout DatabaseServerFrameDecoder
    ) throws(StorageFrameError) {
        do {
            let idempotencyKey = try decoder.readString()
            let expectedFingerprint = try SchemaFingerprint(
                decoder.readBytes()
            )
            let targetFingerprint = try SchemaFingerprint(
                decoder.readBytes()
            )
            let jobID = DatabaseTypes.UUID(
                high: try decoder.readUInt64(),
                low: try decoder.readUInt64()
            )
            guard !idempotencyKey.isEmpty,
                  let rawFamily = UInt16(exactly: try decoder.readUInt32()),
                  let family = DatabaseOperationIdentifier(rawValue: rawFamily)
            else {
                throw StorageFrameError.invalidValue
            }
            let operation = try JobOperationIdentifier(
                family: family,
                kind: decoder.readString()
            )
            #if DATABASE_SERVER_MULTI_BASE
            let job = JobIdentity(
                jobID: jobID,
                operation: operation,
                target: .database
            )
            #else
            let job = JobIdentity(jobID: jobID, operation: operation)
            #endif
            self.init(
                idempotencyKey: idempotencyKey,
                expectedFingerprint: expectedFingerprint,
                targetFingerprint: targetFingerprint,
                job: job
            )
        } catch let error as StorageFrameError {
            throw error
        } catch {
            throw .invalidValue
        }
    }
}
