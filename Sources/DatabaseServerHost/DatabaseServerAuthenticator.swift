import DatabaseKit
import DatabaseWireRuntime

public struct DatabaseServerAuthentication: Sendable, Hashable {
    public let authorization: AuthorizationContext
    public let jobAuthorizationReference: DatabaseJobAuthorizationReference

    public init(
        authorization: AuthorizationContext,
        jobAuthorizationReference: DatabaseJobAuthorizationReference
    ) {
        self.authorization = authorization
        self.jobAuthorizationReference = jobAuthorizationReference
    }
}

public protocol DatabaseServerAuthenticator:
    DatabaseJobAuthorizationValidating,
    Sendable {
    func authenticate(
        _ credential: DatabaseServerCredential
    ) async throws -> DatabaseServerAuthentication
}
