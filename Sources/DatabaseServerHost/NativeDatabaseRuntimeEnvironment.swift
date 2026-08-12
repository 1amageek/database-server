import DatabaseOperations
import DatabaseFoundation
import DatabaseEngine
import DatabaseKit
import DatabaseWire
#if DATABASE_SERVER_FOUNDATIONDB_BACKEND
import FDBStorage
import FoundationDB
#endif
import NIOSSL
#if DATABASE_SERVER_POSTGRESQL_BACKEND
import PostgreSQLStorage
#endif
#if DATABASE_SERVER_SQLITE_BACKEND
import SQLiteStorage
#endif
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
    private let authenticator: any DatabaseServerAuthenticator
    private let backendShutdown: @Sendable () async -> Void
    private let backendShutdownState = BackendShutdown()

    public static func open(
        storageTopology configuration:
            NativeDatabaseStorageTopologyConfiguration,
        authenticator: any DatabaseServerAuthenticator,
        version: String,
        wireLimits: DatabaseWireLimits = .default
    ) async throws -> NativeDatabaseRuntimeEnvironment {
        let application = try NativeDatabaseOperationApplicationFactory
            .schemaDriven(version: version)
        let openedStorage = try await openStorageTopology(configuration)
        let scheduler = NativeDatabaseJobScheduler()
        do {
            let runtime = try await DatabaseHostedRuntime.open(
                application: application,
                storageTopology: openedStorage.topology,
                hostServices: DatabaseOperationHostServices(
                    jobScheduler: AnyDatabaseJobScheduler(scheduler),
                    identifierGenerator: AnyDatabaseUUIDGenerator(
                        RandomDatabaseUUIDGenerator()
                    ),
                    jobAuthorizationValidator:
                        AnyDatabaseJobAuthorizationValidator(authenticator)
                ),
                requestWireLimits: wireLimits,
                responseWireLimits: wireLimits
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
                authenticator: authenticator,
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
        authenticator: any DatabaseServerAuthenticator,
        backendShutdown: @escaping @Sendable () async -> Void
    ) {
        self.runtime = runtime
        self.jobScheduler = jobScheduler
        self.authenticator = authenticator
        self.backendShutdown = backendShutdown
    }

    public func makeRequestExecutor(
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
            #if DATABASE_SERVER_FOUNDATIONDB_BACKEND
            guard !FDBClient.isInitialized else {
                throw NativeDatabaseStorageError
                    .foundationDBClientAlreadyInitialized
            }
            try await FDBClient.initialize()
            #else
            throw NativeDatabaseStorageError.backendUnavailable(
                "foundationdb"
            )
            #endif
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
            #if DATABASE_SERVER_HOST_MULTIPLE_BASES
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
            #else
            let topology = DatabaseStorageTopology(
                controlDomain: domains[0]
            )
            #endif
            let backendShutdown: @Sendable () async -> Void
            if usesFoundationDB {
                #if DATABASE_SERVER_FOUNDATIONDB_BACKEND
                backendShutdown = { FDBClient.shutdown() }
                #else
                preconditionFailure(
                    "Unavailable FoundationDB backend passed admission"
                )
                #endif
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
            #if DATABASE_SERVER_FOUNDATIONDB_BACKEND
            if usesFoundationDB { FDBClient.shutdown() }
            #endif
            throw error
        }
    }

    static func openStorage(
        _ storage: NativeDatabaseStorageConfiguration
    ) async throws -> any StorageEngine {
        switch storage {
        case .sqliteMemory:
            #if DATABASE_SERVER_SQLITE_BACKEND
            return try SQLiteStorageEngine(configuration: .inMemory)
            #else
            throw NativeDatabaseStorageError.backendUnavailable("sqlite")
            #endif
        case .sqliteFile(let path):
            #if DATABASE_SERVER_SQLITE_BACKEND
            return try SQLiteStorageEngine(configuration: .file(path))
            #else
            throw NativeDatabaseStorageError.backendUnavailable("sqlite")
            #endif
        case .postgreSQL(let configuration):
            #if DATABASE_SERVER_POSTGRESQL_BACKEND
            return try await PostgreSQLStorageEngine(
                configuration: try postgreSQLConfiguration(configuration)
            )
            #else
            throw NativeDatabaseStorageError.backendUnavailable("postgresql")
            #endif
        case .foundationDB(let clusterFilePath):
            #if DATABASE_SERVER_FOUNDATIONDB_BACKEND
            let database = try FDBClient.openDatabase(
                clusterFilePath: clusterFilePath
            )
            return try await FDBStorageEngine(
                configuration: .init(database: database)
            )
            #else
            throw NativeDatabaseStorageError.backendUnavailable(
                "foundationdb"
            )
            #endif
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

    #if DATABASE_SERVER_POSTGRESQL_BACKEND
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
    #endif
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
    case backendUnavailable(String)
}
