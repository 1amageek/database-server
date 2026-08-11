import DatabaseWireRuntime
import DatabaseKit
import DatabaseTypes
import Foundation
@testable import DatabaseServerHost
import NIOCore
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Database network service", .serialized)
struct DatabaseNetworkServiceTests {
    @Test("Network service rejects a host and executor routing mismatch")
    func rejectsRoutingConfigurationMismatch() throws {
        let executor = try EchoRequestExecutor()
        let configuration = try DatabaseServerHostConfiguration(
            port: 0,
            routingIdentity: DatabaseServerRoutingIdentity(
                databaseID: "another-database"
            ),
            hasAuthenticator: true
        )

        #expect(throws: DatabaseNetworkServiceError.routingIdentityMismatch) {
            _ = try DatabaseNetworkService(
                configuration: configuration,
                executor: executor
            )
        }
    }

    @Test("HTTP enforces authentication, routing, content type, and body limits")
    func httpBoundary() async throws {
        let executor = try EchoRequestExecutor()
        let running = AsyncStream.makeStream(of: Int.self)
        let configuration = try DatabaseServerHostConfiguration(
            port: 0,
            routingIdentity: try DatabaseServerRoutingIdentity(
                databaseID: "world",
                tenantID: "company-a",
                workspaceID: "private"
            ),
            maximumFrameBytes: 8,
            hasAuthenticator: true
        )
        let service = try DatabaseNetworkService(
            configuration: configuration,
            executor: executor,
            onServerRunning: { channel in
                if let port = channel.localAddress?.port {
                    running.continuation.yield(port)
                }
            }
        )
        let serviceTask = Task {
            try await service.run()
        }
        guard let port = await running.stream.first(where: { _ in true }) else {
            serviceTask.cancel()
            throw NetworkServiceTestError.missingPort
        }
        do {
            guard let endpoint = URL(
                string: "http://127.0.0.1:\(port)/v1/database"
            ) else {
                throw NetworkServiceTestError.invalidEndpoint
            }
            var request = authorizedRequest(endpoint: endpoint)
            request.httpBody = Data([1, 2, 3])
            let (body, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(body == Data([1, 2, 3]))

            var missingAuthentication = request
            missingAuthentication.setValue(
                nil,
                forHTTPHeaderField: "Authorization"
            )
            let (_, unauthorized) = try await URLSession.shared.data(
                for: missingAuthentication
            )
            #expect((unauthorized as? HTTPURLResponse)?.statusCode == 401)

            var routingMismatch = request
            routingMismatch.setValue(
                "company-b",
                forHTTPHeaderField: "x-tenant-id"
            )
            let (_, forbidden) = try await URLSession.shared.data(
                for: routingMismatch
            )
            #expect((forbidden as? HTTPURLResponse)?.statusCode == 403)

            var wrongContentType = request
            wrongContentType.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            let (_, unsupported) = try await URLSession.shared.data(
                for: wrongContentType
            )
            #expect((unsupported as? HTTPURLResponse)?.statusCode == 400)

            var oversized = request
            oversized.httpBody = Data(repeating: 1, count: 9)
            let (_, tooLarge) = try await URLSession.shared.data(for: oversized)
            #expect((tooLarge as? HTTPURLResponse)?.statusCode == 413)

            var revoked = request
            revoked.httpBody = Data([0xFF])
            let (_, revokedResponse) = try await URLSession.shared.data(
                for: revoked
            )
            #expect((revokedResponse as? HTTPURLResponse)?.statusCode == 401)
            #expect(await executor.executionCount == 1)
        } catch {
            serviceTask.cancel()
            _ = await serviceTask.result
            throw error
        }
        serviceTask.cancel()
        _ = await serviceTask.result
        #expect(await executor.shutdownCount == 1)
    }

    @Test("WebSocket accepts only authenticated binary DatabaseWire messages")
    func webSocketBoundary() async throws {
        let executor = try EchoRequestExecutor()
        let running = AsyncStream.makeStream(of: Int.self)
        let configuration = try DatabaseServerHostConfiguration(
            port: 0,
            routingIdentity: try DatabaseServerRoutingIdentity(
                databaseID: "world",
                tenantID: "company-a",
                workspaceID: "private"
            ),
            maximumFrameBytes: 8,
            hasAuthenticator: true
        )
        let service = try DatabaseNetworkService(
            configuration: configuration,
            executor: executor,
            onServerRunning: { channel in
                if let port = channel.localAddress?.port {
                    running.continuation.yield(port)
                }
            }
        )
        let serviceTask = Task {
            try await service.run()
        }
        guard let port = await running.stream.first(where: { _ in true }) else {
            serviceTask.cancel()
            throw NetworkServiceTestError.missingPort
        }
        do {
            guard let endpoint = URL(
                string: "ws://127.0.0.1:\(port)/v1/database"
            ) else {
                throw NetworkServiceTestError.invalidEndpoint
            }
            var request = authorizedRequest(endpoint: endpoint)
            request.httpMethod = "GET"
            request.setValue(nil, forHTTPHeaderField: "Content-Type")
            let task = URLSession.shared.webSocketTask(with: request)
            task.resume()
            try await task.send(.data(Data([4, 5, 6])))
            let message = try await task.receive()
            guard case .data(let data) = message else {
                throw NetworkServiceTestError.nonBinaryResponse
            }
            #expect(data == Data([4, 5, 6]))
            task.cancel(with: .normalClosure, reason: nil)
        } catch {
            serviceTask.cancel()
            _ = await serviceTask.result
            throw error
        }
        serviceTask.cancel()
        _ = await serviceTask.result
        #expect(await executor.shutdownCount == 1)
    }

    @Test("WebSocket requests execute concurrently with serialized writes")
    func webSocketDoesNotHeadOfLineBlock() async throws {
        let executor = try OutOfOrderEchoRequestExecutor()
        let running = AsyncStream.makeStream(of: Int.self)
        let configuration = try DatabaseServerHostConfiguration(
            port: 0,
            routingIdentity: try DatabaseServerRoutingIdentity(
                databaseID: "world",
                tenantID: "company-a",
                workspaceID: "private"
            ),
            maximumFrameBytes: 8,
            maximumConcurrentWebSocketRequests: 2,
            hasAuthenticator: true
        )
        let service = try DatabaseNetworkService(
            configuration: configuration,
            executor: executor,
            onServerRunning: { channel in
                if let port = channel.localAddress?.port {
                    running.continuation.yield(port)
                }
            }
        )
        let serviceTask = Task { try await service.run() }
        guard let port = await running.stream.first(where: { _ in true }),
              let endpoint = URL(
                string: "ws://127.0.0.1:\(port)/v1/database"
              ) else {
            serviceTask.cancel()
            throw NetworkServiceTestError.missingPort
        }
        do {
            var request = authorizedRequest(endpoint: endpoint)
            request.httpMethod = "GET"
            request.setValue(nil, forHTTPHeaderField: "Content-Type")
            let task = URLSession.shared.webSocketTask(with: request)
            task.resume()
            try await task.send(.data(Data([1])))
            try await task.send(.data(Data([2])))
            let first = try await task.receive()
            let second = try await task.receive()
            guard case .data(let firstData) = first,
                  case .data(let secondData) = second else {
                throw NetworkServiceTestError.nonBinaryResponse
            }
            #expect(firstData == Data([2]))
            #expect(secondData == Data([1]))
            task.cancel(with: .normalClosure, reason: nil)
        } catch {
            serviceTask.cancel()
            _ = await serviceTask.result
            throw error
        }
        serviceTask.cancel()
        _ = await serviceTask.result
        #expect(await executor.shutdownCount == 1)
    }

    @Test("TLS serves the authenticated DatabaseWire endpoint")
    func tlsBoundary() async throws {
        let executor = try EchoRequestExecutor()
        let running = AsyncStream.makeStream(of: Int.self)
        let fixtureDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TLS", isDirectory: true)
        let configuration = try DatabaseServerHostConfiguration(
            port: 0,
            routingIdentity: try DatabaseServerRoutingIdentity(
                databaseID: "world",
                tenantID: "company-a",
                workspaceID: "private"
            ),
            tls: DatabaseServerTLSConfiguration(
                certificateChainURL: fixtureDirectory
                    .appendingPathComponent("server-cert.pem"),
                privateKeyURL: fixtureDirectory
                    .appendingPathComponent("server-key.pem")
            ),
            maximumFrameBytes: 8,
            hasAuthenticator: true
        )
        let service = try DatabaseNetworkService(
            configuration: configuration,
            executor: executor,
            onServerRunning: { channel in
                if let port = channel.localAddress?.port {
                    running.continuation.yield(port)
                }
            }
        )
        let serviceTask = Task { try await service.run() }
        guard let port = await running.stream.first(where: { _ in true }) else {
            serviceTask.cancel()
            throw NetworkServiceTestError.missingPort
        }
        let session = URLSession(
            configuration: .ephemeral,
            delegate: LocalSelfSignedTLSDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        do {
            guard let endpoint = URL(
                string: "https://127.0.0.1:\(port)/v1/database"
            ) else {
                throw NetworkServiceTestError.invalidEndpoint
            }
            var request = authorizedRequest(endpoint: endpoint)
            request.httpBody = Data([7, 8, 9])
            let (body, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(body == Data([7, 8, 9]))
        } catch {
            serviceTask.cancel()
            _ = await serviceTask.result
            throw error
        }
        serviceTask.cancel()
        _ = await serviceTask.result
        #expect(await executor.shutdownCount == 1)
    }

    private func authorizedRequest(endpoint: URL) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/octet-stream",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("Bearer valid", forHTTPHeaderField: "Authorization")
        request.setValue("world", forHTTPHeaderField: "x-database-id")
        request.setValue("company-a", forHTTPHeaderField: "x-tenant-id")
        request.setValue("private", forHTTPHeaderField: "x-workspace-id")
        return request
    }
}

private actor EchoRequestExecutor: DatabaseServerRequestExecuting {
    nonisolated let routingIdentity: DatabaseServerRoutingIdentity
    private(set) var executionCount = 0
    private(set) var shutdownCount = 0

    init() throws {
        self.routingIdentity = try DatabaseServerRoutingIdentity(
            databaseID: "world",
            tenantID: "company-a",
            workspaceID: "private"
        )
    }

    func authorize(
        authorizationHeader: String?,
        databaseID: String?,
        tenantID: String?,
        workspaceID: String?
    ) async throws -> DatabaseRequestExecutionContext {
        guard authorizationHeader == "Bearer valid" else {
            throw DatabaseServerRequestError.missingCredential
        }
        guard databaseID == "world",
              tenantID == "company-a",
              workspaceID == "private" else {
            throw DatabaseServerRequestError.routingMismatch
        }
        return DatabaseRequestExecutionContext(
            authorization: .authenticated(
                Principal(identifier: "network-test")
            )
        )
    }

    func execute(
        _ request: ByteString,
        context: DatabaseRequestExecutionContext
    ) async throws -> ByteString {
        _ = context
        if request.count == 1, request[request.startIndex] == 0xFF {
            throw DatabaseServerAuthenticationError.revokedCredential
        }
        executionCount += 1
        return request
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

private actor OutOfOrderEchoRequestExecutor:
    DatabaseServerRequestExecuting
{
    nonisolated let routingIdentity: DatabaseServerRoutingIdentity
    private(set) var shutdownCount = 0

    init() throws {
        self.routingIdentity = try DatabaseServerRoutingIdentity(
            databaseID: "world",
            tenantID: "company-a",
            workspaceID: "private"
        )
    }

    func authorize(
        authorizationHeader: String?,
        databaseID: String?,
        tenantID: String?,
        workspaceID: String?
    ) async throws -> DatabaseRequestExecutionContext {
        guard authorizationHeader == "Bearer valid" else {
            throw DatabaseServerRequestError.missingCredential
        }
        guard databaseID == "world",
              tenantID == "company-a",
              workspaceID == "private" else {
            throw DatabaseServerRequestError.routingMismatch
        }
        return DatabaseRequestExecutionContext(
            authorization: .authenticated(
                Principal(identifier: "concurrency-test")
            )
        )
    }

    func execute(
        _ request: ByteString,
        context: DatabaseRequestExecutionContext
    ) async throws -> ByteString {
        _ = context
        if request.count == 1, request[request.startIndex] == 1 {
            try await Task.sleep(for: .milliseconds(200))
        }
        return request
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

private enum NetworkServiceTestError: Error {
    case missingPort
    case invalidEndpoint
    case nonBinaryResponse
}

private final class LocalSelfSignedTLSDelegate:
    NSObject,
    URLSessionDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        _ = session
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
