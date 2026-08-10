import DatabaseEngine
import DatabaseRuntime
import DatabaseServer
import DatabaseServerFoundation
import StorageKitSystemClock

public enum NativeDatabaseApplicationFactory {
    public static func schemaDriven(
        version: String
    ) throws -> AnyDatabaseServerApplication {
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
        let services = CanonicalDatabaseServerServiceFactory(
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
        let runtimeConfiguration = try DatabaseServerRuntimeConfiguration(
            identity: DatabaseRuntimeIdentity(version: version),
            serviceFactory: AnyDatabaseServerServiceFactory(services),
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
        return AnyDatabaseServerApplication(
            try SchemaDrivenDatabaseApplication(
                containerDefinition: definition,
                runtimeConfiguration: runtimeConfiguration
            )
        )
    }
}
