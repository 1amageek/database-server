import Foundation
@testable import DatabaseServerHost
import Testing

@Suite("Database server storage configuration")
struct DatabaseServerStorageConfigurationTests {
    @Test("Launch configuration selects each native storage backend exactly")
    func selectsNativeBackends() throws {
        let policy = DatabaseServerLaunchConfiguration.EntityPolicy(
            entity: "Asset", roles: ["get": ["reader"], "create": ["editor"]]
        )
        try DatabaseServerLaunchConfiguration.validateEntityPolicies([policy])
        for policies in [
            [policy, policy],
            [.init(entity: "", roles: [:])],
            [.init(entity: "Asset", roles: ["admin": ["editor"]])],
            [.init(entity: "Asset", roles: ["get": [""]])],
            [.init(entity: "Asset", roles: ["get": ["reader", "reader"]])]
        ] {
            #expect(throws: DatabaseServerLaunchConfigurationError.invalidEntityPolicy) {
                try DatabaseServerLaunchConfiguration.validateEntityPolicies(policies)
            }
        }
        for document in [
            #"{"entityPolicies":[{"entity":"Asset","roles":{"read":["reader"]}}]}"#,
            #"{"entityPolicies":[{"entity":"Asset","roles":{},"allowAll":true}]}"#,
            #"{"entityPolicies":{}}"#
        ] {
            #expect(throws: (any Error).self) {
                try DatabaseServerLaunchConfigurationJSONValidator.validate(Data(document.utf8))
            }
        }
        let sqlite = DatabaseServerLaunchConfiguration.Storage(
            sqlite: .init(mode: .memory)
        )
        #expect(try sqlite.runtimeStorage() == .sqliteMemory)

        let postgreSQL = DatabaseServerLaunchConfiguration.Storage(
            postgreSQL: .init(
                host: "127.0.0.1",
                username: "database",
                database: "database_test",
                tls: .require,
                schemaManagement: .assumeExists
            )
        )
        #expect(
            try postgreSQL.runtimeStorage()
                == .postgreSQL(
                    .init(
                        connection: .tcp(host: "127.0.0.1", port: 5_432),
                        username: "database",
                        database: "database_test",
                        tls: .require,
                        schemaManagement: .assumeExists
                    )
                )
        )
        let encodedPostgreSQL = try #require(
            String(
                data: JSONEncoder().encode(postgreSQL),
                encoding: .utf8
            )
        )
        #expect(encodedPostgreSQL.contains(#""kind":"postgresql""#))
        #expect(encodedPostgreSQL.contains(#""postgresql":{"#))
        #expect(encodedPostgreSQL.contains(#""assume-exists""#))
        #expect(!encodedPostgreSQL.contains("postgreSQL"))

        let foundationDB = DatabaseServerLaunchConfiguration.Storage(
            foundationDB: .init(clusterFilePath: "/tmp/fdb.cluster")
        )
        #expect(
            try foundationDB.runtimeStorage()
                == .foundationDB(clusterFilePath: "/tmp/fdb.cluster")
        )

        #expect(
            throws: DatabaseServerLaunchConfigurationError
                .postgreSQLTLSRequiresTCP
        ) {
            _ = try DatabaseServerLaunchConfiguration.Storage(
                postgreSQL: .init(
                    unixSocketPath: "/tmp/.s.PGSQL.5432",
                    username: "database",
                    database: "database_test",
                    tls: .require
                )
            ).runtimeStorage()
        }
    }

    @Test("PostgreSQL password files require an owner-only regular file")
    func passwordFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "database-server-password-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove password fixture: \(error)")
            }
        }
        let passwordURL = directory.appendingPathComponent("password")
        try Data("secret\n".utf8).write(to: passwordURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: passwordURL.path
        )
        #expect(
            try DatabaseServerSecretFile.readPassword(path: passwordURL.path)
                == "secret"
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: passwordURL.path
        )
        #expect(throws: NativeDatabaseStorageError.invalidPasswordFile) {
            _ = try DatabaseServerSecretFile.readPassword(
                path: passwordURL.path
            )
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: passwordURL.path
        )
        let symbolicLinkURL = directory.appendingPathComponent("password-link")
        try FileManager.default.createSymbolicLink(
            at: symbolicLinkURL,
            withDestinationURL: passwordURL
        )
        #expect(throws: NativeDatabaseStorageError.invalidPasswordFile) {
            _ = try DatabaseServerSecretFile.readPassword(
                path: symbolicLinkURL.path
            )
        }
    }
}
