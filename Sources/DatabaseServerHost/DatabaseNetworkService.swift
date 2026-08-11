import DatabaseWireRuntime
import DatabaseTypes
import Foundation
import Hummingbird
import HummingbirdCore
import HummingbirdTLS
import HummingbirdWebSocket
import HTTPTypes
import NIOCore
import ServiceLifecycle

public final class DatabaseNetworkService: Service, Sendable {
    private static let databaseIDHeader = HTTPField.Name("x-database-id")!
    private static let tenantIDHeader = HTTPField.Name("x-tenant-id")!
    private static let workspaceIDHeader = HTTPField.Name("x-workspace-id")!
    private static let wireContentType = "application/octet-stream"
    private static let endpointPath = "/v1/database"

    private let application: any Service
    private let executor: any DatabaseServerRequestExecuting

    public init(
        configuration: DatabaseServerHostConfiguration,
        executor: any DatabaseServerRequestExecuting,
        onServerRunning: @escaping @Sendable (any Channel) async -> Void = {
            _ in
        }
    ) throws {
        guard configuration.routingIdentity == executor.routingIdentity else {
            throw DatabaseNetworkServiceError.routingIdentityMismatch
        }
        self.executor = executor
        let router = Router()
        router.post("/v1/database") { request, _ in
            await Self.respond(
                to: request,
                executor: executor,
                maximumFrameBytes: configuration.maximumFrameBytes
            )
        }
        router.get("/v1/database") { request, _ in
            await Self.respondToNonUpgrade(
                request,
                executor: executor
            )
        }

        let webSocketBuilder = HTTPServerBuilder.http1WebSocketUpgrade(
            configuration: .init(
                ws: .init(maxFrameSize: configuration.maximumFrameBytes)
            )
        ) { request, _, _ in
            guard request.path == Self.endpointPath else {
                return .dontUpgrade
            }
            let executionContext: DatabaseRequestExecutionContext
            do {
                executionContext = try await Self.authorize(
                    headers: request.headerFields,
                    executor: executor
                )
            } catch {
                return .dontUpgrade
            }
            return .upgrade([:]) { inbound, outbound, _ in
                let writer = DatabaseWebSocketResponseWriter(outbound)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var activeRequestCount = 0
                    for try await message in inbound.messages(
                        maxSize: configuration.maximumFrameBytes
                    ) {
                        guard case .binary(let buffer) = message else {
                            throw DatabaseNetworkServiceError
                                .binaryWebSocketMessageRequired
                        }
                        if activeRequestCount
                                == configuration
                                    .maximumConcurrentWebSocketRequests {
                            try await group.next()
                            activeRequestCount -= 1
                        }
                        let requestBytes = ByteString(
                            retainingReadableBytes: buffer
                        )
                        group.addTask {
                            let response = try await executor.execute(
                                requestBytes,
                                context: executionContext
                            )
                            try await writer.write(response)
                        }
                        activeRequestCount += 1
                    }
                    while activeRequestCount > 0 {
                        try await group.next()
                        activeRequestCount -= 1
                    }
                }
            }
        }
        let serverBuilder: HTTPServerBuilder
        if let tls = configuration.tls {
            let certificates = try NIOSSLCertificate.fromPEMFile(
                tls.certificateChainURL.path
            )
            let privateKey = try NIOSSLPrivateKey(
                file: tls.privateKeyURL.path,
                format: .pem
            )
            let tlsConfiguration = TLSConfiguration.makeServerConfiguration(
                certificateChain: certificates.map { .certificate($0) },
                privateKey: .privateKey(privateKey)
            )
            serverBuilder = try .tls(
                webSocketBuilder,
                tlsConfiguration: tlsConfiguration
            )
        } else {
            serverBuilder = webSocketBuilder
        }
        self.application = Application(
            router: router,
            server: serverBuilder,
            configuration: .init(
                address: .hostname(
                    configuration.host,
                    port: configuration.port
                ),
                serverName: "database-server"
            ),
            onServerRunning: onServerRunning
        )
    }

    public func run() async throws {
        do {
            try await application.run()
            await executor.shutdown()
        } catch {
            await executor.shutdown()
            throw error
        }
    }

    private static func respond(
        to request: Request,
        executor: any DatabaseServerRequestExecuting,
        maximumFrameBytes: Int
    ) async -> Response {
        guard isWireContentType(request.headers[.contentType]) else {
            return errorResponse(
                status: .badRequest,
                code: "unsupported_content_type"
            )
        }
        let executionContext: DatabaseRequestExecutionContext
        do {
            executionContext = try await authorize(
                headers: request.headers,
                executor: executor
            )
        } catch {
            return authorizationErrorResponse(error)
        }
        let body: ByteBuffer
        do {
            body = try await request.body.collect(upTo: maximumFrameBytes)
        } catch is NIOTooManyBytesError {
            return errorResponse(
                status: .contentTooLarge,
                code: "request_too_large"
            )
        } catch {
            return errorResponse(
                status: .badRequest,
                code: "invalid_request_body"
            )
        }
        do {
            let response = try await executor.execute(
                ByteString(retainingReadableBytes: body),
                context: executionContext
            )
            var headers = HTTPFields()
            headers[.contentType] = wireContentType
            return Response(
                status: .ok,
                headers: headers,
                body: .init(byteBuffer: response.makeByteBuffer())
            )
        } catch is DatabaseHostedRuntimeError {
            return errorResponse(
                status: .serviceUnavailable,
                code: "server_shutting_down"
            )
        } catch is DatabaseServerAuthenticationError {
            return errorResponse(
                status: .unauthorized,
                code: "authentication_failed"
            )
        } catch is DatabaseJobAuthorizationError {
            return errorResponse(
                status: .unauthorized,
                code: "authentication_failed"
            )
        } catch {
            return errorResponse(
                status: .badRequest,
                code: "invalid_wire_request"
            )
        }
    }

    private static func respondToNonUpgrade(
        _ request: Request,
        executor: any DatabaseServerRequestExecuting
    ) async -> Response {
        do {
            _ = try await authorize(
                headers: request.headers,
                executor: executor
            )
            return errorResponse(
                status: .badRequest,
                code: "websocket_upgrade_required"
            )
        } catch {
            return authorizationErrorResponse(error)
        }
    }

    private static func authorize(
        headers: HTTPFields,
        executor: any DatabaseServerRequestExecuting
    ) async throws -> DatabaseRequestExecutionContext {
        try await executor.authorize(
            authorizationHeader: headers[.authorization],
            databaseID: headers[databaseIDHeader],
            tenantID: headers[tenantIDHeader],
            workspaceID: headers[workspaceIDHeader]
        )
    }

    private static func isWireContentType(_ value: String?) -> Bool {
        guard let value else { return false }
        let mediaType = value.split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mediaType == wireContentType
    }

    private static func authorizationErrorResponse(_ error: any Error)
        -> Response
    {
        if error is DatabaseServerRoutingError
            || error as? DatabaseServerRequestError == .routingMismatch {
            return errorResponse(
                status: .forbidden,
                code: "routing_mismatch"
            )
        }
        return errorResponse(
            status: .unauthorized,
            code: "authentication_failed"
        )
    }

    private static func errorResponse(
        status: HTTPResponse.Status,
        code: String
    ) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        let body = ByteBuffer(string: "{\"error\":\"\(code)\"}")
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: body)
        )
    }
}

private actor DatabaseWebSocketResponseWriter {
    private let outbound: WebSocketOutboundWriter

    init(_ outbound: WebSocketOutboundWriter) {
        self.outbound = outbound
    }

    func write(_ response: ByteString) async throws {
        try await outbound.write(.binary(response.makeByteBuffer()))
    }
}

public enum DatabaseNetworkServiceError: Error, Sendable, Equatable {
    case binaryWebSocketMessageRequired
    case routingIdentityMismatch
}
