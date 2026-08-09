import DatabaseWire
import Foundation

public struct DatabaseServerLaunchConfiguration: Codable, Sendable {
    public struct Storage: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case sqlite
            case postgreSQL = "postgresql"
            case foundationDB = "foundationdb"
        }

        public struct SQLite: Codable, Sendable, Equatable {
            public enum Mode: String, Codable, Sendable {
                case memory
                case file
            }

            public let mode: Mode
            public let path: String?

            public init(mode: Mode, path: String? = nil) {
                self.mode = mode
                self.path = path
            }
        }

        public struct PostgreSQL: Codable, Sendable, Equatable {
            public enum TLSMode: String, Codable, Sendable {
                case disable
                case require
            }

            public enum SchemaManagement: String, Codable, Sendable {
                case createIfNeeded = "create-if-needed"
                case assumeExists = "assume-exists"
            }

            public let host: String?
            public let port: Int
            public let unixSocketPath: String?
            public let username: String
            public let passwordFilePath: String?
            public let database: String
            public let tls: TLSMode
            public let tableName: String
            public let schemaManagement: SchemaManagement

            public init(
                host: String? = nil,
                port: Int = 5_432,
                unixSocketPath: String? = nil,
                username: String,
                passwordFilePath: String? = nil,
                database: String,
                tls: TLSMode = .disable,
                tableName: String = "kv_store",
                schemaManagement: SchemaManagement = .createIfNeeded
            ) {
                self.host = host
                self.port = port
                self.unixSocketPath = unixSocketPath
                self.username = username
                self.passwordFilePath = passwordFilePath
                self.database = database
                self.tls = tls
                self.tableName = tableName
                self.schemaManagement = schemaManagement
            }
        }

        public struct FoundationDB: Codable, Sendable, Equatable {
            public let clusterFilePath: String

            public init(clusterFilePath: String) {
                self.clusterFilePath = clusterFilePath
            }
        }

        public let kind: Kind
        public let sqlite: SQLite?
        public let postgreSQL: PostgreSQL?
        public let foundationDB: FoundationDB?

        private enum CodingKeys: String, CodingKey {
            case kind
            case sqlite
            case postgreSQL = "postgresql"
            case foundationDB = "foundationdb"
        }

        public init(sqlite: SQLite) {
            self.kind = .sqlite
            self.sqlite = sqlite
            self.postgreSQL = nil
            self.foundationDB = nil
        }

        public init(postgreSQL: PostgreSQL) {
            self.kind = .postgreSQL
            self.sqlite = nil
            self.postgreSQL = postgreSQL
            self.foundationDB = nil
        }

        public init(foundationDB: FoundationDB) {
            self.kind = .foundationDB
            self.sqlite = nil
            self.postgreSQL = nil
            self.foundationDB = foundationDB
        }

        public func runtimeStorage() throws
            -> NativeDatabaseStorageConfiguration
        {
            let payloadCount = [
                sqlite != nil,
                postgreSQL != nil,
                foundationDB != nil,
            ].filter { $0 }.count
            guard payloadCount == 1 else {
                throw DatabaseServerLaunchConfigurationError
                    .storageConfigurationMismatch
            }
            switch kind {
            case .sqlite:
                guard let sqlite,
                      postgreSQL == nil,
                      foundationDB == nil else {
                    throw DatabaseServerLaunchConfigurationError
                        .storageConfigurationMismatch
                }
                switch sqlite.mode {
                case .memory:
                    guard sqlite.path == nil else {
                        throw DatabaseServerLaunchConfigurationError
                            .sqliteMemoryHasPath
                    }
                    return .sqliteMemory
                case .file:
                    guard let path = sqlite.path, !path.isEmpty else {
                        throw DatabaseServerLaunchConfigurationError
                            .sqliteFileMissingPath
                    }
                    return .sqliteFile(path: path)
                }
            case .postgreSQL:
                guard sqlite == nil,
                      let postgreSQL,
                      foundationDB == nil else {
                    throw DatabaseServerLaunchConfigurationError
                        .storageConfigurationMismatch
                }
                return try postgreSQL.validated()
            case .foundationDB:
                guard sqlite == nil,
                      postgreSQL == nil,
                      let foundationDB,
                      !foundationDB.clusterFilePath.isEmpty else {
                    throw DatabaseServerLaunchConfigurationError
                        .invalidFoundationDBConfiguration
                }
                return .foundationDB(
                    clusterFilePath: foundationDB.clusterFilePath
                )
            }
        }
    }

    public struct Routing: Codable, Sendable {
        public let databaseID: String
        public let tenantID: String?
        public let workspaceID: String?

        public init(
            databaseID: String,
            tenantID: String? = nil,
            workspaceID: String? = nil
        ) {
            self.databaseID = databaseID
            self.tenantID = tenantID
            self.workspaceID = workspaceID
        }
    }

    public struct TLS: Codable, Sendable {
        public let certificateChainPath: String
        public let privateKeyPath: String

        public init(certificateChainPath: String, privateKeyPath: String) {
            self.certificateChainPath = certificateChainPath
            self.privateKeyPath = privateKeyPath
        }
    }

    public let formatVersion: Int
    public let storage: Storage
    public let host: String
    public let port: Int
    public let routing: Routing
    public let tokenRegistryPath: String
    public let tls: TLS?
    public let maximumFrameBytes: Int?

    public init(
        formatVersion: Int = 1,
        storage: Storage,
        host: String = "127.0.0.1",
        port: Int = 7_878,
        routing: Routing,
        tokenRegistryPath: String,
        tls: TLS? = nil,
        maximumFrameBytes: Int? = nil
    ) {
        self.formatVersion = formatVersion
        self.storage = storage
        self.host = host
        self.port = port
        self.routing = routing
        self.tokenRegistryPath = tokenRegistryPath
        self.tls = tls
        self.maximumFrameBytes = maximumFrameBytes
    }

    public static func load(
        from url: URL
    ) throws -> DatabaseServerLaunchConfiguration {
        let configuration: DatabaseServerLaunchConfiguration
        do {
            configuration = try JSONDecoder().decode(
                DatabaseServerLaunchConfiguration.self,
                from: DatabaseServerConfigurationFile.read(from: url)
            )
        } catch {
            throw DatabaseServerLaunchConfigurationError.invalidDocument
        }
        try configuration.validate()
        return configuration
    }

    public func create(at url: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try DatabaseServerConfigurationFile.create(
                encoder.encode(self),
                at: url
            )
        } catch let error as DatabaseServerLaunchConfigurationError {
            throw error
        } catch {
            throw DatabaseServerLaunchConfigurationError
                .configurationWriteFailed
        }
    }

    public func runtimeStorage()
        throws -> NativeDatabaseStorageConfiguration
    {
        try storage.runtimeStorage()
    }

    public func routingIdentity() throws -> DatabaseServerRoutingIdentity {
        try DatabaseServerRoutingIdentity(
            databaseID: routing.databaseID,
            tenantID: routing.tenantID,
            workspaceID: routing.workspaceID
        )
    }

    public func hostConfiguration(
        host overrideHost: String? = nil,
        port overridePort: Int? = nil
    )
        throws -> DatabaseServerHostConfiguration
    {
        let tlsConfiguration = tls.map {
            DatabaseServerTLSConfiguration(
                certificateChainURL: URL(
                    fileURLWithPath: $0.certificateChainPath
                ),
                privateKeyURL: URL(fileURLWithPath: $0.privateKeyPath)
            )
        }
        return try DatabaseServerHostConfiguration(
            host: overrideHost ?? host,
            port: overridePort ?? port,
            routingIdentity: routingIdentity(),
            tls: tlsConfiguration,
            maximumFrameBytes: maximumFrameBytes
                ?? DatabaseWireLimits.default.maximumFrameBytes,
            hasAuthenticator: true
        )
    }

    public var tokenRegistryURL: URL {
        URL(fileURLWithPath: tokenRegistryPath)
    }

    private func validate() throws {
        guard formatVersion == 1 else {
            throw DatabaseServerLaunchConfigurationError
                .unsupportedFormatVersion(formatVersion)
        }
        guard !tokenRegistryPath.isEmpty else {
            throw DatabaseServerLaunchConfigurationError
                .missingTokenRegistryPath
        }
        _ = try storage.runtimeStorage()
        _ = try hostConfiguration()
    }
}

public enum DatabaseServerLaunchConfigurationError:
    Error,
    Sendable,
    Equatable
{
    case invalidDocument
    case unsupportedFormatVersion(Int)
    case storageConfigurationMismatch
    case sqliteMemoryHasPath
    case sqliteFileMissingPath
    case invalidPostgreSQLConfiguration
    case postgreSQLTLSRequiresTCP
    case invalidFoundationDBConfiguration
    case missingTokenRegistryPath
    case configurationAlreadyExists
    case configurationWriteFailed
    case invalidConfigurationPermissions
}

private extension DatabaseServerLaunchConfiguration.Storage.PostgreSQL {
    func validated() throws -> NativeDatabaseStorageConfiguration {
        let hasHost = host.map { !$0.isEmpty } ?? false
        let hasSocket = unixSocketPath.map { !$0.isEmpty } ?? false
        guard hasHost != hasSocket,
              (1...65_535).contains(port),
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !tableName.isEmpty,
              passwordFilePath.map({ !$0.isEmpty }) ?? true else {
            throw DatabaseServerLaunchConfigurationError
                .invalidPostgreSQLConfiguration
        }
        let connection: NativeDatabaseStorageConfiguration.PostgreSQL.Connection
        if let host, hasHost {
            connection = .tcp(host: host, port: port)
        } else if let unixSocketPath, hasSocket {
            guard tls == .disable else {
                throw DatabaseServerLaunchConfigurationError
                    .postgreSQLTLSRequiresTCP
            }
            connection = .unixSocket(path: unixSocketPath)
        } else {
            throw DatabaseServerLaunchConfigurationError
                .invalidPostgreSQLConfiguration
        }
        return .postgreSQL(
            NativeDatabaseStorageConfiguration.PostgreSQL(
                connection: connection,
                username: username,
                passwordFilePath: passwordFilePath,
                database: database,
                tls: tls == .disable ? .disable : .require,
                tableName: tableName,
                schemaManagement: schemaManagement == .createIfNeeded
                    ? .createIfNeeded
                    : .assumeExists
            )
        )
    }
}
