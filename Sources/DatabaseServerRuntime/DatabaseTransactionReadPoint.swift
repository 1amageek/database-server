import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes
import StorageKit

/// Captures the strongest read point exposed by one concrete transaction.
/// Backends without versioned reads receive a transaction-lifetime opaque ID;
/// callers must not attempt to restore that ID in a later transaction.
enum DatabaseTransactionReadPoint {
    struct Value: Sendable, Hashable {
        let position: DatabaseStorageReadPosition
        #if DATABASE_SERVER_MULTI_BASE
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

    static func value(
        domainID: String,
        snapshot: DatabaseReadSnapshot
    ) -> Value {
        let position = storagePosition(snapshot.position)
        #if DATABASE_SERVER_MULTI_BASE
        return Value(position: position, domainID: domainID)
        #else
        return Value(position: position)
        #endif
    }

    private static func storagePosition(
        _ position: DatabaseReadPosition
    ) -> DatabaseStorageReadPosition {
        switch position {
        case .version(let version):
            return .version(version)
        case .opaque(let identifier):
            return .opaque(identifier)
        }
    }
}
