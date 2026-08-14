import DatabaseKit
import DatabaseServerRuntime
import Foundation
@testable import DatabaseServerHost
import Testing

@Suite("Database token registry")
struct DatabaseTokenRegistryTests {
    @Test("A registered token authenticates without persisting its raw value")
    func registrationAuthenticationAndSecretStorage() async throws {
        try await withTemporaryDirectory { directory in
            let registryURL = directory.appendingPathComponent("tokens.json")
            let registry = try DatabaseTokenRegistry(fileURL: registryURL)
            let principal = Principal(
                identifier: "local-admin",
                roles: ["admin"]
            )

            let registration = try await registry.register(principal: principal)
            let authentication = try await registry.authenticate(
                .bearer(registration.token.rawValue)
            )
            let storedText = try String(
                contentsOf: registryURL,
                encoding: .utf8
            )

            #expect(authentication.authorization == .authenticated(principal))
            #expect(
                authentication.jobAuthorizationReference.value
                    == registration.token.identifier
            )
            #expect(
                try await registry.revalidate(
                    authentication.jobAuthorizationReference
                ) == .authenticated(principal)
            )
            #expect(!storedText.contains(registration.token.rawValue))
            #expect(storedText.contains(registration.token.identifier))
            let attributes = try FileManager.default.attributesOfItem(
                atPath: registryURL.path
            )
            #expect(
                (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
            )
            let directoryAttributes = try FileManager.default.attributesOfItem(
                atPath: directory.path
            )
            #expect(
                (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
                    == 0o700
            )
            let temporaryFiles = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasSuffix(".tmp") }
            #expect(temporaryFiles.isEmpty)
        }
    }

    @Test("Revocation is durable and rejects the original token")
    func revocationIsDurable() async throws {
        try await withTemporaryDirectory { directory in
            let registryURL = directory.appendingPathComponent("tokens.json")
            let registry = try DatabaseTokenRegistry(fileURL: registryURL)
            let registration = try await registry.register(
                principal: Principal(identifier: "operator")
            )
            try await registry.revoke(
                tokenIdentifier: registration.token.identifier
            )
            let reference = try DatabaseJobAuthorizationReference(
                registration.token.identifier
            )

            await #expect(
                throws: DatabaseServerAuthenticationError.revokedCredential
            ) {
                _ = try await registry.authenticate(
                    .bearer(registration.token.rawValue)
                )
            }
            let reopened = try DatabaseTokenRegistry(fileURL: registryURL)
            await #expect(
                throws: DatabaseServerAuthenticationError.revokedCredential
            ) {
                _ = try await reopened.authenticate(
                    .bearer(registration.token.rawValue)
                )
            }
            await #expect(
                throws: DatabaseServerAuthenticationError.revokedCredential
            ) {
                _ = try await reopened.revalidate(reference)
            }
        }
    }

    @Test("Malformed and unknown tokens are distinct typed failures")
    func malformedAndUnknownTokensFail() async throws {
        try await withTemporaryDirectory { directory in
            let registry = try DatabaseTokenRegistry(
                fileURL: directory.appendingPathComponent("tokens.json")
            )

            await #expect(
                throws: DatabaseServerAuthenticationError.malformedCredential
            ) {
                _ = try await registry.authenticate(.bearer("not-a-token"))
            }
            let unknown = DatabaseServerToken.generate()
            await #expect(
                throws: DatabaseServerAuthenticationError.invalidCredential
            ) {
                _ = try await registry.authenticate(.bearer(unknown.rawValue))
            }
        }
    }

    @Test("Claims are rejected instead of being silently discarded")
    func claimsAreRejected() async throws {
        try await withTemporaryDirectory { directory in
            let registry = try DatabaseTokenRegistry(
                fileURL: directory.appendingPathComponent("tokens.json")
            )
            let principal = Principal(
                identifier: "claims-principal",
                claims: try FieldObject([
                    (key: "department", value: .string("engineering")),
                ])
            )

            await #expect(
                throws: DatabaseServerAuthenticationError.claimsNotSupported
            ) {
                _ = try await registry.register(principal: principal)
            }
            #expect(await registry.isEmpty)

            await #expect(
                throws: DatabaseServerAuthenticationError.invalidPrincipal
            ) {
                _ = try await registry.register(
                    principal: Principal(identifier: "")
                )
            }
            #expect(await registry.isEmpty)
        }
    }

    @Test("A registry with broader permissions is rejected")
    func broaderPermissionsAreRejected() async throws {
        try await withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let registryURL = directory.appendingPathComponent("tokens.json")
            try Data(
                "{\"formatVersion\":1,\"tokens\":[]}".utf8
            ).write(to: registryURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o640],
                ofItemAtPath: registryURL.path
            )

            #expect(
                throws: DatabaseServerAuthenticationError
                    .invalidRegistryPermissions
            ) {
                _ = try DatabaseTokenRegistry(fileURL: registryURL)
            }
        }
    }

    @Test("A symbolic-link registry is rejected")
    func symbolicLinkRegistryIsRejected() async throws {
        try await withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let targetURL = directory.appendingPathComponent("target.json")
            try Data(
                "{\"formatVersion\":1,\"tokens\":[]}".utf8
            ).write(to: targetURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: targetURL.path
            )
            let registryURL = directory.appendingPathComponent("tokens.json")
            try FileManager.default.createSymbolicLink(
                at: registryURL,
                withDestinationURL: targetURL
            )

            #expect(
                throws: DatabaseServerAuthenticationError
                    .invalidRegistryPermissions
            ) {
                _ = try DatabaseTokenRegistry(fileURL: registryURL)
            }
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "database-server-token-registry-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func withTemporaryDirectory<Result>(
        _ body: (URL) async throws -> Result
    ) async throws -> Result {
        let directory = temporaryDirectory()
        do {
            let result = try await body(directory)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            return result
        } catch {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            throw error
        }
    }
}
