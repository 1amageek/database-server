import NIOCore

final class DatabaseStdioFrameDecoder: ByteToMessageDecoder {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let maximumFrameBytes: Int
    private var expectedPayloadBytes: Int?

    init(maximumFrameBytes: Int) {
        self.maximumFrameBytes = maximumFrameBytes
    }

    func decode(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer
    ) throws -> DecodingState {
        if expectedPayloadBytes == nil {
            guard buffer.readableBytes >= 4 else {
                return .needMoreData
            }
            guard let length = buffer.readInteger(
                endianness: .big,
                as: UInt32.self
            ) else {
                preconditionFailure("Four readable bytes must decode UInt32")
            }
            guard length > 0 else {
                throw DatabaseStdioFrameError.zeroLengthFrame
            }
            guard length <= UInt32(maximumFrameBytes) else {
                throw DatabaseStdioFrameError.frameTooLarge(
                    actual: Int(length),
                    maximum: maximumFrameBytes
                )
            }
            expectedPayloadBytes = Int(length)
        }
        guard let expectedPayloadBytes else {
            preconditionFailure("A decoded prefix must define a payload length")
        }
        guard buffer.readableBytes >= expectedPayloadBytes else {
            return .needMoreData
        }
        guard let payload = buffer.readSlice(length: expectedPayloadBytes) else {
            preconditionFailure("Readable payload must produce a buffer slice")
        }
        self.expectedPayloadBytes = nil
        context.fireChannelRead(Self.wrapInboundOut(payload))
        return .continue
    }

    func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        let state = try decode(context: context, buffer: &buffer)
        guard seenEOF else { return state }
        if let expectedPayloadBytes {
            throw DatabaseStdioFrameError.truncatedPayload(
                expected: expectedPayloadBytes,
                actual: buffer.readableBytes
            )
        }
        guard buffer.readableBytes == 0 else {
            throw DatabaseStdioFrameError.truncatedLengthPrefix(
                actual: buffer.readableBytes
            )
        }
        return state
    }
}
