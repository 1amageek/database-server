import DatabaseEngine
import DatabaseWireRuntime

/// Standard application composition for a storage-owned schema catalog.
public struct StandaloneDatabaseApplication: DatabaseApplication,
    Sendable {
    private let containerDefinition: DatabaseContainerDefinition
    private let runtimeConfiguration: DatabaseOperationRuntimeConfiguration

    public init(
        containerDefinition: DatabaseContainerDefinition,
        runtimeConfiguration: DatabaseOperationRuntimeConfiguration
    ) throws(StandaloneDatabaseApplicationError) {
        guard containerDefinition.isSchemaDriven else {
            throw .compiledContainerDefinition
        }
        guard runtimeConfiguration.schemaRuntimeFactory != nil else {
            throw .schemaExecutionUnavailable
        }
        self.containerDefinition = containerDefinition
        self.runtimeConfiguration = runtimeConfiguration
    }

    public func makeContainerDefinition() async throws
        -> DatabaseContainerDefinition {
        containerDefinition
    }

    public func makeRuntimeConfiguration(
        for container: DBContainer
    ) async throws -> DatabaseOperationRuntimeConfiguration {
        _ = container
        return runtimeConfiguration
    }
}
