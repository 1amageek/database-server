import DatabaseTypes
import Hummingbird

struct ByteBufferByteStringOwner: ByteStringOwner {
    let buffer: ByteBuffer

    var count: Int {
        buffer.readableBytes
    }

    var retainedByteCount: Int? {
        buffer.capacity
    }

    var isStorageSelfContained: Bool {
        buffer.readerIndex == 0 && buffer.readableBytes == buffer.capacity
    }

    func borrowBytes(
        _ body: (UnsafeRawBufferPointer) throws -> Void
    ) rethrows {
        try buffer.withUnsafeReadableBytes(body)
    }
}

extension ByteString {
    init(retainingReadableBytes buffer: ByteBuffer) {
        self.init(retaining: ByteBufferByteStringOwner(buffer: buffer))
    }

    func makeByteBuffer() -> ByteBuffer {
        // NIO must own the outbound storage after this synchronous borrow
        // ends. This is the single required response copy at the native
        // transport boundary; Wire execution retains ByteString ownership up
        // to this point without intermediate Data or Array materialization.
        var buffer = ByteBufferAllocator().buffer(capacity: count)
        _ = withUnsafeBytes { bytes in
            buffer.writeBytes(bytes)
        }
        return buffer
    }
}
