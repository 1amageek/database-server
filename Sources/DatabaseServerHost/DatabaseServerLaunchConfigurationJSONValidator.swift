import Foundation

/// Rejects configuration keys that the native host does not understand.
///
/// `JSONDecoder` intentionally ignores unknown keys, which is unsafe for a
/// storage topology because a misspelled domain, placement, or credential
/// field could otherwise appear to have been accepted.
enum DatabaseServerLaunchConfigurationJSONValidator {
    static func validate(_ data: Data) throws {
        let value = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )
        let root = try object(value)
        #if DATABASE_SERVER_HOST_MULTI_BASE
        let rootKeys: Set<String> = [
                "formatVersion",
                "controlDomain",
                "domains",
                "placements",
                "defaultPlacement",
                "host",
                "port",
                "routing",
                "tokenRegistryPath",
                "tls",
                "maximumFrameBytes",
        ]
        #else
        let rootKeys: Set<String> = [
            "formatVersion",
            "storage",
            "databaseRoot",
            "host",
            "port",
            "routing",
            "tokenRegistryPath",
            "tls",
            "maximumFrameBytes",
        ]
        #endif
        try requireOnly(root, keys: rootKeys)

        #if DATABASE_SERVER_HOST_MULTI_BASE
        if let domains = root["domains"] as? [Any] {
            for value in domains {
                let domain = try object(value)
                try requireOnly(
                    domain,
                    keys: ["id", "namespace", "storage"]
                )
                if let storage = domain["storage"] {
                    try validateStorage(storage)
                }
            }
        }
        if let placements = root["placements"] as? [Any] {
            for value in placements {
                try requireOnly(
                    object(value),
                    keys: ["id", "domain", "path"]
                )
            }
        }
        #else
        if let storage = root["storage"] {
            try validateStorage(storage)
        }
        if let databaseRoot = root["databaseRoot"] {
            try requireOnly(
                object(databaseRoot),
                keys: ["kind", "path"]
            )
        }
        #endif
        if let routing = root["routing"] {
            try requireOnly(
                object(routing),
                keys: ["databaseID", "tenantID", "workspaceID"]
            )
        }
        if let tls = root["tls"], !(tls is NSNull) {
            try requireOnly(
                object(tls),
                keys: ["certificateChainPath", "privateKeyPath"]
            )
        }
    }

    private static func validateStorage(_ value: Any) throws {
        let storage = try object(value)
        try requireOnly(
            storage,
            keys: ["kind", "sqlite", "postgresql", "foundationdb"]
        )
        if let sqlite = storage["sqlite"], !(sqlite is NSNull) {
            try requireOnly(
                object(sqlite),
                keys: ["mode", "path"]
            )
        }
        if let postgreSQL = storage["postgresql"],
           !(postgreSQL is NSNull) {
            try requireOnly(
                object(postgreSQL),
                keys: [
                    "host",
                    "port",
                    "unixSocketPath",
                    "username",
                    "passwordFilePath",
                    "database",
                    "tls",
                    "tableName",
                    "schemaManagement",
                ]
            )
        }
        if let foundationDB = storage["foundationdb"],
           !(foundationDB is NSNull) {
            try requireOnly(
                object(foundationDB),
                keys: ["clusterFilePath"]
            )
        }
    }

    private static func object(
        _ value: Any
    ) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw DatabaseServerLaunchConfigurationError.invalidDocument
        }
        return object
    }

    private static func requireOnly(
        _ object: [String: Any],
        keys: Set<String>
    ) throws {
        guard Set(object.keys).isSubset(of: keys) else {
            throw DatabaseServerLaunchConfigurationError.invalidDocument
        }
    }
}
