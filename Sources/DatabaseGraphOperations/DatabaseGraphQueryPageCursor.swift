import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseOperationCore
#if DATABASE_GRAPH_OPERATIONS_ENABLED
import DatabaseTypes
import DatabaseKit
@_spi(DatabaseExecution) import DatabaseWire

package struct DatabaseGraphQueryPageCursor: Sendable, Hashable {
    package enum Kind: UInt8, Sendable, Hashable {
        case construct = 1
        case describe = 2
    }

    private static let formatVersion: UInt8 = 6

    package let kind: Kind
    #if DATABASE_SERVER_MULTIPLE_BASES
    package let resource: Security.Resource
    #endif
    package let dataGeneration: UInt64
    package let requestFingerprint: ByteString
    package let restorableReadPosition: DatabaseStorageReadPosition?
    package let resultFingerprint: ByteString
    package let tripleOffset: UInt64

    #if DATABASE_SERVER_MULTIPLE_BASES
    package init(
        kind: Kind,
        resource: Security.Resource,
        dataGeneration: UInt64,
        requestFingerprint: ByteString,
        restorableReadPosition: DatabaseStorageReadPosition?,
        resultFingerprint: ByteString,
        tripleOffset: UInt64
    ) {
        self.kind = kind
        self.resource = resource
        self.dataGeneration = dataGeneration
        self.requestFingerprint = requestFingerprint
        self.restorableReadPosition = restorableReadPosition
        self.resultFingerprint = resultFingerprint
        self.tripleOffset = tripleOffset
    }
    #else
    package init(
        kind: Kind,
        dataGeneration: UInt64,
        requestFingerprint: ByteString,
        restorableReadPosition: DatabaseStorageReadPosition?,
        resultFingerprint: ByteString,
        tripleOffset: UInt64
    ) {
        self.kind = kind
        self.dataGeneration = dataGeneration
        self.requestFingerprint = requestFingerprint
        self.restorableReadPosition = restorableReadPosition
        self.resultFingerprint = resultFingerprint
        self.tripleOffset = tripleOffset
    }
    #endif

    package func encode(limits: DatabaseWireLimits) throws -> ByteString {
        if case .opaque? = restorableReadPosition {
            throw DatabaseGraphQueryError.invalidContinuation
        }
        do {
            return try DatabaseWireWriter.encode(limits: limits) {
                (writer: inout DatabaseWireWriter) throws(DatabaseWireError) in
                writer.writeUInt8(Self.formatVersion)
                writer.writeUInt8(kind.rawValue)
                #if DATABASE_SERVER_MULTIPLE_BASES
                try Self.write(resource, to: &writer)
                #endif
                writer.writeUInt64(dataGeneration)
                try writer.writeBytes(requestFingerprint)
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
                try writer.writeBytes(resultFingerprint)
                writer.writeUInt64(tripleOffset)
            }
        } catch {
            throw DatabaseGraphQueryError.invalidContinuation
        }
    }

    package static func decode(
        _ bytes: ByteString,
        limits: DatabaseWireLimits
    ) throws -> Self {
        do {
            var reader = DatabaseWireReader(bytes, limits: limits)
            guard try reader.readUInt8() == Self.formatVersion,
                  let kind = Kind(rawValue: try reader.readUInt8()) else {
                throw DatabaseGraphQueryError.invalidContinuation
            }
            #if DATABASE_SERVER_MULTIPLE_BASES
            let resource = try Self.readResource(from: &reader)
            #endif
            let dataGeneration = try reader.readUInt64()
            let requestFingerprint = try reader.readBytes()
            let restorableReadPosition: DatabaseStorageReadPosition?
            switch try reader.readUInt8() {
            case 0:
                restorableReadPosition = nil
            case 1:
                restorableReadPosition = .version(try reader.readUInt64())
            default:
                throw DatabaseGraphQueryError.invalidContinuation
            }
            let resultFingerprint = try reader.readBytes()
            guard requestFingerprint.count == DatabaseRequestDigest.byteCount,
                  resultFingerprint.count == DatabaseRequestDigest.byteCount else {
                throw DatabaseGraphQueryError.invalidContinuation
            }
            let tripleOffset = try reader.readUInt64()
            guard tripleOffset > 0 else {
                throw DatabaseGraphQueryError.invalidContinuation
            }
            #if DATABASE_SERVER_MULTIPLE_BASES
            let result = Self(
                kind: kind,
                resource: resource,
                dataGeneration: dataGeneration,
                requestFingerprint: requestFingerprint,
                restorableReadPosition: restorableReadPosition,
                resultFingerprint: resultFingerprint,
                tripleOffset: tripleOffset
            )
            #else
            let result = Self(
                kind: kind,
                dataGeneration: dataGeneration,
                requestFingerprint: requestFingerprint,
                restorableReadPosition: restorableReadPosition,
                resultFingerprint: resultFingerprint,
                tripleOffset: tripleOffset
            )
            #endif
            try reader.ensureFullyRead()
            return result
        } catch let error as DatabaseGraphQueryError {
            throw error
        } catch {
            throw DatabaseGraphQueryError.invalidContinuation
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
            throw DatabaseGraphQueryError.invalidContinuation
        }
    }
    #endif
}

#endif
