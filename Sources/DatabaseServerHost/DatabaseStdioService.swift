import DatabaseKit
import DatabaseServerRuntime
import DatabaseTypes
import NIOCore
import NIOPosix
import ServiceLifecycle

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class DatabaseStdioService: Service, Sendable {
    private let executor: any DatabaseServerRequestExecuting
    private let executionContext: DatabaseRequestExecutionContext
    private let maximumFrameBytes: Int
    private let inputDescriptor: CInt
    private let outputDescriptor: CInt

    public init(
        executor: any DatabaseServerRequestExecuting,
        authorization: AuthorizationContext,
        jobAuthorizationReference: DatabaseJobAuthorizationReference,
        maximumFrameBytes: Int,
        inputDescriptor: CInt = STDIN_FILENO,
        outputDescriptor: CInt = STDOUT_FILENO
    ) throws(DatabaseStdioFrameError) {
        _ = try DatabaseStdioFrameCodec(
            maximumFrameBytes: maximumFrameBytes
        )
        self.executor = executor
        self.executionContext = DatabaseRequestExecutionContext(
            authorization: authorization,
            jobAuthorizationReference: jobAuthorizationReference
        )
        self.maximumFrameBytes = maximumFrameBytes
        self.inputDescriptor = inputDescriptor
        self.outputDescriptor = outputDescriptor
    }

    public func run() async throws {
        do {
            let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer> = try await
                NIOPipeBootstrap(
                    group: MultiThreadedEventLoopGroup.singleton
                ).takingOwnershipOfDescriptors(
                    input: inputDescriptor,
                    output: outputDescriptor
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            ByteToMessageHandler(
                                DatabaseStdioFrameDecoder(
                                    maximumFrameBytes: self.maximumFrameBytes
                                )
                            )
                        )
                        return try NIOAsyncChannel(
                            wrappingChannelSynchronously: channel
                        )
                    }
                }
            try await channel.executeThenClose { inbound, outbound in
                for try await buffer in inbound {
                    let request = ByteString(retainingReadableBytes: buffer)
                    let response = try await executor.execute(
                        request,
                        context: executionContext
                    )
                    guard !response.isEmpty,
                          response.count <= maximumFrameBytes else {
                        throw DatabaseStdioFrameError.frameTooLarge(
                            actual: response.count,
                            maximum: maximumFrameBytes
                        )
                    }
                    try await outbound.write(framed(response))
                }
            }
            await executor.shutdown()
        } catch {
            await executor.shutdown()
            throw error
        }
    }

    private func framed(_ payload: ByteString) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(
            capacity: 4 + payload.count
        )
        buffer.writeInteger(
            UInt32(payload.count),
            endianness: .big
        )
        _ = payload.withUnsafeBytes { bytes in
            buffer.writeBytes(bytes)
        }
        return buffer
    }
}
