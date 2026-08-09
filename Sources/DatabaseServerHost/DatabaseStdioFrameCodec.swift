import DatabaseTypes

public struct DatabaseStdioFrameCodec: Sendable, Hashable {
    public let maximumFrameBytes: Int

    public init(
        maximumFrameBytes: Int
    ) throws(DatabaseStdioFrameError) {
        guard maximumFrameBytes > 0,
              maximumFrameBytes <= Int(UInt32.max) else {
            throw .invalidMaximumFrameBytes
        }
        self.maximumFrameBytes = maximumFrameBytes
    }

    public func lengthPrefix(
        for payload: ByteString
    ) throws(DatabaseStdioFrameError) -> ByteString {
        guard !payload.isEmpty else {
            throw .zeroLengthFrame
        }
        guard payload.count <= maximumFrameBytes else {
            throw .frameTooLarge(
                actual: payload.count,
                maximum: maximumFrameBytes
            )
        }
        let length = UInt32(payload.count)
        return ByteString([
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ])
    }

    public func decodeLength(
        _ prefix: ByteString
    ) throws(DatabaseStdioFrameError) -> Int {
        guard prefix.count == 4 else {
            throw .truncatedLengthPrefix(actual: prefix.count)
        }
        let length = prefix.withUnsafeBytes { bytes in
            (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
        }
        guard length > 0 else {
            throw .zeroLengthFrame
        }
        guard length <= UInt32(maximumFrameBytes) else {
            throw .frameTooLarge(
                actual: Int(length),
                maximum: maximumFrameBytes
            )
        }
        return Int(length)
    }
}

public enum DatabaseStdioFrameError: Error, Sendable, Equatable {
    case invalidMaximumFrameBytes
    case truncatedLengthPrefix(actual: Int)
    case zeroLengthFrame
    case frameTooLarge(actual: Int, maximum: Int)
    case truncatedPayload(expected: Int, actual: Int)
}
