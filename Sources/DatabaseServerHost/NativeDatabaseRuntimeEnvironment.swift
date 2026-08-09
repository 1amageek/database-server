import DatabaseServer
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
        storage: NativeDatabaseStorageConfiguration,
        version: String
    ) async throws -> NativeDatabaseRuntimeEnvironment {
        let openedStorage = try await openStorage(storage)
        let engine = openedStorage.engine
        let scheduler = NativeDatabaseJobScheduler()
        do {
            let runtime = try await DatabaseHostedRuntime.open(
                application: try NativeDatabaseApplicationFactory
                    .schemaDriven(version: version),
                storageEngine: engine,
                hostServices: DatabaseServerHostServices(
                    jobScheduler: scheduler
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
            engine.requestShutdown()
            await engine.waitUntilShutdown()
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
    struct OpenedStorage: Sendable {
        let engine: any StorageEngine
        let backendShutdown: @Sendable () async -> Void
    }

    static func openStorage(
        _ storage: NativeDatabaseStorageConfiguration
    ) async throws -> OpenedStorage {
        switch storage {
        case .sqliteMemory:
            return OpenedStorage(
                engine: try SQLiteStorageEngine(configuration: .inMemory),
                backendShutdown: {}
            )
        case .sqliteFile(let path):
            return OpenedStorage(
                engine: try SQLiteStorageEngine(configuration: .file(path)),
                backendShutdown: {}
            )
        case .postgreSQL(let configuration):
            return OpenedStorage(
                engine: try await PostgreSQLStorageEngine(
                    configuration: try postgreSQLConfiguration(configuration)
                ),
                backendShutdown: {}
            )
        case .foundationDB(let clusterFilePath):
            guard !FDBClient.isInitialized else {
                throw NativeDatabaseStorageError
                    .foundationDBClientAlreadyInitialized
            }
            try await FDBClient.initialize()
            do {
                let database = try FDBClient.openDatabase(
                    clusterFilePath: clusterFilePath
                )
                let engine = try await FDBStorageEngine(
                    configuration: .init(database: database)
                )
                return OpenedStorage(
                    engine: engine,
                    backendShutdown: { FDBClient.shutdown() }
                )
            } catch {
                FDBClient.shutdown()
                throw error
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
}
