import DatabaseKit
import DatabaseTypes
import DatabaseWire
import Testing
@testable import DatabaseServerRuntime

@Suite("Database request digest")
struct DatabaseRequestDigestTests {
    @Test("Digests bind both operation and payload")
    func bindsOperationAndPayload() throws {
        let query = DatabaseRequestDigest.compute(
            operation: .queryExecute,
            payload: [1, 2, 3]
        )
        let mutation = DatabaseRequestDigest.compute(
            operation: .mutationExecute,
            payload: [1, 2, 3]
        )
        let differentPayload = DatabaseRequestDigest.compute(
            operation: .queryExecute,
            payload: [1, 2, 4]
        )

        #expect(query.count == DatabaseRequestDigest.byteCount)
        #expect(query != mutation)
        #expect(query != differentPayload)

        #if DATABASE_SERVER_MULTIPLE_BASES
        let baseA = try Base.ID("a")
        let baseB = try Base.ID("b")
        let encodedBaseB: ByteString = [
            0, 0, 0, 0, 0, 0, 0, 1,
            0x62,
        ]
        let oneMemberWithSuffix = DatabaseRequestDigest.computeRequest(
            operation: .queryExecute,
            target: .composition(try .derived([baseA])),
            prefix: encodedBaseB,
            payload: []
        )
        let twoMembers = DatabaseRequestDigest.computeRequest(
            operation: .queryExecute,
            target: .composition(try .derived([baseA, baseB])),
            payload: []
        )
        #expect(oneMemberWithSuffix != twoMembers)
        #endif
    }
}
