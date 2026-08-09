import DatabaseKit

public protocol DatabaseServerAuthenticator: Sendable {
    func authenticate(
        _ credential: DatabaseServerCredential
    ) async throws -> AuthorizationContext
}
