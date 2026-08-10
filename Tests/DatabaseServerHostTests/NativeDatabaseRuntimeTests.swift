import DatabaseKit
import DatabaseServer
@_spi(DatabaseServer) import DatabaseWire
@testable import DatabaseServerHost
import Testing

@Suite("Native database runtime", .serialized)
struct NativeDatabaseRuntimeTests {
    @Test("An empty schema-driven database executes capabilities")
    func emptyDatabaseExecutesCapabilities() async throws {
        let environment = try await NativeDatabaseRuntimeEnvironment.open(
            storageTopology: .single(storage: .sqliteMemory),
            version: "native-runtime-test"
        )
        do {
            let request = try DatabaseWireEncoder().encodeRequest(
                DatabaseOperations.capabilitiesDescribe,
                requestID: 1,
                target: .database,
                request: EmptyOperationPayload()
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
                DatabaseOperations.capabilitiesDescribe,
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
        await #expect(throws: DatabaseHostedRuntimeError.shuttingDown) {
            let request = try DatabaseWireEncoder().encodeRequest(
                DatabaseOperations.capabilitiesDescribe,
                requestID: 2,
                target: .database,
                request: EmptyOperationPayload()
            )
            _ = try await environment.runtime.execute(
                request,
                authorization: DatabaseRequestExecutionContext(
                    authorization: .anonymous
                )
            )
        }
    }

    @Test("A native host owns multiple storage domains as one topology")
    func multipleStorageDomainsOpenAndShutdownTogether() async throws {
        let environment = try await NativeDatabaseRuntimeEnvironment.open(
            storageTopology: NativeDatabaseStorageTopologyConfiguration(
                controlDomainID: "primary",
                domains: [
                    .init(
                        id: "primary",
                        namespacePath: ["database", "main"],
                        storage: .sqliteMemory
                    ),
                    .init(
                        id: "secondary",
                        namespacePath: ["database", "secondary"],
                        storage: .sqliteMemory
                    ),
                ],
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
            ),
            version: "multi-domain-runtime-test"
        )
        do {
            let request = try DatabaseWireEncoder().encodeRequest(
                DatabaseOperations.capabilitiesDescribe,
                requestID: 3,
                target: .database,
                request: EmptyOperationPayload()
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
                DatabaseOperations.capabilitiesDescribe,
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
}
