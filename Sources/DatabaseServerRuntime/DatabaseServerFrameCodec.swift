import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseEngine

/// A value persisted exclusively by the server runtime.
package protocol DatabaseServerFrameValue: Sendable {
    func encode(
        to encoder: inout DatabaseServerFrameEncoder
    ) throws(StorageFrameError)

    init(
        from decoder: inout DatabaseServerFrameDecoder
    ) throws(StorageFrameError)
}

/// Encodes and decodes bounded server-owned metadata frames.
package enum DatabaseServerFrameCodec {
    package static func encode<Value: DatabaseServerFrameValue>(
        _ value: Value,
        limits: StorageFrameLimits = .default
    ) throws(StorageFrameError) -> ByteString {
        try DatabaseServerFrameEncoder.encode(limits: limits) {
            (encoder: inout DatabaseServerFrameEncoder) throws(StorageFrameError) in
            try value.encode(to: &encoder)
        }
    }

    package static func decode<Value: DatabaseServerFrameValue>(
        _ type: Value.Type,
        from bytes: ByteString,
        limits: StorageFrameLimits = .default
    ) throws(StorageFrameError) -> Value {
        var decoder = try DatabaseServerFrameDecoder(bytes, limits: limits)
        let value = try Value(from: &decoder)
        try decoder.ensureFullyRead()
        return value
    }
}

/// Writes one exact-size server frame without an intermediate payload buffer.
package struct DatabaseServerFrameEncoder {
    private enum Destination {
        case measuring
        case fixed(UnsafeMutableRawBufferPointer)
    }

    package let limits: StorageFrameLimits
    private var destination: Destination
    private var offset: Int
    private var deferredError: StorageFrameError?

    private init(destination: Destination, limits: StorageFrameLimits) {
        self.destination = destination
        self.limits = limits
        self.offset = 0
        self.deferredError = nil
    }

    package static func encode(
        limits: StorageFrameLimits = .default,
        _ body: (inout DatabaseServerFrameEncoder) throws(StorageFrameError) -> Void
    ) throws(StorageFrameError) -> ByteString {
        var measurement = DatabaseServerFrameEncoder(
            destination: .measuring,
            limits: limits
        )
        try body(&measurement)
        try measurement.finish()
        let byteCount = measurement.offset
        guard byteCount <= limits.maximumFrameBytes else {
            throw .frameTooLarge(
                actual: byteCount,
                maximum: limits.maximumFrameBytes
            )
        }
        return try ByteString.copying(count: byteCount) {
            output throws(StorageFrameError) in
            var encoder = DatabaseServerFrameEncoder(
                destination: .fixed(output),
                limits: limits
            )
            try body(&encoder)
            try encoder.finish()
            guard encoder.offset == byteCount else {
                throw StorageFrameError.byteCountOverflow
            }
        }
    }

    package mutating func writeUInt8(_ value: UInt8) {
        appendByte(value)
    }

    package mutating func writeUInt32(_ value: UInt32) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { appendBytes($0) }
    }

    package mutating func writeUInt64(_ value: UInt64) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { appendBytes($0) }
    }

    package mutating func writeInt64(_ value: Int64) {
        writeUInt64(UInt64(bitPattern: value))
    }

    package mutating func writeCount(
        _ value: Int
    ) throws(StorageFrameError) {
        guard value <= limits.maximumCollectionCount else {
            throw .collectionTooLarge(
                actual: value,
                maximum: limits.maximumCollectionCount
            )
        }
        try writeLength(value)
    }

    package mutating func writeBytes(
        _ value: ByteString
    ) throws(StorageFrameError) {
        guard value.count <= limits.maximumByteStringBytes else {
            throw .byteStringTooLarge(
                actual: value.count,
                maximum: limits.maximumByteStringBytes
            )
        }
        try writeLength(value.count)
        value.withUnsafeBytes { appendBytes($0) }
    }

    package mutating func writeString(
        _ value: String
    ) throws(StorageFrameError) {
        let byteCount = value.utf8.count
        guard byteCount <= limits.maximumStringBytes else {
            throw .stringTooLarge(
                actual: byteCount,
                maximum: limits.maximumStringBytes
            )
        }
        try writeLength(byteCount)
        guard case .fixed = destination else {
            advance(by: byteCount)
            return
        }
        let emitted = value.utf8.withContiguousStorageIfAvailable {
            appendBytes(UnsafeRawBufferPointer($0))
            return true
        } ?? false
        if !emitted {
            for byte in value.utf8 {
                appendByte(byte)
            }
        }
    }

    package mutating func writeOptionalString(
        _ value: String?
    ) throws(StorageFrameError) {
        writeUInt8(value == nil ? 0 : 1)
        if let value {
            try writeString(value)
        }
    }

    private mutating func writeLength(
        _ value: Int
    ) throws(StorageFrameError) {
        guard value >= 0, let encoded = UInt32(exactly: value) else {
            throw .byteCountOverflow
        }
        writeUInt32(encoded)
    }

    private mutating func appendByte(_ value: UInt8) {
        var value = value
        withUnsafeBytes(of: &value) { appendBytes($0) }
    }

    private mutating func appendBytes(_ source: UnsafeRawBufferPointer) {
        guard deferredError == nil else { return }
        let nextOffset = offset.addingReportingOverflow(source.count)
        guard !nextOffset.overflow else {
            deferredError = .byteCountOverflow
            return
        }
        switch destination {
        case .measuring:
            offset = nextOffset.partialValue
        case .fixed(let output):
            guard offset <= output.count,
                  source.count <= output.count - offset else {
                deferredError = .byteCountOverflow
                return
            }
            UnsafeMutableRawBufferPointer(
                rebasing: output[offset..<nextOffset.partialValue]
            ).copyMemory(from: source)
            offset = nextOffset.partialValue
        }
    }

    private mutating func advance(by count: Int) {
        guard deferredError == nil else { return }
        let nextOffset = offset.addingReportingOverflow(count)
        guard !nextOffset.overflow else {
            deferredError = .byteCountOverflow
            return
        }
        offset = nextOffset.partialValue
    }

    private func finish() throws(StorageFrameError) {
        if let deferredError {
            throw deferredError
        }
    }
}

/// Decodes a server frame while retaining the original `ByteString` owner.
package struct DatabaseServerFrameDecoder: Sendable {
    private let bytes: ByteString
    private var offset: Int
    package let limits: StorageFrameLimits

    package init(
        _ bytes: ByteString,
        limits: StorageFrameLimits = .default
    ) throws(StorageFrameError) {
        guard bytes.count <= limits.maximumFrameBytes else {
            throw .frameTooLarge(
                actual: bytes.count,
                maximum: limits.maximumFrameBytes
            )
        }
        self.bytes = bytes
        self.offset = 0
        self.limits = limits
    }

    package var remainingCount: Int { bytes.count - offset }

    package mutating func readUInt8() throws(StorageFrameError) -> UInt8 {
        guard offset < bytes.count else { throw .truncated }
        let value = bytes[bytes.startIndex + offset]
        offset += 1
        return value
    }

    package mutating func readUInt32() throws(StorageFrameError) -> UInt32 {
        let payload = try readRawBytes(count: 4)
        return payload.withUnsafeBytes {
            UInt32($0[0])
                | (UInt32($0[1]) << 8)
                | (UInt32($0[2]) << 16)
                | (UInt32($0[3]) << 24)
        }
    }

    package mutating func readUInt64() throws(StorageFrameError) -> UInt64 {
        let payload = try readRawBytes(count: 8)
        return payload.withUnsafeBytes {
            UInt64($0[0])
                | (UInt64($0[1]) << 8)
                | (UInt64($0[2]) << 16)
                | (UInt64($0[3]) << 24)
                | (UInt64($0[4]) << 32)
                | (UInt64($0[5]) << 40)
                | (UInt64($0[6]) << 48)
                | (UInt64($0[7]) << 56)
        }
    }

    package mutating func readInt64() throws(StorageFrameError) -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    package mutating func readCount() throws(StorageFrameError) -> Int {
        let count = try readLength()
        guard count <= limits.maximumCollectionCount else {
            throw .collectionTooLarge(
                actual: count,
                maximum: limits.maximumCollectionCount
            )
        }
        return count
    }

    package mutating func readBytes() throws(StorageFrameError) -> ByteString {
        let count = try readLength()
        guard count <= limits.maximumByteStringBytes else {
            throw .byteStringTooLarge(
                actual: count,
                maximum: limits.maximumByteStringBytes
            )
        }
        return try readRawBytes(count: count)
    }

    package mutating func readString() throws(StorageFrameError) -> String {
        let count = try readLength()
        guard count <= limits.maximumStringBytes else {
            throw .stringTooLarge(
                actual: count,
                maximum: limits.maximumStringBytes
            )
        }
        let payload = try readRawBytes(count: count)
        guard let value = String(validating: payload, as: UTF8.self) else {
            throw .invalidUTF8
        }
        return value
    }

    package mutating func readOptionalString() throws(
        StorageFrameError
    ) -> String? {
        switch try readUInt8() {
        case 0:
            return nil
        case 1:
            return try readString()
        case let value:
            throw .invalidBool(value)
        }
    }

    package func ensureFullyRead() throws(StorageFrameError) {
        guard remainingCount == 0 else { throw .trailingBytes }
    }

    private mutating func readLength() throws(StorageFrameError) -> Int {
        guard let count = Int(exactly: try readUInt32()) else {
            throw .byteCountOverflow
        }
        return count
    }

    private mutating func readRawBytes(
        count: Int
    ) throws(StorageFrameError) -> ByteString {
        guard count >= 0, count <= bytes.count - offset else {
            throw .truncated
        }
        let lowerBound = bytes.startIndex + offset
        let upperBound = lowerBound + count
        offset += count
        return bytes[lowerBound..<upperBound]
    }
}
