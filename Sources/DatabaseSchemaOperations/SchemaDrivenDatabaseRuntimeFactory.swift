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
    private let sqlAuthorizationPolicyFactory: (@Sendable (
        Schema.Entity, SQLNamespace, String
    ) -> AuthorizationPolicyHandler?)?

    public init(
        executionIdentity: DatabaseExecutionRuntimeIdentity,
        authorizationPolicies: [AuthorizationPolicyHandler] = [],
        sqlAuthorizationPolicyFactory: (@Sendable (
            Schema.Entity, SQLNamespace, String
        ) -> AuthorizationPolicyHandler?)? = nil
    ) {
        self.executionIdentity = executionIdentity
        self.authorizationPolicies = authorizationPolicies
        self.sqlAuthorizationPolicyFactory = sqlAuthorizationPolicyFactory
    }

    public func makeOperationConfiguration(
        for schema: Schema
    ) async throws -> DatabaseRuntimeConfiguration {
        try DatabaseFrameworkRuntime.configuration(
            executionIdentity: executionIdentity,
            schema: schema,
            authorizationPolicies: authorizationPolicies,
            sqlAuthorizationPolicyFactory: sqlAuthorizationPolicyFactory
        )
    }
}
