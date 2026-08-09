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
            storage: .sqliteMemory,
            version: "native-runtime-test"
        )
        do {
            let request = try DatabaseWireEncoder().encodeRequest(
                DatabaseOperations.capabilitiesDescribe,
                requestID: 1,
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
}
