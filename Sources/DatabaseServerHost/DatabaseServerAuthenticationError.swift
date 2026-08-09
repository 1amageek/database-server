public enum DatabaseServerAuthenticationError:
    Error,
    Sendable,
    Equatable
{
    case malformedCredential
    case invalidCredential
    case revokedCredential
    case invalidRegistry
    case invalidRegistryPermissions
    case registryWriteFailed
}
