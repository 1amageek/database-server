@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseJobRuntime
import DatabaseKit
import DatabaseRuntime

/// Runtime factory for a database whose complete execution model comes from a
/// canonical `SchemaManifest` rather than compiled `Persistable` types.
public struct SchemaDrivenDatabaseRuntimeFactory: DatabaseSchemaRuntimeFactory,
    Sendable {
    private let executionIdentity: DatabaseExecutionRuntimeIdentity
    private let authorizationPolicies: [AuthorizationPolicyHandler]

    public init(
        executionIdentity: DatabaseExecutionRuntimeIdentity,
        authorizationPolicies: [AuthorizationPolicyHandler] = []
    ) {
        self.executionIdentity = executionIdentity
        self.authorizationPolicies = authorizationPolicies
    }

    public func makeOperationConfiguration(
        for schema: Schema
    ) async throws -> DatabaseRuntimeConfiguration {
        try DatabaseFrameworkRuntime.configuration(
            executionIdentity: executionIdentity,
            schema: schema,
            authorizationPolicies: authorizationPolicies
        )
    }
}
