import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
import DatabaseKit
import DatabaseTypes
import StorageKit

/// Captures the strongest read point exposed by one concrete transaction.
/// Backends without versioned reads receive a transaction-lifetime opaque ID;
/// callers must not attempt to restore that ID in a later transaction.
enum DatabaseTransactionReadPoint {
    struct Value: Sendable, Hashable {
        let position: DatabaseStorageReadPosition
        #if DATABASE_SERVER_MULTIPLE_BASES
        let domainID: String

        init(position: DatabaseStorageReadPosition, domainID: String) {
            self.position = position
            self.domainID = domainID
        }

        var domainReadPoint: DomainReadPoint {
            get throws {
                let position: DomainReadPoint.Position = switch position {
                case .version(let version):
                    .version(version)
                case .opaque(let identifier):
                    .opaque(identifier)
                }
                return try DomainReadPoint(
                    domainID: domainID,
                    position: position
                )
            }
        }
        #else
        init(position: DatabaseStorageReadPosition) {
            self.position = position
        }
        #endif

        var restorableVersion: UInt64? {
            guard case .version(let version) = position else {
                return nil
            }
            return version
        }
    }

    enum Error: Swift.Error, Sendable {
        case invalidVersion(Int64)
    }

    static func capture(
        domainID: String,
        transaction: any TransactionAccess
    ) async throws -> Value {
        if transaction.capabilities.readVersion {
            let signedVersion = try await transaction.getReadVersion()
            guard let version = UInt64(exactly: signedVersion) else {
                throw Error.invalidVersion(signedVersion)
            }
            #if DATABASE_SERVER_MULTIPLE_BASES
            return Value(position: .version(version), domainID: domainID)
            #else
            return Value(position: .version(version))
            #endif
        }
        #if DATABASE_SERVER_MULTIPLE_BASES
        return Value(
            position: .opaque(makeOpaqueIdentifier()),
            domainID: domainID
        )
        #else
        return Value(position: .opaque(makeOpaqueIdentifier()))
        #endif
    }

    static func restore(
        _ position: DatabaseStorageReadPosition,
        transaction: any TransactionAccess
    ) throws -> Bool {
        switch position {
        case .version(let version):
            guard transaction.capabilities.historicalReadVersion,
                  let signedVersion = Int64(exactly: version) else {
                return false
            }
            try transaction.setReadVersion(signedVersion)
            return true
        case .opaque:
            return false
        }
    }

    private static func makeOpaqueIdentifier() -> ByteString {
        var generator = SystemRandomNumberGenerator()
        return ByteString((0..<32).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
    }
}
