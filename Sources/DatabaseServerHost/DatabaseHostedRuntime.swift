import DatabaseEngine
import DatabaseOperations
import DatabaseTypes
import DatabaseWire
import DatabaseWireAdapter
import StorageKit

public final class DatabaseHostedRuntime: Sendable {
    private let operationInstance: DatabaseOperationInstance
    private let wireEndpoint: DatabaseWireEndpoint

    public static func open(
        application: AnyDatabaseOperationApplication,
        storageTopology: DatabaseStorageTopology,
        hostServices: DatabaseOperationHostServices,
        requestWireLimits: DatabaseWireLimits = .default,
        responseWireLimits: DatabaseWireLimits = .default
    ) async throws -> DatabaseHostedRuntime {
        let definition: DatabaseContainerDefinition
        do {
            definition = try await application.makeContainerDefinition()
        } catch {
            for domain in storageTopology.domains {
                domain.storageEngine.requestShutdown()
            }
            for domain in storageTopology.domains {
                await domain.storageEngine.waitUntilShutdown()
            }
            throw error
        }
        // DatabaseContainerDefinition transfers the complete topology into
        // DBContainer. Its open path owns authoritative cleanup on failure;
        // the host must not race it with a second engine shutdown.
        let container = try await definition.open(
            storageTopology: storageTopology
        )
        let configuration: DatabaseOperationConfiguration
        do {
            configuration = try await application.makeOperationConfiguration(
                for: container
            )
        } catch {
            await container.shutdown()
            throw error
        }
        let operationInstance = try await DatabaseOperationInstance.open(
            container: container,
            configuration: configuration,
            hostServices: hostServices
        )
        return DatabaseHostedRuntime(
            operationInstance: operationInstance,
            wireEndpoint: DatabaseWireEndpoint(
                instance: operationInstance,
                requestLimits: requestWireLimits,
                responseLimits: responseWireLimits
            )
        )
    }

    init(
        operationInstance: DatabaseOperationInstance,
        wireEndpoint: DatabaseWireEndpoint
    ) {
        self.operationInstance = operationInstance
        self.wireEndpoint = wireEndpoint
    }

    public func execute(
        _ request: ByteString,
        authorization: DatabaseRequestExecutionContext
    ) async throws -> ByteString {
        try await wireEndpoint.execute(request, context: authorization)
    }

    public func runScheduledWork() async throws {
        try await operationInstance.runScheduledWork()
    }

    public func shutdown() async {
        await operationInstance.shutdown()
    }
}
