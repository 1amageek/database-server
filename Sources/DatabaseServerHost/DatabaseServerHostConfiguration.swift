import DatabaseWire
import Foundation

public struct DatabaseServerTLSConfiguration: Sendable, Hashable {
    public let certificateChainURL: URL
    public let privateKeyURL: URL

    public init(certificateChainURL: URL, privateKeyURL: URL) {
        self.certificateChainURL = certificateChainURL
        self.privateKeyURL = privateKeyURL
    }
}

public struct DatabaseServerHostConfiguration: Sendable, Hashable {
    public let host: String
    public let port: Int
    public let routingIdentity: DatabaseServerRoutingIdentity
    public let tls: DatabaseServerTLSConfiguration?
    public let maximumFrameBytes: Int
    public let maximumConcurrentWebSocketRequests: Int
    package let wireLimits: DatabaseWireLimits

    public init(
        host: String = "127.0.0.1",
        port: Int = 7_878,
        routingIdentity: DatabaseServerRoutingIdentity,
        tls: DatabaseServerTLSConfiguration? = nil,
        maximumFrameBytes: Int = DatabaseWireLimits.default.maximumFrameBytes,
        maximumConcurrentWebSocketRequests: Int = 8
    ) throws(DatabaseServerHostConfigurationError) {
        guard !host.isEmpty else {
            throw .invalidHost
        }
        guard (0...65_535).contains(port) else {
            throw .invalidPort
        }
        guard maximumFrameBytes > 0,
              maximumFrameBytes <= Int(UInt32.max) else {
            throw .invalidMaximumFrameBytes
        }
        guard (1...64).contains(maximumConcurrentWebSocketRequests) else {
            throw .invalidMaximumConcurrentWebSocketRequests
        }
        if !Self.isLoopback(host), tls == nil {
            throw .nonLoopbackRequiresTLS
        }
        if !Self.isLoopback(host),
           (routingIdentity.tenantID == nil
                || routingIdentity.workspaceID == nil) {
            throw .nonLoopbackRequiresCompleteRoutingIdentity
        }
        self.host = host
        self.port = port
        self.routingIdentity = routingIdentity
        self.tls = tls
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumConcurrentWebSocketRequests =
            maximumConcurrentWebSocketRequests
        do {
            self.wireLimits = try Self.wireLimits(
                maximumFrameBytes: maximumFrameBytes
            )
        } catch {
            throw .invalidMaximumFrameBytes
        }
    }

    package static func wireLimits(
        maximumFrameBytes: Int
    ) throws -> DatabaseWireLimits {
        let canonical = DatabaseWireLimits.default
        return try DatabaseWireLimits(
            maximumFrameBytes: maximumFrameBytes,
            maximumStringBytes: min(
                canonical.maximumStringBytes,
                maximumFrameBytes
            ),
            maximumByteStringBytes: min(
                canonical.maximumByteStringBytes,
                maximumFrameBytes
            ),
            maximumCollectionCount: canonical.maximumCollectionCount,
            maximumNestingDepth: canonical.maximumNestingDepth,
            maximumObjectCount: canonical.maximumObjectCount
        )
    }

    public static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host == "localhost"
    }
}

public enum DatabaseServerHostConfigurationError:
    Error,
    Sendable,
    Equatable
{
    case invalidHost
    case invalidPort
    case invalidMaximumFrameBytes
    case invalidMaximumConcurrentWebSocketRequests
    case nonLoopbackRequiresTLS
    case nonLoopbackRequiresCompleteRoutingIdentity
}
