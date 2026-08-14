import ArgumentParser
import DatabaseKit
import DatabaseServerRuntime
import DatabaseServerHost
import DatabaseWire
import Darwin
import Foundation
import Logging
import ServiceLifecycle

private enum DatabaseServerStorageBackend: String, ExpressibleByArgument {
    case sqlite
    case postgreSQL = "postgresql"
    case foundationDB = "foundationdb"
}

private enum DatabaseServerPostgreSQLTLSMode: String, ExpressibleByArgument {
    case disable
    case require
}

private enum DatabaseServerPostgreSQLSchemaManagement:
    String,
    ExpressibleByArgument
{
    case createIfNeeded = "create-if-needed"
    case assumeExists = "assume-exists"
}

private struct DatabaseServerStorageOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Select sqlite, postgresql, or foundationdb; defaults to sqlite for a new selection."
    )
    var storage: DatabaseServerStorageBackend?

    @Option(name: .long, help: "SQLite database file path.")
    var path: String?

    @Flag(name: .long, help: "Use process-local SQLite memory storage.")
    var memory = false

    @Option(name: .customLong("postgres-host"), help: "PostgreSQL TCP host.")
    var postgreSQLHost: String?

    @Option(name: .customLong("postgres-port"), help: "PostgreSQL TCP port.")
    var postgreSQLPort = 5_432

    @Option(
        name: .customLong("postgres-unix-socket"),
        help: "PostgreSQL Unix socket path."
    )
    var postgreSQLUnixSocket: String?

    @Option(name: .customLong("postgres-user"), help: "PostgreSQL username.")
    var postgreSQLUser: String?

    @Option(
        name: .customLong("postgres-password-file"),
        help: "Owner-only PostgreSQL password file path."
    )
    var postgreSQLPasswordFile: String?

    @Option(
        name: .customLong("postgres-database"),
        help: "PostgreSQL database name."
    )
    var postgreSQLDatabase: String?

    @Option(
        name: .customLong("postgres-table"),
        help: "PostgreSQL key/value table name."
    )
    var postgreSQLTable = "kv_store"

    @Option(
        name: .customLong("postgres-schema-management"),
        help: "Select create-if-needed or assume-exists."
    )
    var postgreSQLSchemaManagement =
        DatabaseServerPostgreSQLSchemaManagement.createIfNeeded

    @Option(
        name: .customLong("postgres-tls"),
        help: "Select disable or require."
    )
    var postgreSQLTLS = DatabaseServerPostgreSQLTLSMode.disable

    @Option(
        name: .customLong("fdb-cluster-file"),
        help: "Explicit FoundationDB cluster file path."
    )
    var foundationDBClusterFile: String?

    @Option(
        name: .customLong("fdb-directory"),
        help: "One FoundationDB Directory component; repeat for nested paths."
    )
    var foundationDBDirectory: [String] = []

    #if DATABASE_SERVER_EXECUTABLE_MULTIPLE_BASES
    @Option(
        name: .customLong("domain-namespace"),
        help: "One non-FoundationDB domain namespace component; repeat for nested paths."
    )
    var domainNamespace: [String] = []
    #endif

    func launchStorage(required: Bool) throws
        -> DatabaseServerLaunchConfiguration.Storage?
    {
        guard required || hasExplicitSelection else { return nil }
        let selectedStorage = storage ?? .sqlite
        switch selectedStorage {
        case .sqlite:
            guard !hasPostgreSQLOptions,
                  foundationDBClusterFile == nil,
                  foundationDBDirectory.isEmpty,
                  memory != (path != nil) else {
                throw ValidationError(
                    "SQLite requires exactly one of --memory or --path and no other backend options."
                )
            }
            if memory {
                return .init(sqlite: .init(mode: .memory))
            }
            let path = URL(fileURLWithPath: try requiredValue(path, "--path"))
                .standardizedFileURL.path
            return .init(sqlite: .init(mode: .file, path: path))
        case .postgreSQL:
            guard !memory,
                  path == nil,
                  foundationDBClusterFile == nil,
                  foundationDBDirectory.isEmpty,
                  (postgreSQLHost != nil) != (postgreSQLUnixSocket != nil),
                  (1...65_535).contains(postgreSQLPort) else {
                throw ValidationError(
                    "PostgreSQL requires exactly one of --postgres-host or --postgres-unix-socket and no SQLite or FoundationDB options."
                )
            }
            let passwordFile = postgreSQLPasswordFile.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }
            return .init(
                postgreSQL: .init(
                    host: postgreSQLHost,
                    port: postgreSQLPort,
                    unixSocketPath: postgreSQLUnixSocket.map {
                        URL(fileURLWithPath: $0).standardizedFileURL.path
                    },
                    username: try requiredValue(
                        postgreSQLUser,
                        "--postgres-user"
                    ),
                    passwordFilePath: passwordFile,
                    database: try requiredValue(
                        postgreSQLDatabase,
                        "--postgres-database"
                    ),
                    tls: postgreSQLTLS == .disable ? .disable : .require,
                    tableName: postgreSQLTable,
                    schemaManagement: postgreSQLSchemaManagement
                        == .createIfNeeded ? .createIfNeeded : .assumeExists
                )
            )
        case .foundationDB:
            guard !memory,
                  path == nil,
                  !hasPostgreSQLOptions,
                  !foundationDBDirectory.isEmpty,
                  !foundationDBDirectory.contains(where: \.isEmpty) else {
                throw ValidationError(
                    "FoundationDB requires at least one --fdb-directory component and cannot be combined with SQLite or PostgreSQL options."
                )
            }
            let clusterFile = URL(
                fileURLWithPath: try requiredValue(
                    foundationDBClusterFile,
                    "--fdb-cluster-file"
                )
            ).standardizedFileURL.path
            return .init(
                foundationDB: .init(clusterFilePath: clusterFile)
            )
        }
    }

    func runtimeStorage() throws -> NativeDatabaseStorageConfiguration {
        guard let storage = try launchStorage(required: true) else {
            throw ValidationError("Storage configuration is required.")
        }
        return try storage.runtimeStorage()
    }

    #if !DATABASE_SERVER_EXECUTABLE_MULTIPLE_BASES
    func launchDatabaseRoot(
        for storage: DatabaseServerLaunchConfiguration.Storage
    ) throws -> DatabaseServerLaunchConfiguration.DatabaseRoot {
        switch storage.kind {
        case .sqlite, .postgreSQL:
            return .engine
        case .foundationDB:
            guard !foundationDBDirectory.isEmpty,
                  !foundationDBDirectory.contains(where: \.isEmpty) else {
                throw ValidationError(
                    "FoundationDB requires at least one --fdb-directory component."
                )
            }
            return .directory(path: foundationDBDirectory)
        }
    }

    func runtimeDatabaseRoot() throws -> NativeDatabaseRootConfiguration {
        guard let storage = try launchStorage(required: true) else {
            throw ValidationError("Storage configuration is required.")
        }
        return try launchDatabaseRoot(for: storage).runtimeRoot(for: storage)
    }
    #else
    func multipleBasesNamespace(
        for storage: DatabaseServerLaunchConfiguration.Storage
    ) throws -> [String] {
        let components: [String]
        switch storage.kind {
        case .foundationDB:
            guard domainNamespace.isEmpty else {
                throw ValidationError(
                    "FoundationDB uses --fdb-directory, not --domain-namespace."
                )
            }
            components = foundationDBDirectory
        case .sqlite, .postgreSQL:
            components = domainNamespace
        }
        guard !components.isEmpty,
              !components.contains(where: \.isEmpty) else {
            throw ValidationError(
                "MultipleBases requires an explicit storage namespace."
            )
        }
        return components
    }
    #endif

    private var hasExplicitSelection: Bool {
        #if DATABASE_SERVER_EXECUTABLE_MULTIPLE_BASES
        storage != nil
            || memory
            || path != nil
            || hasPostgreSQLOptions
            || foundationDBClusterFile != nil
            || !foundationDBDirectory.isEmpty
            || !domainNamespace.isEmpty
        #else
        storage != nil
            || memory
            || path != nil
            || hasPostgreSQLOptions
            || foundationDBClusterFile != nil
            || !foundationDBDirectory.isEmpty
        #endif
    }

    private var hasPostgreSQLOptions: Bool {
        postgreSQLHost != nil
            || postgreSQLUnixSocket != nil
            || postgreSQLUser != nil
            || postgreSQLPasswordFile != nil
            || postgreSQLDatabase != nil
            || postgreSQLPort != 5_432
            || postgreSQLTable != "kv_store"
            || postgreSQLSchemaManagement != .createIfNeeded
            || postgreSQLTLS != .disable
    }

    private func requiredValue(
        _ value: String?,
        _ option: String
    ) throws -> String {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError(
                "\(option) is required for \((storage ?? .sqlite).rawValue)."
            )
        }
        return value
    }
}

@main
struct DatabaseServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "database-server",
        abstract: "Hosts a standalone database over DatabaseWire.",
        version: DatabaseServerBuild.version,
        subcommands: [Bootstrap.self, Serve.self, Stdio.self]
    )

    struct Bootstrap: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Prepare a server configuration and local administrator credential."
        )

        @Option(name: .long, help: "Server configuration path.")
        var config: String

        @OptionGroup fileprivate var storageOptions: DatabaseServerStorageOptions

        @Option(name: .long, help: "Listener host for a new configuration or this launch.")
        var host: String?

        @Option(name: .long, help: "Listener port for a new configuration or this launch.")
        var port: Int?

        @Option(name: .long, help: "Database routing identity for a new configuration.")
        var database = "main"

        @Option(name: .long, help: "Tenant routing identity for a new configuration.")
        var tenant: String?

        @Option(name: .long, help: "Workspace routing identity for a new configuration.")
        var workspace: String?

        mutating func run() async throws {
            guard isatty(STDIN_FILENO) == 0,
                  isatty(STDOUT_FILENO) == 0 else {
                throw ValidationError(
                    "Bootstrap requires private stdin and stdout pipes."
                )
            }
            let configurationURL = URL(fileURLWithPath: config)
            let launchConfiguration: DatabaseServerLaunchConfiguration
            if FileManager.default.fileExists(atPath: configurationURL.path) {
                launchConfiguration = try DatabaseServerLaunchConfiguration
                    .load(from: configurationURL)
                if let requested = try storageOptions.launchStorage(
                    required: false
                ) {
                    #if DATABASE_SERVER_EXECUTABLE_MULTIPLE_BASES
                    let matches = launchConfiguration.matchesSingleStorage(
                        requested,
                        namespace: try storageOptions.multipleBasesNamespace(
                            for: requested
                        )
                    )
                    #else
                    let requestedRoot = try storageOptions.launchDatabaseRoot(
                        for: requested
                    )
                    let matches = launchConfiguration.matchesSingleStorage(
                        requested,
                        databaseRoot: requestedRoot
                    )
                    #endif
                    guard matches else {
                        throw ValidationError(
                            "The requested storage does not match the existing configuration."
                        )
                    }
                }
            } else {
                guard let storage = try storageOptions.launchStorage(
                    required: true
                ) else {
                    throw ValidationError("A new configuration requires storage.")
                }
                let registryURL = configurationURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("tokens.json")
                #if DATABASE_SERVER_EXECUTABLE_MULTIPLE_BASES
                launchConfiguration = DatabaseServerLaunchConfiguration(
                    controlDomain: "primary",
                    domains: [
                        .init(
                            id: "primary",
                            namespace: try storageOptions.multipleBasesNamespace(
                                for: storage
                            ),
                            storage: storage
                        ),
                    ],
                    placements: [
                        .init(
                            id: "default",
                            domain: "primary",
                            path: ["bases"]
                        ),
                    ],
                    defaultPlacement: "default",
                    host: host ?? "127.0.0.1",
                    port: port ?? 7_878,
                    routing: .init(
                        databaseID: database,
                        tenantID: tenant,
                        workspaceID: workspace
                    ),
                    tokenRegistryPath: registryURL.path
                )
                #else
                launchConfiguration = DatabaseServerLaunchConfiguration(
                    storage: storage,
                    databaseRoot: try storageOptions.launchDatabaseRoot(
                        for: storage
                    ),
                    host: host ?? "127.0.0.1",
                    port: port ?? 7_878,
                    routing: .init(
                        databaseID: database,
                        tenantID: tenant,
                        workspaceID: workspace
                    ),
                    tokenRegistryPath: registryURL.path
                )
                #endif
                try launchConfiguration.create(at: configurationURL)
            }

            let actualHost = host ?? launchConfiguration.host
            let actualPort = port ?? launchConfiguration.port
            _ = try launchConfiguration.hostConfiguration(
                host: actualHost,
                port: actualPort
            )
            let registry = try DatabaseTokenRegistry(
                fileURL: launchConfiguration.tokenRegistryURL
            )
            let registration: DatabaseTokenRegistry.Registration?
            if await registry.isEmpty {
                registration = try await registry.register(
                    principal: Principal(
                        identifier: "local-admin",
                        roles: ["admin"]
                    )
                )
            } else {
                registration = nil
            }

            do {
                try writeBootstrapResponse(
                    DatabaseServerBootstrapResponse(
                        createdCredential: registration != nil,
                        token: registration?.token.rawValue,
                        endpoint: endpoint(
                            host: actualHost,
                            port: actualPort,
                            usesTLS: launchConfiguration.tls != nil
                        ),
                        databaseID: launchConfiguration.routing.databaseID,
                        tenantID: launchConfiguration.routing.tenantID,
                        workspaceID: launchConfiguration.routing.workspaceID
                    )
                )
                if let registration {
                    let acknowledgement = try FileHandle.standardInput.read(
                        upToCount: 1
                    ) ?? Data()
                    guard acknowledgement == Data([1]) else {
                        try await registry.remove(
                            tokenIdentifier: registration.token.identifier
                        )
                        throw DatabaseServerBootstrapError
                            .credentialWasNotAccepted
                    }
                }
            } catch {
                if let registration {
                    do {
                        try await registry.remove(
                            tokenIdentifier: registration.token.identifier
                        )
                    } catch DatabaseServerAuthenticationError.invalidCredential {
                        // The rejection path already removed this registration.
                    }
                }
                throw error
            }
        }
    }

    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Serve HTTP and WebSocket DatabaseWire connections."
        )

        @Option(
            name: .long,
            help: "Path to a versioned server configuration document."
        )
        var config: String

        @Option(name: .long, help: "Override the configured listener host.")
        var host: String?

        @Option(name: .long, help: "Override the configured listener port.")
        var port: Int?

        mutating func run() async throws {
            let launchConfiguration = try DatabaseServerLaunchConfiguration
                .load(from: URL(fileURLWithPath: config))
            let registry = try DatabaseTokenRegistry(
                fileURL: launchConfiguration.tokenRegistryURL
            )
            guard await registry.isEmpty == false else {
                throw ValidationError(
                    "The configured token registry has no credentials."
                )
            }
            let hostConfiguration = try launchConfiguration.hostConfiguration(
                host: host,
                port: port
            )
            let routingIdentity = try launchConfiguration.routingIdentity()
            #if DATABASE_SERVER_EXECUTABLE_MULTIPLE_BASES
            let environment = try await NativeDatabaseRuntimeEnvironment.open(
                storageTopology: launchConfiguration.runtimeStorageTopology(),
                authenticator: registry,
                version: DatabaseServerBuild.version,
                wireLimits: hostConfiguration.wireLimits
            )
            #else
            let environment = try await NativeDatabaseRuntimeEnvironment.open(
                storage: launchConfiguration.runtimeStorage(),
                databaseRoot: launchConfiguration.runtimeDatabaseRoot(),
                authenticator: registry,
                version: DatabaseServerBuild.version,
                wireLimits: hostConfiguration.wireLimits
            )
            #endif
            do {
                let executor = environment.makeRequestExecutor(
                    routingIdentity: routingIdentity
                )
                let network = try DatabaseNetworkService(
                    configuration: hostConfiguration,
                    executor: executor
                )
                try await runServiceGroup(
                    primary: network,
                    scheduler: environment.jobScheduler
                )
            } catch {
                await environment.shutdown()
                throw error
            }
            await environment.shutdown()
        }
    }

    struct Stdio: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Serve a private length-prefixed DatabaseWire stream."
        )

        @OptionGroup fileprivate var storageOptions: DatabaseServerStorageOptions

        @Option(
            name: .long,
            help: "Maximum length of one DatabaseWire frame."
        )
        var maximumFrameBytes = DatabaseWireLimits.default.maximumFrameBytes

        mutating func run() async throws {
            let authenticator = try LocalProcessAuthenticator()
            let wireLimits = try DatabaseServerHostConfiguration.wireLimits(
                maximumFrameBytes: maximumFrameBytes
            )
            #if DATABASE_SERVER_EXECUTABLE_MULTIPLE_BASES
            guard let selectedStorage = try storageOptions.launchStorage(
                required: true
            ) else {
                throw ValidationError("Storage configuration is required.")
            }
            let environment = try await NativeDatabaseRuntimeEnvironment.open(
                storageTopology: .single(
                    storage: try selectedStorage.runtimeStorage(),
                    namespacePath: try storageOptions.multipleBasesNamespace(
                        for: selectedStorage
                    )
                ),
                authenticator: authenticator,
                version: DatabaseServerBuild.version,
                wireLimits: wireLimits
            )
            #else
            let environment = try await NativeDatabaseRuntimeEnvironment.open(
                storage: try storageOptions.runtimeStorage(),
                databaseRoot: try storageOptions.runtimeDatabaseRoot(),
                authenticator: authenticator,
                version: DatabaseServerBuild.version,
                wireLimits: wireLimits
            )
            #endif
            do {
                let executor = environment.makeRequestExecutor(
                    routingIdentity: try DatabaseServerRoutingIdentity(
                        databaseID: "main"
                    )
                )
                let service = try DatabaseStdioService(
                    executor: executor,
                    authorization: .authenticated(
                        Principal(
                            identifier: "local-process",
                            roles: ["admin"]
                        )
                    ),
                    jobAuthorizationReference:
                        authenticator.authorizationReference,
                    maximumFrameBytes: maximumFrameBytes
                )
                try await runServiceGroup(
                    primary: service,
                    scheduler: environment.jobScheduler
                )
            } catch {
                await environment.shutdown()
                throw error
            }
            await environment.shutdown()
        }
    }
}

private struct DatabaseServerBootstrapResponse: Encodable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case createdCredential
        case token
        case endpoint
        case databaseID
        case tenantID
        case workspaceID
    }

    let formatVersion = 1
    let createdCredential: Bool
    let token: String?
    let endpoint: String
    let databaseID: String
    let tenantID: String?
    let workspaceID: String?

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(createdCredential, forKey: .createdCredential)
        if let token {
            try container.encode(token, forKey: .token)
        } else {
            try container.encodeNil(forKey: .token)
        }
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(databaseID, forKey: .databaseID)
        if let tenantID {
            try container.encode(tenantID, forKey: .tenantID)
        } else {
            try container.encodeNil(forKey: .tenantID)
        }
        if let workspaceID {
            try container.encode(workspaceID, forKey: .workspaceID)
        } else {
            try container.encodeNil(forKey: .workspaceID)
        }
    }
}

private enum DatabaseServerBootstrapError: Error {
    case credentialWasNotAccepted
    case responseTooLarge
}

private func endpoint(
    host: String,
    port: Int,
    usesTLS: Bool
) -> String {
    let renderedHost = host.contains(":") ? "[\(host)]" : host
    return "\(usesTLS ? "https" : "http")://\(renderedHost):\(port)/v1/database"
}

private func writeBootstrapResponse(
    _ response: DatabaseServerBootstrapResponse
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(response)
    guard let length = UInt32(exactly: payload.count) else {
        throw DatabaseServerBootstrapError.responseTooLarge
    }
    var bigEndianLength = length.bigEndian
    let prefix = withUnsafeBytes(of: &bigEndianLength) { Data($0) }
    try FileHandle.standardOutput.write(contentsOf: prefix)
    try FileHandle.standardOutput.write(contentsOf: payload)
}

private enum DatabaseServerBuild {
    static let version = "26.0814.0"
}

private struct LocalProcessAuthenticator: DatabaseServerAuthenticator {
    let authorizationReference: DatabaseJobAuthorizationReference

    init() throws {
        self.authorizationReference = try DatabaseJobAuthorizationReference(
            "local-process"
        )
    }

    func authenticate(
        _ credential: DatabaseServerCredential
    ) async throws -> DatabaseServerAuthentication {
        _ = credential
        throw DatabaseServerAuthenticationError.invalidCredential
    }

    func revalidate(
        _ reference: DatabaseJobAuthorizationReference
    ) async throws -> AuthorizationContext {
        guard reference == authorizationReference else {
            throw DatabaseServerAuthenticationError.invalidCredential
        }
        return .authenticated(
            Principal(identifier: "local-process", roles: ["admin"])
        )
    }
}

private func runServiceGroup(
    primary: any Service,
    scheduler: NativeDatabaseJobScheduler
) async throws {
    let group = ServiceGroup(
        configuration: .init(
            services: [
                ServiceGroupConfiguration.ServiceConfiguration(
                    service: primary,
                    successTerminationBehavior: .gracefullyShutdownGroup,
                    failureTerminationBehavior: .cancelGroup
                ),
            ],
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: Logger(label: "database-server")
        )
    )
    let schedulerTask = Task<Result<Void, any Error>, Never> {
        do {
            try await scheduler.run()
            return .success(())
        } catch {
            return .failure(error)
        }
    }
    let schedulerObserver = Task<Result<Void, any Error>, Never> {
        let result = await schedulerTask.value
        await group.triggerGracefulShutdown()
        return result
    }

    let primaryResult: Result<Void, any Error>
    do {
        try await group.run()
        primaryResult = .success(())
    } catch {
        primaryResult = .failure(error)
    }
    await scheduler.shutdown()
    let schedulerResult = await schedulerObserver.value
    try primaryResult.get()
    try schedulerResult.get()
}
