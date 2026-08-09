import DatabaseServer
import DatabaseTypes

public protocol DatabaseServerRequestExecuting: Sendable {
    var routingIdentity: DatabaseServerRoutingIdentity { get }

    func authorize(
        authorizationHeader: String?,
        databaseID: String?,
        tenantID: String?,
        workspaceID: String?
    ) async throws -> DatabaseRequestExecutionContext

    func execute(
        _ request: ByteString,
        context: DatabaseRequestExecutionContext
    ) async throws -> ByteString

    func shutdown() async
}

public final class DatabaseServerRequestExecutor:
    DatabaseServerRequestExecuting,
    Sendable
{
    private let authenticator: any DatabaseServerAuthenticator
    public let routingIdentity: DatabaseServerRoutingIdentity
    private let runtime: DatabaseHostedRuntime
    private let prepareForShutdown: @Sendable () async -> Void

    public init(
        authenticator: any DatabaseServerAuthenticator,
        routingIdentity: DatabaseServerRoutingIdentity,
        runtime: DatabaseHostedRuntime,
        prepareForShutdown: @escaping @Sendable () async -> Void = {}
    ) {
        self.authenticator = authenticator
        self.routingIdentity = routingIdentity
        self.runtime = runtime
        self.prepareForShutdown = prepareForShutdown
    }

    public func authorize(
        authorizationHeader: String?,
        databaseID: String?,
        tenantID: String?,
        workspaceID: String?
    ) async throws -> DatabaseRequestExecutionContext {
        let credential = try Self.parseCredential(authorizationHeader)
        let authorization = try await authenticator.authenticate(credential)
        do {
            try routingIdentity.validate(
                databaseID: databaseID,
                tenantID: tenantID,
                workspaceID: workspaceID
            )
        } catch {
            throw DatabaseServerRequestError.routingMismatch
        }
        return DatabaseRequestExecutionContext(
            authorization: authorization
        )
    }

    public func execute(
        _ request: ByteString,
        context: DatabaseRequestExecutionContext
    ) async throws -> ByteString {
        try await runtime.execute(request, authorization: context)
    }

    public func shutdown() async {
        await prepareForShutdown()
        await runtime.shutdown()
    }

    private static func parseCredential(
        _ header: String?
    ) throws(DatabaseServerRequestError) -> DatabaseServerCredential {
        guard let header else {
            throw .missingCredential
        }
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else {
            throw .malformedCredential
        }
        let token = header.dropFirst(prefix.count)
        guard !token.isEmpty,
              !token.contains(where: { $0.isWhitespace }) else {
            throw .malformedCredential
        }
        return .bearer(String(token))
    }
}

public enum DatabaseServerRequestError: Error, Sendable, Equatable {
    case missingCredential
    case malformedCredential
    case routingMismatch
}
