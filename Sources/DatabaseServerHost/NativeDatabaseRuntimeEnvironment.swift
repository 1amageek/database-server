import DatabaseServer
import DatabaseServerFoundation
import DatabaseEngine
import DatabaseKit
import FDBStorage
import FoundationDB
import NIOSSL
import PostgreSQLStorage
import SQLiteStorage
import StorageKit

public final class NativeDatabaseRuntimeEnvironment: Sendable {
    private actor BackendShutdown {
        private var didRun = false

        func run(_ operation: @Sendable () async -> Void) async {
            guard !didRun else { return }
            didRun = true
            await operation()
        }
    }

    public let runtime: DatabaseHostedRuntime
    public let jobScheduler: NativeDatabaseJobScheduler
    private let backendShutdown: @Sendable () async -> Void
    private let backendShutdownState = BackendShutdown()

    public static func open(
        storageTopology configuration:
            NativeDatabaseStorageTopologyConfiguration,
        version: String
    ) async throws -> NativeDatabaseRuntimeEnvironment {
        let application = try NativeDatabaseApplicationFactory
            .schemaDriven(version: version)
        let openedStorage = try await openStorageTopology(configuration)
        let scheduler = NativeDatabaseJobScheduler()
        do {
            let runtime = try await DatabaseHostedRuntime.open(
                application: application,
                storageTopology: openedStorage.topology,
                hostServices: DatabaseServerHostServices(
                    jobScheduler: scheduler,
                    identifierGenerator: RandomDatabaseUUIDGenerator()
                )
            )
            await scheduler.install { [weak runtime] in
                guard let runtime else {
                    throw NativeDatabaseRuntimeEnvironmentError
                        .runtimeReleased
                }
                try await runtime.runScheduledWork()
            }
            return NativeDatabaseRuntimeEnvironment(
                runtime: runtime,
                jobScheduler: scheduler,
                backendShutdown: openedStorage.backendShutdown
            )
        } catch {
            await scheduler.shutdown()
            // DatabaseHostedRuntime transfers the topology to DBContainer;
            // both its definition-failure and container-open-failure paths
            // complete authoritative engine shutdown before returning.
            await openedStorage.backendShutdown()
            throw error
        }
    }

    private init(
        runtime: DatabaseHostedRuntime,
        jobScheduler: NativeDatabaseJobScheduler,
        backendShutdown: @escaping @Sendable () async -> Void
    ) {
        self.runtime = runtime
        self.jobScheduler = jobScheduler
        self.backendShutdown = backendShutdown
    }

    public func makeRequestExecutor(
        authenticator: any DatabaseServerAuthenticator,
        routingIdentity: DatabaseServerRoutingIdentity
    ) -> DatabaseServerRequestExecutor {
        DatabaseServerRequestExecutor(
            authenticator: authenticator,
            routingIdentity: routingIdentity,
            runtime: runtime,
            prepareForShutdown: { [jobScheduler] in
                await jobScheduler.shutdown()
            }
        )
    }

    public func shutdown() async {
        await jobScheduler.shutdown()
        await runtime.shutdown()
        await backendShutdownState.run(backendShutdown)
    }
}

private extension NativeDatabaseRuntimeEnvironment {
    struct OpenedStorageTopology: Sendable {
        let topology: DatabaseStorageTopology
        let backendShutdown: @Sendable () async -> Void
    }

    static func openStorageTopology(
        _ configuration: NativeDatabaseStorageTopologyConfiguration
    ) async throws -> OpenedStorageTopology {
        try validatePhysicalBackends(configuration.domains)
        let usesFoundationDB = configuration.domains.contains {
            if case .foundationDB = $0.storage { return true }
            return false
        }
        if usesFoundationDB {
            guard !FDBClient.isInitialized else {
                throw NativeDatabaseStorageError
                    .foundationDBClientAlreadyInitialized
            }
            try await FDBClient.initialize()
        }

        var openedEngines: [any StorageEngine] = []
        do {
            var domains: [DatabaseStorageDomain] = []
            domains.reserveCapacity(configuration.domains.count)
            for domain in configuration.domains {
                let engine = try await openStorage(domain.storage)
                openedEngines.append(engine)
                domains.append(
                    try DatabaseStorageDomain(
                        id: DatabaseStorageDomain.ID(domain.id),
                        namespacePath: domain.namespacePath,
                        storageEngine: engine
                    )
                )
            }
            let placements = try configuration.placements.map {
                placement in
                try DatabaseStoragePlacement(
                    id: Base.Placement.ID(placement.id),
                    domainID: DatabaseStorageDomain.ID(
                        placement.domainID
                    ),
                    path: placement.path
                )
            }
            let topology = try DatabaseStorageTopology(
                controlDomainID: DatabaseStorageDomain.ID(
                    configuration.controlDomainID
                ),
                domains: domains,
                placements: placements,
                defaultPlacementID: Base.Placement.ID(
                    configuration.defaultPlacementID
                )
            )
            let backendShutdown: @Sendable () async -> Void
            if usesFoundationDB {
                backendShutdown = { FDBClient.shutdown() }
            } else {
                backendShutdown = {}
            }
            return OpenedStorageTopology(
                topology: topology,
                backendShutdown: backendShutdown
            )
        } catch {
            for engine in openedEngines.reversed() {
                engine.requestShutdown()
            }
            for engine in openedEngines.reversed() {
                await engine.waitUntilShutdown()
            }
            if usesFoundationDB { FDBClient.shutdown() }
            throw error
        }
    }

    static func openStorage(
        _ storage: NativeDatabaseStorageConfiguration
    ) async throws -> any StorageEngine {
        switch storage {
        case .sqliteMemory:
            return try SQLiteStorageEngine(configuration: .inMemory)
        case .sqliteFile(let path):
            return try SQLiteStorageEngine(configuration: .file(path))
        case .postgreSQL(let configuration):
            return try await PostgreSQLStorageEngine(
                configuration: try postgreSQLConfiguration(configuration)
            )
        case .foundationDB(let clusterFilePath):
            let database = try FDBClient.openDatabase(
                clusterFilePath: clusterFilePath
            )
            return try await FDBStorageEngine(
                configuration: .init(database: database)
            )
        }
    }

    static func validatePhysicalBackends(
        _ domains: [NativeDatabaseStorageDomainConfiguration]
    ) throws {
        var persistentBackends: Set<NativeDatabaseStorageConfiguration> = []
        for domain in domains {
            if case .sqliteMemory = domain.storage { continue }
            guard persistentBackends.insert(domain.storage).inserted else {
                throw NativeDatabaseStorageError
                    .duplicatePhysicalBackend
            }
        }
    }

    static func postgreSQLConfiguration(
        _ configuration: NativeDatabaseStorageConfiguration.PostgreSQL
    ) throws -> PostgreSQLConfiguration {
        let password = try configuration.passwordFilePath.map {
            try DatabaseServerSecretFile.readPassword(path: $0)
        }
        let schemaManagement: PostgreSQLConfiguration.SchemaManagement =
            configuration.schemaManagement == .createIfNeeded
                ? .createIfNeeded
                : .assumeExists

        switch configuration.connection {
        case .tcp(let host, let port):
            switch configuration.tls {
            case .disable:
                return PostgreSQLConfiguration(
                    host: host,
                    port: port,
                    username: configuration.username,
                    password: password,
                    database: configuration.database,
                    tls: .disable,
                    tableName: configuration.tableName,
                    schemaManagement: schemaManagement
                )
            case .require:
                return PostgreSQLConfiguration(
                    host: host,
                    port: port,
                    username: configuration.username,
                    password: password,
                    database: configuration.database,
                    tls: .require(TLSConfiguration.makeClientConfiguration()),
                    tableName: configuration.tableName,
                    schemaManagement: schemaManagement
                )
            }
        case .unixSocket(let path):
            guard configuration.tls == .disable else {
                throw NativeDatabaseStorageError
                    .postgreSQLTLSRequiresTCP
            }
            return PostgreSQLConfiguration(
                unixSocketPath: path,
                username: configuration.username,
                password: password,
                database: configuration.database,
                tableName: configuration.tableName,
                schemaManagement: schemaManagement
            )
        }
    }
}

public enum NativeDatabaseRuntimeEnvironmentError:
    Error,
    Sendable,
    Equatable
{
    case runtimeReleased
}

public enum NativeDatabaseStorageError: Error, Sendable, Equatable {
    case invalidPasswordFile
    case postgreSQLTLSRequiresTCP
    case foundationDBClientAlreadyInitialized
    case duplicatePhysicalBackend
}
