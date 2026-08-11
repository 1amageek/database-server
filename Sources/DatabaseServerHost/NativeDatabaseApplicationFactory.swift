import DatabaseEngine
import DatabaseRuntime
import DatabaseWireRuntime
import DatabaseFoundation
import StorageKitSystemClock

public enum NativeDatabaseApplicationFactory {
    public static func schemaDriven(
        version: String
    ) throws -> AnyDatabaseApplication {
        let schemaRuntimeFactory = AnyDatabaseSchemaRuntimeFactory(
            SchemaDrivenDatabaseRuntimeFactory()
        )
        let runtimeLimits = DatabaseRuntimeLimits.default
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
        let runtimeConfiguration = try DatabaseOperationRuntimeConfiguration(
            identity: DatabaseRuntimeIdentity(version: version),
            serviceFactory: AnyDatabaseOperationServiceFactory(services),
            admissionPolicy: AnyDatabaseOperationAdmissionPolicy(
                UnrestrictedDatabaseOperationAdmissionPolicy()
            ),
            clock: RealtimeDatabaseWallClock(),
            schemaRuntimeFactory: schemaRuntimeFactory,
            runtimeLimits: runtimeLimits
        )
        let definition = DatabaseContainerDefinition(
            schemaRuntimeFactory: schemaRuntimeFactory,
            security: .enabled(),
            monotonicClock: SystemStorageClock(),
            wallClock: RealtimeDatabaseWallClock()
        )
        return AnyDatabaseApplication(
            try StandaloneDatabaseApplication(
                containerDefinition: definition,
                runtimeConfiguration: runtimeConfiguration
            )
        )
    }
}
