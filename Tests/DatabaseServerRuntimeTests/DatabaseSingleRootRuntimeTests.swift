#if !MultipleBases
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
import DatabaseServerRuntime
import DatabaseServerFoundation
import DatabaseTypes
import DatabaseWire
import StorageKit
import TestSupport
import Testing

@Persistable
private struct SingleRootEntity: SecurityPolicy {
    #Directory<SingleRootEntity>("single-root", "entities")

    var id: String = ""
    var value: String = ""

    static func permitsRead(
        of resource: borrowing SingleRootEntity,
        in context: borrowing AuthorizationContext
    ) -> Bool {
        _ = resource
        return context.isAuthenticated
    }

    static func permitsQuery(
        _ query: borrowing SecurityQuery,
        in context: borrowing AuthorizationContext
    ) -> Bool {
        _ = query
        return context.isAuthenticated
    }

    static func permitsCreate(
        _ newResource: borrowing SingleRootEntity,
        in context: borrowing AuthorizationContext
    ) -> Bool {
        _ = newResource
        return context.isAuthenticated
    }

    static func permitsUpdate(
        from resource: borrowing SingleRootEntity,
        to newResource: borrowing SingleRootEntity,
        in context: borrowing AuthorizationContext
    ) -> Bool {
        _ = resource
        _ = newResource
        return context.isAuthenticated
    }

    static func permitsDelete(
        _ resource: borrowing SingleRootEntity,
        in context: borrowing AuthorizationContext
    ) -> Bool {
        _ = resource
        return context.isAuthenticated
    }
}

@Suite("Single database data root", .serialized)
struct DatabaseSingleRootRuntimeTests {
    private static let authorization = AuthorizationContext.authenticated(
        Principal(identifier: "single-root-admin", roles: ["admin"])
    )

    @Test("local contexts persist through the database data root")
    func localContextPersistsData() async throws {
        let container = try await makeContainer()
        defer {
            Task { await container.shutdown() }
        }
        let context = container.newContext(authorization: Self.authorization)
        var entity = SingleRootEntity()
        entity.id = "entity-1"
        entity.value = "stored"

        try context.insert(entity)
        try await context.save()

        let stored = try await context.model(
            for: entity.id,
            as: SingleRootEntity.self
        )
        #expect(stored?.value == "stored")
        await container.shutdown()
    }

    @Test("runtime advertises only database-root operations")
    func capabilitiesExcludeMultipleBaseOperations() async throws {
        let container = try await makeContainer()
        let runtime = try await makeRuntime(container: container)

        let response = try await invoke(
            DatabaseOperationCatalog.capabilitiesDescribe,
            request: EmptyOperationPayload(),
            requestID: 1,
            runtime: runtime
        )
        let identifiers = Set(response.features.map(\.identifier))
        #expect(identifiers.contains("query.execute"))
        #expect(identifiers.contains("mutation.execute"))
        #expect(!identifiers.contains("base.execute"))
        #expect(!identifiers.contains("composition.execute"))
        #expect(!identifiers.contains("grant.execute"))
        #expect(!identifiers.contains { $0.hasPrefix("composition.") })
        await container.shutdown()
    }

    private func makeContainer() async throws -> DBContainer {
        let engine = InMemoryEngine()
        return try await DBContainer.open(
            for: try Schema(
                entities: [try SingleRootEntity.schemaEntity],
                version: Schema.Version(1, 0, 0)
            ),
            configuration: DBConfiguration(
                storageEngine: engine,
                monotonicClock: TestProcessMonotonicClock(),
                wallClock: RealtimeDatabaseWallClock()
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        SingleRootEntity.self
                    ),
                ],
                authorizationPolicies: [
                    AuthorizationPolicyHandler(SingleRootEntity.self),
                ]
            )
        )
    }

    private func makeRuntime(
        container: DBContainer
    ) async throws -> DatabaseOperationInstance {
        try await DatabaseOperationInstance.open(
            container: container,
            configuration: try DatabaseOperationConfiguration(
                identity: DatabaseOperationIdentity(version: "single-root-test"),
                serviceFactory: AnyDatabaseOperationServiceFactory(
                    SingleRootServiceFactory()
                ),
                admissionPolicy: AnyDatabaseOperationAdmissionPolicy(
                    UnrestrictedDatabaseOperationAdmissionPolicy()
                ),
            )
        )
    }

    private func invoke<Request, Response>(
        _ operation: DatabaseOperation<Request, Response>,
        request: Request,
        requestID: UInt64,
        metadata: OperationRequestMetadata = OperationRequestMetadata(),
        authorization: AuthorizationContext = Self.authorization,
        runtime: DatabaseOperationInstance
    ) async throws -> Response {
        let frame = try DatabaseWireEncoder().encodeRequest(
            operation,
            requestID: requestID,
            metadata: metadata,
            request: request
        )
        let response = try DatabaseWireDecoder().decodeResponse(
            operation,
            from: try await DatabaseWireEndpoint(instance: runtime).execute(
                frame,
                context: DatabaseRequestExecutionContext(
                    authorization: authorization
                )
            ),
            matching: requestID
        )
        switch response {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

private final class SingleRootServiceFactory: DatabaseOperationServiceFactory {
    func makeServices(
        context: DatabaseOperationServiceContext
    ) async throws -> DatabaseOperationServices {
        let unavailable = SingleRootUnavailableService()
        #if GraphIndexes
        return DatabaseOperationServices(
            graphOperations: GraphOperationServices(
                statementExecutor: CanonicalDatabaseStatementMutationExecutor(
                    runtimeLimits: context.runtimeLimits
                ),
                algorithm: AnyDatabaseGraphAlgorithmService(unavailable),
                ontology: AnyDatabaseOntologyService(unavailable),
                shacl: AnyDatabaseSHACLService(unavailable)
            ),
            readCommandRegistry: try DatabaseReadCommandRegistry(commands: []),
            writeCommandRegistry: try DatabaseWriteCommandRegistry(commands: []),
            maintenanceService: AnyDatabaseMaintenanceService(unavailable),
            jobService: AnyDatabaseJobService(unavailable)
        )
        #else
        return DatabaseOperationServices(
            statementExecutor: AnyDatabaseStatementMutationExecutor(
                CanonicalDatabaseStatementMutationExecutor(
                    runtimeLimits: context.runtimeLimits
                )
            ),
            readCommandRegistry: try DatabaseReadCommandRegistry(commands: []),
            writeCommandRegistry: try DatabaseWriteCommandRegistry(commands: []),
            maintenanceService: AnyDatabaseMaintenanceService(unavailable),
            jobService: AnyDatabaseJobService(unavailable)
        )
        #endif
    }
}

private struct SingleRootUnavailableService:
    DatabaseMaintenanceService,
    DatabaseJobService
{
    let jobOperations: [JobOperationIdentifier] = []

    func execute(
        _ request: MaintenanceExecuteOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> MaintenanceExecutionResult {
        _ = request
        _ = context
        throw SingleRootUnavailableError()
    }

    func start(
        _ request: JobStartOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobStartExecutionResult {
        _ = request
        _ = context
        throw SingleRootUnavailableError()
    }

    func status(
        _ request: JobStatusOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobStatusOperation.Response {
        _ = request
        _ = context
        throw SingleRootUnavailableError()
    }

    func result(
        _ request: JobResultOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobResultOperation.Response {
        _ = request
        _ = context
        throw SingleRootUnavailableError()
    }

    func cancel(
        _ request: JobCancelOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobCancellationExecutionResult {
        _ = request
        _ = context
        throw SingleRootUnavailableError()
    }

    func runScheduledWork() async throws {
        throw SingleRootUnavailableError()
    }

}

#if GraphIndexes
extension SingleRootUnavailableService:
    DatabaseGraphAlgorithmService,
    DatabaseOntologyService,
    DatabaseSHACLService {
    func execute(
        _ request: GraphAlgorithmOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> GraphAlgorithmOperation.Response {
        _ = request
        _ = context
        throw SingleRootUnavailableError()
    }

    func execute(
        _ request: OntologyExecuteOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> OntologyExecutionResult {
        _ = request
        _ = context
        throw SingleRootUnavailableError()
    }

    func execute(
        _ request: SHACLExecuteOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> SHACLExecutionResult {
        _ = request
        _ = context
        throw SingleRootUnavailableError()
    }
}
#endif

private struct SingleRootUnavailableError: Error {}
#endif
