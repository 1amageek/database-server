@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
import DatabaseServerFoundation
import DatabaseServerRuntime
import DatabaseWire
import StorageKit
import TestSupport
import Testing

@Suite("Canonical database operation service factory")
struct CanonicalDatabaseOperationServiceFactoryTests {
    @Test("factory composes every canonical database service")
    func composesCanonicalServices() async throws {
        let container = try await DBContainer.open(
            for: try Schema(
                entities: [try DatabaseGraphSourceEdge.schemaEntity],
                version: Schema.Version(1, 0, 0)
            ),
            configuration: DBConfiguration.testing(storageEngine: InMemoryEngine()),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [try DatabaseFrameworkRuntime.entity(DatabaseGraphSourceEdge.self)]
            ),
            security: .testingDisabled
        )
        let stateStore = DatabaseMutationStateStore(
            container: container
        )
        let context = DatabaseOperationServiceContext(
            container: container,
            stateStore: stateStore,
            coordinator: DatabaseTransactionalOperationCoordinator(
                stateStore: stateStore
            ),
            runtimeLimits: .default,
            wireLimits: .default,
            clock: AnyDatabaseWallClock(RealtimeDatabaseWallClock())
        )
        let platform = RejectingPlatformServices()
        let services = try await CanonicalDatabaseOperationServiceFactory(
            maintenanceServiceFactory: platform,
            jobServiceFactory: platform
        ).makeServices(context: context)

        #expect(services.readCommandRegistry.identifiers.isEmpty)
        #expect(services.writeCommandRegistry.identifiers.isEmpty)
        let decorated = services.replacingCommandRegistries(
            read: try DatabaseReadCommandRegistry(commands: []),
            write: try DatabaseWriteCommandRegistry(commands: [])
        )
        #expect(decorated.statementExecutor === services.statementExecutor)
        await #expect(throws: UnexpectedPlatformInvocation.self) {
            try await services.jobService.runScheduledWork()
        }
    }

    private struct RejectingPlatformServices:
        DatabaseMaintenanceServiceFactory,
        DatabaseMaintenanceService,
        DatabaseJobServiceFactory,
        DatabaseJobService {
        var jobOperations: [JobOperationIdentifier] { [] }

        #if MultiBase
        func startBaseAdmission(
            for operation: JobOperationIdentifier
        ) throws -> DatabaseBaseAdmissionKind {
            _ = operation
            throw UnexpectedPlatformInvocation.unexpectedInvocation
        }
        #endif

        func makeMaintenanceService(
            context: DatabaseOperationServiceContext
        ) async throws -> AnyDatabaseMaintenanceService {
            _ = context
            return AnyDatabaseMaintenanceService(self)
        }

        func makeJobService(
            context: DatabaseOperationServiceContext
        ) async throws -> AnyDatabaseJobService {
            _ = context
            return AnyDatabaseJobService(self)
        }

        func execute(
            _ request: MaintenanceExecuteOperation.Request,
            context: DatabaseOperationContext
        ) async throws -> MaintenanceExecutionResult {
            _ = request
            _ = context
            throw UnexpectedPlatformInvocation.unexpectedInvocation
        }

        func start(
            _ request: JobStartOperation.Request,
            context: DatabaseOperationContext
        ) async throws -> JobStartExecutionResult {
            _ = request
            _ = context
            throw UnexpectedPlatformInvocation.unexpectedInvocation
        }

        func status(
            _ request: JobStatusOperation.Request,
            context: DatabaseOperationContext
        ) async throws -> JobStatusOperation.Response {
            _ = request
            _ = context
            throw UnexpectedPlatformInvocation.unexpectedInvocation
        }

        func result(
            _ request: JobResultOperation.Request,
            context: DatabaseOperationContext
        ) async throws -> JobResultOperation.Response {
            _ = request
            _ = context
            throw UnexpectedPlatformInvocation.unexpectedInvocation
        }

        func cancel(
            _ request: JobCancelOperation.Request,
            context: DatabaseOperationContext
        ) async throws -> JobCancellationExecutionResult {
            _ = request
            _ = context
            throw UnexpectedPlatformInvocation.unexpectedInvocation
        }

        func runScheduledWork() async throws {
            throw UnexpectedPlatformInvocation.unexpectedInvocation
        }
    }

    private enum UnexpectedPlatformInvocation: Error {
        case unexpectedInvocation
    }
}
