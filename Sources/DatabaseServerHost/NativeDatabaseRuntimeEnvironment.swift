import DatabaseServer
import SQLiteStorage

public final class NativeDatabaseRuntimeEnvironment: Sendable {
    public enum Storage: Sendable, Hashable {
        case memory
        case file(path: String)
    }

    public let runtime: DatabaseHostedRuntime
    public let jobScheduler: NativeDatabaseJobScheduler

    public static func open(
        storage: Storage,
        version: String
    ) async throws -> NativeDatabaseRuntimeEnvironment {
        let storageConfiguration: SQLiteStorageEngine.Configuration
        switch storage {
        case .memory:
            storageConfiguration = .inMemory
        case .file(let path):
            storageConfiguration = .file(path)
        }
        let engine = try SQLiteStorageEngine(
            configuration: storageConfiguration
        )
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
                jobScheduler: scheduler
            )
        } catch {
            await scheduler.shutdown()
            engine.requestShutdown()
            await engine.waitUntilShutdown()
            throw error
        }
    }

    private init(
        runtime: DatabaseHostedRuntime,
        jobScheduler: NativeDatabaseJobScheduler
    ) {
        self.runtime = runtime
        self.jobScheduler = jobScheduler
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
    }
}

public enum NativeDatabaseRuntimeEnvironmentError:
    Error,
    Sendable,
    Equatable
{
    case runtimeReleased
}
