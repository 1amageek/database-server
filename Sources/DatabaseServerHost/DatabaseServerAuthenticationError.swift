public enum DatabaseServerAuthenticationError:
    Error,
    Sendable,
    Equatable
{
    case malformedCredential
    case invalidCredential
    case revokedCredential
    case claimsNotSupported
    case invalidPrincipal
    case invalidRegistry
    case invalidRegistryPermissions
    case registryWriteFailed
}
