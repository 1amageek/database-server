import DatabaseWire
import Foundation

public struct DatabaseServerLaunchConfiguration: Codable, Sendable {
    public struct Storage: Codable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case memory
            case file
        }

        public let kind: Kind
        public let path: String?

        public init(kind: Kind, path: String? = nil) {
            self.kind = kind
            self.path = path
        }

        func validated() throws -> NativeDatabaseRuntimeEnvironment.Storage {
            switch kind {
            case .memory:
                guard path == nil else {
                    throw DatabaseServerLaunchConfigurationError
                        .memoryStorageHasPath
                }
                return .memory
            case .file:
                guard let path, !path.isEmpty else {
                    throw DatabaseServerLaunchConfigurationError
                        .fileStorageMissingPath
                }
                return .file(path: path)
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
        throws -> NativeDatabaseRuntimeEnvironment.Storage
    {
        try storage.validated()
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
        _ = try storage.validated()
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
    case memoryStorageHasPath
    case fileStorageMissingPath
    case missingTokenRegistryPath
    case configurationAlreadyExists
    case configurationWriteFailed
    case invalidConfigurationPermissions
}
