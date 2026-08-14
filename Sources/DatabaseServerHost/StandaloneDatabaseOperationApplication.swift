@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseServerRuntime

/// Standard application composition for a storage-owned schema catalog.
public struct StandaloneDatabaseOperationApplication: DatabaseOperationApplication,
    Sendable {
    private let containerDefinition: DatabaseContainerDefinition
    private let operationConfiguration: DatabaseOperationConfiguration

    public init(
        containerDefinition: DatabaseContainerDefinition,
        operationConfiguration: DatabaseOperationConfiguration
    ) throws(StandaloneDatabaseOperationApplicationError) {
        guard containerDefinition.isSchemaDriven else {
            throw .compiledContainerDefinition
        }
        guard operationConfiguration.schemaRuntimeFactory != nil else {
            throw .schemaExecutionUnavailable
        }
        self.containerDefinition = containerDefinition
        self.operationConfiguration = operationConfiguration
    }

    public func makeContainerDefinition() async throws
        -> DatabaseContainerDefinition {
        containerDefinition
    }

    public func makeOperationConfiguration(
        for container: DBContainer
    ) async throws -> DatabaseOperationConfiguration {
        _ = container
        return operationConfiguration
    }
}
