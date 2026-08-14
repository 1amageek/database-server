@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseRuntime
import DatabaseServerRuntime
import DatabaseServerFoundation
import StorageKitSystemClock

public enum NativeDatabaseOperationApplicationFactory {
    public static func schemaDriven(
        version: String
    ) throws -> AnyDatabaseOperationApplication {
        let schemaRuntimeFactory = AnyDatabaseSchemaRuntimeFactory(
            SchemaDrivenDatabaseRuntimeFactory()
        )
        let runtimeLimits = DatabaseOperationLimits.default
        let identifierGenerator = RandomDatabaseUUIDGenerator()
        let operationRegistry = try DatabaseResumableOperationRegistry(
            operations: [
                AnyDatabaseResumableOperation(
                    DatabaseMaintenanceResumableOperation(
                        runtimeLimits: runtimeLimits
                    )
                ),
            ]
        )
        let services = CanonicalDatabaseOperationServiceFactory(
            maintenanceServiceFactory:
                DatabaseMaintenanceOperationServiceFactory(
                    identifierGenerator: identifierGenerator
                ),
            jobServiceFactory: try DatabasePersistentJobServiceFactory(
                registry: operationRegistry,
                identifierGenerator: identifierGenerator,
                storageLimits: DatabasePersistentJobStorageLimits(
                    maximumStorageValueBytes: 1_048_576
                )
            )
        )
        let operationConfiguration = try DatabaseOperationConfiguration(
            identity: DatabaseOperationIdentity(version: version),
            serviceFactory: AnyDatabaseOperationServiceFactory(services),
            admissionPolicy: AnyDatabaseOperationAdmissionPolicy(
                UnrestrictedDatabaseOperationAdmissionPolicy()
            ),
            schemaRuntimeFactory: schemaRuntimeFactory,
            runtimeLimits: runtimeLimits
        )
        let definition = DatabaseContainerDefinition(
            schemaRuntimeFactory: schemaRuntimeFactory,
            security: .enabled(),
            monotonicClock: SystemStorageClock(),
            wallClock: RealtimeDatabaseWallClock()
        )
        return AnyDatabaseOperationApplication(
            try StandaloneDatabaseOperationApplication(
                containerDefinition: definition,
                operationConfiguration: operationConfiguration
            )
        )
    }
}
