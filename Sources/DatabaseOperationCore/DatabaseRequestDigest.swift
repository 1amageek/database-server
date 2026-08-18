import DatabaseKit
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire

public enum DatabaseRequestDigest {
    public static let byteCount = 32

    #if DATABASE_SERVER_MULTIPLE_BASES
    public static func computeRequest(
        operation: DatabaseOperationIdentifier,
        target: DatabaseOperationTarget,
        prefix: ByteString = [],
        payload: ByteString
    ) -> ByteString {
        var accumulator = DatabaseRequestDigestAccumulator(
            operation: operation
        )
        switch target {
        case .database:
            accumulator.update(bigEndian: 0)
        case .base(let baseID):
            accumulator.update(bigEndian: 1)
            accumulator.update(bigEndian: UInt64(baseID.value.utf8.count))
            accumulator.update(utf8: baseID.value)
        case .composition(let selection):
            accumulator.update(bigEndian: 2)
            switch selection.kind {
            case .named:
                accumulator.update(bigEndian: 0)
                guard let id = selection.namedID else {
                    preconditionFailure(
                        "Named Composition selection is missing its identifier"
                    )
                }
                accumulator.update(
                    bigEndian: UInt64(id.value.utf8.count)
                )
                accumulator.update(utf8: id.value)
            case .derived:
                accumulator.update(bigEndian: 1)
                guard let bases = selection.bases else {
                    preconditionFailure(
                        "Derived Composition selection is missing its Bases"
                    )
                }
                accumulator.update(bigEndian: UInt64(bases.count))
                for baseID in bases {
                    accumulator.update(
                        bigEndian: UInt64(baseID.value.utf8.count)
                    )
                    accumulator.update(utf8: baseID.value)
                }
            }
        }
        accumulator.update(prefix)
        accumulator.update(payload)
        return accumulator.finalize()
    }
    #endif

    package static func compute(
        operation: DatabaseOperationIdentifier,
        prefix: ByteString = [],
        payload: ByteString
    ) -> ByteString {
        var accumulator = DatabaseRequestDigestAccumulator(
            operation: operation
        )
        accumulator.update(prefix)
        accumulator.update(payload)
        return accumulator.finalize()
    }

    package static func compute(
        jobOperation: JobOperationIdentifier,
        prefix: ByteString = [],
        payload: ByteString
    ) -> ByteString {
        var accumulator = DatabaseRequestDigestAccumulator(
            jobOperation: jobOperation
        )
        accumulator.update(prefix)
        accumulator.update(payload)
        return accumulator.finalize()
    }
}
