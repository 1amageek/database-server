import DatabaseKit
import DatabaseTypes
import DatabaseWire
import NIOCore
@testable import DatabaseServerHost
import Testing

@Suite("Database stdio frame codec")
struct DatabaseStdioFrameCodecTests {
    @Test("Length prefix is UInt32 big-endian")
    func bigEndianLengthPrefix() throws {
        let codec = try DatabaseStdioFrameCodec(maximumFrameBytes: 1_024)
        let prefix = try codec.lengthPrefix(
            for: ByteString(repeating: 0, count: 258)
        )

        #expect(prefix == ByteString([0, 0, 1, 2]))
        #expect(try codec.decodeLength(prefix) == 258)

        let valueLimits = QueryValueLimits(maximumRetainedBytes: 1_024 * 1_024,
                                          maximumTotalNodes: 1_000, maximumNestingDepth: 16,
                                          maximumCollectionElements: 1_000)
        let json = try QueryJSONValue(bytes: ByteString(Array("{\"value\":1}".utf8)), limits: valueLimits)
        let request = QueryExecuteOperation.Request(
            input: .text(language: .sql, statement: "SELECT :value"),
            parameters: [QueryParameter(position: 1, name: "value", value: .json(json), type: .sql(.json))]
        )
        #if MultiBase
        let frame = try DatabaseWireEncoder().encodeRequest(
            DatabaseOperationCatalog.queryExecute, requestID: 77, target: .database, request: request
        )
        #else
        let frame = try DatabaseWireEncoder().encodeRequest(
            DatabaseOperationCatalog.queryExecute, requestID: 77, request: request
        )
        #endif
        var inbound = ByteBufferAllocator().buffer(capacity: 32 * 1_024)
        inbound.writeInteger(UInt32(frame.count), endianness: .big)
        _ = frame.withUnsafeBytes { inbound.writeBytes($0) }
        let rootCapacity = inbound.storageCapacity
        let decoder = DatabaseStdioFrameDecoder(maximumFrameBytes: rootCapacity)
        let decodedPayload = try decoder.decodeFrame(buffer: &inbound)
        let payload = try #require(decodedPayload)
        #expect(payload.capacity == frame.count)
        #expect(payload.storageCapacity == rootCapacity)
        #expect(rootCapacity > payload.capacity)
        #expect(inbound.readableBytes == 0)
        let owner = ByteBufferByteStringOwner(buffer: payload)
        #expect(owner.retainedByteCount == rootCapacity)
        #expect(!owner.isStorageSelfContained)
        let retained = ByteString(retainingReadableBytes: payload)
        inbound = ByteBuffer()
        #expect(retained == frame)
        #expect(retained.retainedByteCount == rootCapacity)
        #expect(!retained.isStorageSelfContained)

        func limits(maximumFrameBytes: Int) throws -> DatabaseWireLimits {
            try DatabaseWireLimits(
                maximumFrameBytes: maximumFrameBytes,
                maximumStringBytes: 1_024, maximumByteStringBytes: 1_024,
                maximumCollectionCount: 100, maximumNestingDepth: 16,
                maximumObjectCount: 100
            )
        }
        #expect(throws: DatabaseWireError.invalidQueryValue(.resourceLimit(
            resource: "rootRetainedBytes", actual: UInt64(rootCapacity), maximum: UInt64(frame.count)
        ))) {
            try DatabaseWireDecoder(limits: limits(maximumFrameBytes: frame.count)).decodeRequest(
                DatabaseOperationCatalog.queryExecute, from: retained
            )
        }
        let accepted = try DatabaseWireDecoder(limits: limits(maximumFrameBytes: rootCapacity)).decodeRequest(
            DatabaseOperationCatalog.queryExecute, from: retained
        )
        #expect(accepted.request.parameters == request.parameters)
    }

    @Test("Zero, oversized, and truncated frames fail explicitly")
    func invalidFrames() throws {
        let codec = try DatabaseStdioFrameCodec(maximumFrameBytes: 4)

        #expect(throws: DatabaseStdioFrameError.zeroLengthFrame) {
            _ = try codec.lengthPrefix(for: ByteString())
        }
        #expect(
            throws: DatabaseStdioFrameError.frameTooLarge(
                actual: 5,
                maximum: 4
            )
        ) {
            _ = try codec.lengthPrefix(
                for: ByteString(repeating: 0, count: 5)
            )
        }
        #expect(
            throws: DatabaseStdioFrameError.truncatedLengthPrefix(actual: 3)
        ) {
            _ = try codec.decodeLength(ByteString([0, 0, 1]))
        }
        #expect(throws: DatabaseStdioFrameError.zeroLengthFrame) {
            _ = try codec.decodeLength(ByteString([0, 0, 0, 0]))
        }
    }
}
