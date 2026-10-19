@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
import DatabaseServerFoundation
import DatabaseServerRuntime
import StorageKitSystemClock

public enum NativeDatabaseOperationApplicationFactory {
    public static func schemaDriven(
        version: String,
        sqlTablePolicies: [SQLTablePolicy] = [],
        entityPolicies: [DatabaseServerLaunchConfiguration.EntityPolicy] = []
    ) throws -> AnyDatabaseOperationApplication {
        try SQLTablePolicy.validate(sqlTablePolicies)
        try DatabaseServerLaunchConfiguration.validateEntityPolicies(entityPolicies)
        let policies = Dictionary(uniqueKeysWithValues: sqlTablePolicies.map {
            (SQLTablePolicy.Target(schema: $0.schema, table: $0.table),
             $0.roles.mapValues { Set($0) })
        })
        let entityRoles = Dictionary(uniqueKeysWithValues: entityPolicies.map {
            ($0.entity, $0.roles.mapValues { Set($0) })
        })
        let schemaRuntimeFactory = AnyDatabaseSchemaRuntimeFactory(
            SchemaDrivenDatabaseRuntimeFactory(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-server.schema-driven@\(version)",
                    revision: 1
                ),
                // Entity rules bind schema-driven entities, including ones
                // published after startup. Framework replaces the binding of
                // every SQL-owned entity with its sqlTablePolicies decision.
                schemaDrivenAuthorizationPolicyFactory: { entity in
                    guard let roles = entityRoles[entity.name] else { return nil }
                    return AuthorizationPolicyHandler(schemaDriven: entity) { operation, authorization in
                        guard let principal = authorization.principal,
                              let allowed = roles[operation.rawValue] else { return false }
                        return !principal.roles.isDisjoint(with: allowed)
                    }
                },
                sqlAuthorizationPolicyFactory: { entity, namespace, relation in
                    guard let roles = policies[SQLTablePolicy.Target(
                        schema: namespace.name, table: relation
                    )] else { return nil }
                    return AuthorizationPolicyHandler(schemaDriven: entity) { operation, authorization in
                        guard let principal = authorization.principal,
                              let allowed = roles[operation.rawValue] else { return false }
                        return !principal.roles.isDisjoint(with: allowed)
                    }
                }
            )
        )
        let runtimeLimits = DatabaseOperationLimits.default
        let identifierGenerator = RandomDatabaseUUIDGenerator()
        let operationRegistry = try DatabaseResumableOperationRegistry(
            operations: [
                AnyDatabaseResumableOperation(
                    DatabaseMaintenanceResumableOperation(
                        runtimeLimits: runtimeLimits
                    )
                )
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
