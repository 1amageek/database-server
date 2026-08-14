import DatabaseOperationCore
import DatabaseTypes
import DatabaseKit
@_spi(DatabaseExecution) import DatabaseWire

package struct DatabaseQueryPageCursor: Sendable, Hashable {
    private static let formatVersion: UInt8 = 6

    #if DATABASE_SERVER_MULTIPLE_BASES
    package let resource: Security.Resource
    #endif
    package let restorableReadPosition: DatabaseStorageReadPosition?
    package let dataGeneration: UInt64
    package let continuation: ByteString

    #if DATABASE_SERVER_MULTIPLE_BASES
    package init(
        resource: Security.Resource,
        restorableReadPosition: DatabaseStorageReadPosition?,
        dataGeneration: UInt64,
        continuation: ByteString
    ) {
        self.resource = resource
        self.restorableReadPosition = restorableReadPosition
        self.dataGeneration = dataGeneration
        self.continuation = continuation
    }
    #else
    package init(
        restorableReadPosition: DatabaseStorageReadPosition?,
        dataGeneration: UInt64,
        continuation: ByteString
    ) {
        self.restorableReadPosition = restorableReadPosition
        self.dataGeneration = dataGeneration
        self.continuation = continuation
    }
    #endif

    package func encode(limits: DatabaseWireLimits) throws -> ByteString {
        if case .opaque? = restorableReadPosition {
            throw DatabaseQueryExecutionError.invalidContinuation
        }
        do {
            return try DatabaseWireWriter.encode(limits: limits) {
                (writer: inout DatabaseWireWriter) throws(DatabaseWireError) in
                writer.writeUInt8(Self.formatVersion)
                #if DATABASE_SERVER_MULTIPLE_BASES
                try Self.write(resource, to: &writer)
                #endif
                switch restorableReadPosition {
                case nil:
                    writer.writeUInt8(0)
                case .version(let version):
                    writer.writeUInt8(1)
                    writer.writeUInt64(version)
                case .opaque:
                    preconditionFailure(
                        "Opaque read positions are not restorable"
                    )
                }
                writer.writeUInt64(dataGeneration)
                try writer.writeBytes(continuation)
            }
        } catch {
            throw DatabaseQueryExecutionError.invalidContinuation
        }
    }

    package static func decode(
        _ bytes: ByteString,
        limits: DatabaseWireLimits
    ) throws -> Self {
        do {
            var reader = DatabaseWireReader(bytes, limits: limits)
            guard try reader.readUInt8() == Self.formatVersion else {
                throw DatabaseQueryExecutionError.invalidContinuation
            }
            #if DATABASE_SERVER_MULTIPLE_BASES
            let resource = try Self.readResource(from: &reader)
            #endif
            let restorableReadPosition: DatabaseStorageReadPosition?
            switch try reader.readUInt8() {
            case 0:
                restorableReadPosition = nil
            case 1:
                restorableReadPosition = .version(try reader.readUInt64())
            default:
                throw DatabaseQueryExecutionError.invalidContinuation
            }
            let dataGeneration = try reader.readUInt64()
            let continuation = try reader.readBytes()
            guard !continuation.isEmpty else {
                throw DatabaseQueryExecutionError.invalidContinuation
            }
            try reader.ensureFullyRead()
            #if DATABASE_SERVER_MULTIPLE_BASES
            return Self(
                resource: resource,
                restorableReadPosition: restorableReadPosition,
                dataGeneration: dataGeneration,
                continuation: continuation
            )
            #else
            return Self(
                restorableReadPosition: restorableReadPosition,
                dataGeneration: dataGeneration,
                continuation: continuation
            )
            #endif
        } catch let error as DatabaseQueryExecutionError {
            throw error
        } catch {
            throw DatabaseQueryExecutionError.invalidContinuation
        }
    }

    #if DATABASE_SERVER_MULTIPLE_BASES
    private static func write(
        _ resource: Security.Resource,
        to writer: inout DatabaseWireWriter
    ) throws(DatabaseWireError) {
        switch resource {
        case .database:
            writer.writeUInt8(0)
        case .base(let id):
            writer.writeUInt8(1)
            try writer.writeString(id.value)
        }
    }

    private static func readResource(
        from reader: inout DatabaseWireReader
    ) throws -> Security.Resource {
        switch try reader.readUInt8() {
        case 0:
            return .database
        case 1:
            return .base(try Base.ID(reader.readString()))
        default:
            throw DatabaseQueryExecutionError.invalidContinuation
        }
    }
    #endif
}
