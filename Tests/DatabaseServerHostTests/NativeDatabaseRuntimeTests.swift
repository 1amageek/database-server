import DatabaseKit
import DatabaseServerRuntime
@_spi(DatabaseExecution) import DatabaseWire
@testable import DatabaseServerHost
import Testing

@Suite("Native database runtime", .serialized)
struct NativeDatabaseRuntimeTests {
    @Test("An empty schema-driven database executes capabilities")
    func emptyDatabaseExecutesCapabilities() async throws {
        let environment = try await openNativeRuntime(
            authenticator: try NativeRuntimeTestAuthenticator(),
            version: "native-runtime-test"
        )
        do {
            let request = try databaseServerHostCapabilitiesRequest(
                requestID: 1
            )
            let responseBytes = try await environment.runtime.execute(
                request,
                authorization: DatabaseRequestExecutionContext(
                    authorization: .authenticated(
                        Principal(identifier: "test", roles: ["admin"])
                    )
                )
            )
            let response = try DatabaseWireDecoder().decodeResponse(
                DatabaseOperationCatalog.capabilitiesDescribe,
                from: responseBytes,
                matching: 1
            )

            let payload = try response.get()
            #expect(payload.runtimeVersion == "native-runtime-test")
            #expect(
                payload.features.contains {
                    $0.identifier == "schema.execute" && $0.version == 1
                }
            )
        } catch {
            await environment.shutdown()
            throw error
        }
        await environment.shutdown()
        await #expect(throws: DatabaseOperationInstanceError.shuttingDown) {
            let request = try databaseServerHostCapabilitiesRequest(
                requestID: 2
            )
            _ = try await environment.runtime.execute(
                request,
                authorization: DatabaseRequestExecutionContext(
                    authorization: .anonymous
                )
            )
        }
    }

    #if DATABASE_SERVER_HOST_MULTI_BASE
    @Test("A native host owns multiple storage domains as one topology")
    func multipleStorageDomainsOpenAndShutdownTogether() async throws {
        let environment = try await NativeDatabaseRuntimeEnvironment.open(
            storageTopology: multipleDomainTopology(),
            authenticator: try NativeRuntimeTestAuthenticator(),
            version: "multi-domain-runtime-test"
        )
        do {
            let request = try databaseServerHostCapabilitiesRequest(
                requestID: 3
            )
            let responseBytes = try await environment.runtime.execute(
                request,
                authorization: DatabaseRequestExecutionContext(
                    authorization: .authenticated(
                        Principal(identifier: "test", roles: ["admin"])
                    )
                )
            )
            let response = try DatabaseWireDecoder().decodeResponse(
                DatabaseOperationCatalog.capabilitiesDescribe,
                from: responseBytes,
                matching: 3
            )
            #expect(try response.get().runtimeVersion == "multi-domain-runtime-test")
        } catch {
            await environment.shutdown()
            throw error
        }
        await environment.shutdown()
    }
    #endif

    @Test("Every request revalidates its credential reference")
    func requestsObserveCredentialRevocation() async throws {
        let authenticator = try RevocableNativeRuntimeAuthenticator()
        let environment = try await openNativeRuntime(
            authenticator: authenticator,
            version: "credential-revalidation-test"
        )
        let executor = environment.makeRequestExecutor(
            routingIdentity: try DatabaseServerRoutingIdentity(
                databaseID: "revalidation-test"
            )
        )
        do {
            let context = try await executor.authorize(
                authorizationHeader: "Bearer valid",
                databaseID: "revalidation-test",
                tenantID: nil,
                workspaceID: nil
            )
            let request = try databaseServerHostCapabilitiesRequest(
                requestID: 4
            )
            _ = try await executor.execute(request, context: context)
            await authenticator.revoke()
            await #expect(
                throws: DatabaseServerAuthenticationError.revokedCredential
            ) {
                _ = try await executor.execute(request, context: context)
            }
        } catch {
            await environment.shutdown()
            throw error
        }
        await environment.shutdown()
    }
}

private func openNativeRuntime(
    authenticator: any DatabaseServerAuthenticator,
    version: String
) async throws -> NativeDatabaseRuntimeEnvironment {
    #if DATABASE_SERVER_HOST_MULTI_BASE
    try await NativeDatabaseRuntimeEnvironment.open(
        storageTopology: .single(
            storage: .sqliteMemory,
            namespacePath: ["database", "test"]
        ),
        authenticator: authenticator,
        version: version
    )
    #else
    try await NativeDatabaseRuntimeEnvironment.open(
        storage: .sqliteMemory,
        databaseRoot: .engine,
        authenticator: authenticator,
        version: version
    )
    #endif
}

#if DATABASE_SERVER_HOST_MULTI_BASE
private func multipleDomainTopology()
    -> NativeDatabaseStorageTopologyConfiguration
{
    let domains = [
        NativeDatabaseStorageDomainConfiguration(
            id: "primary",
            namespacePath: ["database", "main"],
            storage: .sqliteMemory
        ),
        NativeDatabaseStorageDomainConfiguration(
            id: "secondary",
            namespacePath: ["database", "secondary"],
            storage: .sqliteMemory
        ),
    ]
    return NativeDatabaseStorageTopologyConfiguration(
        controlDomainID: "primary",
        domains: domains,
        placements: [
            .init(
                id: "default",
                domainID: "primary",
                path: ["bases"]
            ),
            .init(
                id: "secondary",
                domainID: "secondary",
                path: ["bases"]
            ),
        ],
        defaultPlacementID: "default"
    )
}
#endif

private struct NativeRuntimeTestAuthenticator: DatabaseServerAuthenticator {
    let reference: DatabaseJobAuthorizationReference

    init() throws {
        self.reference = try DatabaseJobAuthorizationReference(
            "native-runtime-test"
        )
    }

    func authenticate(
        _ credential: DatabaseServerCredential
    ) async throws -> DatabaseServerAuthentication {
        _ = credential
        return DatabaseServerAuthentication(
            authorization: authorization,
            jobAuthorizationReference: reference
        )
    }

    func revalidate(
        _ reference: DatabaseJobAuthorizationReference
    ) async throws -> AuthorizationContext {
        guard reference == self.reference else {
            throw DatabaseServerAuthenticationError.invalidCredential
        }
        return authorization
    }

    private var authorization: AuthorizationContext {
        .authenticated(
            Principal(identifier: "test", roles: ["admin"])
        )
    }
}

private actor RevocableNativeRuntimeAuthenticator:
    DatabaseServerAuthenticator
{
    private let reference: DatabaseJobAuthorizationReference
    private var isRevoked = false

    init() throws {
        self.reference = try DatabaseJobAuthorizationReference(
            "revocable-native-runtime-test"
        )
    }

    func authenticate(
        _ credential: DatabaseServerCredential
    ) async throws -> DatabaseServerAuthentication {
        guard credential == .bearer("valid"), !isRevoked else {
            throw DatabaseServerAuthenticationError.invalidCredential
        }
        return DatabaseServerAuthentication(
            authorization: authorization,
            jobAuthorizationReference: reference
        )
    }

    func revalidate(
        _ reference: DatabaseJobAuthorizationReference
    ) async throws -> AuthorizationContext {
        guard reference == self.reference else {
            throw DatabaseServerAuthenticationError.invalidCredential
        }
        guard !isRevoked else {
            throw DatabaseServerAuthenticationError.revokedCredential
        }
        return authorization
    }

    func revoke() {
        isRevoked = true
    }

    private var authorization: AuthorizationContext {
        .authenticated(
            Principal(identifier: "revocable-test", roles: ["admin"])
        )
    }
}
