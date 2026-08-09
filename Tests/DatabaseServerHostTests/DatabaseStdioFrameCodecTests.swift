import DatabaseTypes
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
