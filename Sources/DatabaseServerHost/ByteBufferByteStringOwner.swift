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
        var buffer = ByteBufferAllocator().buffer(capacity: count)
        _ = withUnsafeBytes { bytes in
            buffer.writeBytes(bytes)
        }
        return buffer
    }
}
