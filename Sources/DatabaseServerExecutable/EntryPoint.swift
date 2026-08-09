import ArgumentParser
import DatabaseKit
import DatabaseServerHost
import DatabaseWire
import Darwin
import Foundation
import Logging
import ServiceLifecycle

@main
struct DatabaseServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "database-server",
        abstract: "Hosts a canonical DatabaseWire runtime.",
        version: DatabaseServerBuild.version,
        subcommands: [Bootstrap.self, Serve.self, Stdio.self]
    )

    struct Bootstrap: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Prepare a server configuration and local administrator credential."
        )

        @Option(name: .long, help: "Server configuration path.")
        var config: String

        @Option(name: .long, help: "SQLite database path for a new configuration.")
        var path: String?

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
                if let path {
                    let requestedPath = URL(fileURLWithPath: path)
                        .standardizedFileURL.path
                    guard case .file(let configuredPath) = try launchConfiguration
                        .runtimeStorage(),
                          URL(fileURLWithPath: configuredPath)
                            .standardizedFileURL.path == requestedPath else {
                        throw ValidationError(
                            "The requested database path does not match the existing configuration."
                        )
                    }
                }
            } else {
                guard let path, !path.isEmpty else {
                    throw ValidationError(
                        "A new configuration requires --path."
                    )
                }
                let databaseURL = URL(fileURLWithPath: path)
                    .standardizedFileURL
                let registryURL = configurationURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("tokens.json")
                launchConfiguration = DatabaseServerLaunchConfiguration(
                    storage: .init(kind: .file, path: databaseURL.path),
                    host: host ?? "127.0.0.1",
                    port: port ?? 7_878,
                    routing: .init(
                        databaseID: database,
                        tenantID: tenant,
                        workspaceID: workspace
                    ),
                    tokenRegistryPath: registryURL.path
                )
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
            let environment = try await NativeDatabaseRuntimeEnvironment.open(
                storage: launchConfiguration.runtimeStorage(),
                version: DatabaseServerBuild.version
            )
            do {
                let executor = environment.makeRequestExecutor(
                    authenticator: registry,
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
        }
    }

    struct Stdio: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Serve a private length-prefixed DatabaseWire stream."
        )

        @Option(name: .long, help: "SQLite database file path.")
        var path: String?

        @Flag(name: .long, help: "Use a process-local in-memory database.")
        var memory = false

        @Option(
            name: .long,
            help: "Maximum length of one DatabaseWire frame."
        )
        var maximumFrameBytes = DatabaseWireLimits.default.maximumFrameBytes

        mutating func validate() throws {
            guard memory != (path != nil) else {
                throw ValidationError(
                    "Exactly one of --memory or --path is required."
                )
            }
        }

        mutating func run() async throws {
            let storage: NativeDatabaseRuntimeEnvironment.Storage
            if memory {
                storage = .memory
            } else if let path {
                storage = .file(path: path)
            } else {
                throw ValidationError(
                    "Exactly one of --memory or --path is required."
                )
            }
            let environment = try await NativeDatabaseRuntimeEnvironment.open(
                storage: storage,
                version: DatabaseServerBuild.version
            )
            do {
                let executor = environment.makeRequestExecutor(
                    authenticator: RejectingAuthenticator(),
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
    static let version = "26.0809.0"
}

private struct RejectingAuthenticator: DatabaseServerAuthenticator {
    func authenticate(
        _ credential: DatabaseServerCredential
    ) async throws -> AuthorizationContext {
        _ = credential
        throw DatabaseServerAuthenticationError.invalidCredential
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
