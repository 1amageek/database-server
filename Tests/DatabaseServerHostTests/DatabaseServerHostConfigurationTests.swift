import Foundation
@testable import DatabaseServerHost
import Testing

@Suite("Database server host configuration")
struct DatabaseServerHostConfigurationTests {
    @Test("Loopback permits an authenticated plaintext listener")
    func loopbackListener() throws {
        let routing = try DatabaseServerRoutingIdentity(databaseID: "main")
        let configuration = try DatabaseServerHostConfiguration(
            routingIdentity: routing
        )

        #expect(configuration.host == "127.0.0.1")
        #expect(configuration.port == 7_878)
        #expect(
            configuration.wireLimits.maximumFrameBytes
                == configuration.maximumFrameBytes
        )
    }

    @Test("Non-loopback rejects a listener without TLS before bind")
    func nonLoopbackRequiresTLS() throws {
        let routing = try DatabaseServerRoutingIdentity(databaseID: "main")
        #expect(
            throws: DatabaseServerHostConfigurationError
                .nonLoopbackRequiresTLS
        ) {
            _ = try DatabaseServerHostConfiguration(
                host: "0.0.0.0",
                routingIdentity: routing
            )
        }
    }

    @Test("WebSocket request concurrency has a strict host bound")
    func webSocketConcurrencyIsBounded() throws {
        let routing = try DatabaseServerRoutingIdentity(databaseID: "main")
        #expect(
            throws: DatabaseServerHostConfigurationError
                .invalidMaximumConcurrentWebSocketRequests
        ) {
            _ = try DatabaseServerHostConfiguration(
                routingIdentity: routing,
                maximumConcurrentWebSocketRequests: 0
            )
        }
        #expect(
            throws: DatabaseServerHostConfigurationError
                .invalidMaximumConcurrentWebSocketRequests
        ) {
            _ = try DatabaseServerHostConfiguration(
                routingIdentity: routing,
                maximumConcurrentWebSocketRequests: 65
            )
        }
    }

    @Test("Routing identity compares every dimension exactly")
    func exactRoutingIdentity() throws {
        let routing = try DatabaseServerRoutingIdentity(
            databaseID: "world",
            tenantID: "company-a",
            workspaceID: "private"
        )
        try routing.validate(
            databaseID: "world",
            tenantID: "company-a",
            workspaceID: "private"
        )
        #expect(throws: DatabaseServerRoutingError.mismatch) {
            try routing.validate(
                databaseID: "world",
                tenantID: "company-a",
                workspaceID: nil
            )
        }
    }

    #if !DATABASE_SERVER_HOST_MULTIPLE_BASES
    @Test("Standard database roots are explicit and backend-specific")
    func standardDatabaseRootsAreBackendSpecific() throws {
        let sqlite = DatabaseServerLaunchConfiguration.Storage(
            sqlite: .init(mode: .memory)
        )
        let foundationDB = DatabaseServerLaunchConfiguration.Storage(
            foundationDB: .init(clusterFilePath: "/tmp/fdb.cluster")
        )
        let directory = DatabaseServerLaunchConfiguration.DatabaseRoot
            .directory(path: ["applications", "main"])

        #expect(
            try DatabaseServerLaunchConfiguration.DatabaseRoot.engine
                .runtimeRoot(for: sqlite) == .engine
        )
        #expect(
            try directory.runtimeRoot(for: foundationDB)
                == .namespace(path: ["applications", "main"])
        )
        #expect(
            throws: DatabaseServerLaunchConfigurationError
                .databaseRootMismatch
        ) {
            _ = try directory.runtimeRoot(for: sqlite)
        }
        #expect(
            throws: DatabaseServerLaunchConfigurationError
                .databaseRootMismatch
        ) {
            _ = try DatabaseServerLaunchConfiguration.DatabaseRoot.engine
                .runtimeRoot(for: foundationDB)
        }
        #expect(
            throws: DatabaseServerLaunchConfigurationError.invalidDatabaseRoot
        ) {
            _ = try DatabaseServerLaunchConfiguration.DatabaseRoot
                .directory(path: [])
                .runtimeRoot(for: foundationDB)
        }
    }
    #endif

    @Test("Launch configuration is private, durable, and never follows a symbolic link")
    func secureLaunchConfigurationFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "database-server-configuration-\(UUID().uuidString)",
                isDirectory: true
            )
        let configurationRoot = root
            .appendingPathComponent("config", isDirectory: true)
        let directory = configurationRoot
            .appendingPathComponent("server", isDirectory: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch where (error as NSError).code
                    == NSFileNoSuchFileError {
            } catch {
                Issue.record("Failed to remove configuration fixture: \(error)")
            }
        }
        let configurationURL = directory.appendingPathComponent("server.json")
        let storage = DatabaseServerLaunchConfiguration.Storage(
            sqlite: .init(
                mode: .file,
                path: directory.appendingPathComponent("database.sqlite").path
            )
        )
        let configuration = launchConfiguration(
            storage: storage,
            tokenRegistryPath: directory
                .appendingPathComponent("tokens.json").path
        )
        try configuration.create(at: configurationURL)

        let loaded = try DatabaseServerLaunchConfiguration.load(
            from: configurationURL
        )
        #expect(loaded.routing.databaseID == "main")
        #if DATABASE_SERVER_HOST_MULTIPLE_BASES
        #expect(loaded.formatVersion == 2)
        #expect(loaded.domains.first?.storage.kind == .sqlite)
        #else
        #expect(loaded.formatVersion == 3)
        #expect(loaded.storage.kind == .sqlite)
        #expect(loaded.databaseRoot == .engine)
        #endif
        let attributes = try FileManager.default.attributesOfItem(
            atPath: configurationURL.path
        )
        #expect(
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
        )
        for privateDirectory in [root, configurationRoot, directory] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: privateDirectory.path
            )
            #expect(
                (attributes[.posixPermissions] as? NSNumber)?.intValue
                    == 0o700
            )
        }

        let linkURL = directory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: configurationURL
        )
        #expect(
            throws: DatabaseServerLaunchConfigurationError.invalidDocument
        ) {
            _ = try DatabaseServerLaunchConfiguration.load(from: linkURL)
        }
    }

    @Test("Launch configuration rejects malformed storage topologies")
    func launchConfigurationRejectsMalformedTopologies() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "database-server-unknown-key-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch where (error as NSError).code
                    == NSFileNoSuchFileError {
            } catch {
                Issue.record("Failed to remove configuration fixture: \(error)")
            }
        }
        let configurationURL = directory.appendingPathComponent("server.json")
        let document = Data(
            (#"{"formatVersion":2,"controlDomain":"primary","domains":[{"id":"primary","namespace":["database","main"],"storage":{"kind":"sqlite","sqlite":{"mode":"memory","unexpected":true}}}]"#
                + placementDocumentFragment
                + #", "host":"127.0.0.1","port":7878,"routing":{"databaseID":"main"},"tokenRegistryPath":"/tmp/tokens.json"}"#).utf8
        )
        try DatabaseServerConfigurationFile.create(document, at: configurationURL)

        #expect(
            throws: DatabaseServerLaunchConfigurationError.invalidDocument
        ) {
            _ = try DatabaseServerLaunchConfiguration.load(
                from: configurationURL
            )
        }

        let duplicateDomainURL = directory.appendingPathComponent(
            "duplicate-domain.json"
        )
        let duplicateDomainDocument = Data(
            (#"{"formatVersion":2,"controlDomain":"primary","domains":[{"id":"primary","namespace":["database","main"],"storage":{"kind":"sqlite","sqlite":{"mode":"memory"}}},{"id":"primary","namespace":["database","other"],"storage":{"kind":"sqlite","sqlite":{"mode":"memory"}}}]"#
                + placementDocumentFragment
                + #", "host":"127.0.0.1","port":7878,"routing":{"databaseID":"main"},"tokenRegistryPath":"/tmp/tokens.json"}"#).utf8
        )
        try DatabaseServerConfigurationFile.create(
            duplicateDomainDocument,
            at: duplicateDomainURL
        )
        #if DATABASE_SERVER_HOST_MULTIPLE_BASES
        let duplicateDomainError =
            DatabaseServerLaunchConfigurationError.invalidTopology
        #else
        let duplicateDomainError =
            DatabaseServerLaunchConfigurationError.invalidDocument
        #endif
        #expect(throws: duplicateDomainError) {
            _ = try DatabaseServerLaunchConfiguration.load(
                from: duplicateDomainURL
            )
        }

        #if DATABASE_SERVER_HOST_MULTIPLE_BASES
        let missingDomainURL = directory.appendingPathComponent(
            "missing-domain.json"
        )
        let missingDomainDocument = Data(
            #"{"formatVersion":2,"controlDomain":"primary","domains":[{"id":"primary","namespace":["database","main"],"storage":{"kind":"sqlite","sqlite":{"mode":"memory"}}}],"placements":[{"id":"default","domain":"missing","path":["bases"]}],"defaultPlacement":"default","host":"127.0.0.1","port":7878,"routing":{"databaseID":"main"},"tokenRegistryPath":"/tmp/tokens.json"}"#.utf8
        )
        try DatabaseServerConfigurationFile.create(
            missingDomainDocument,
            at: missingDomainURL
        )
        #expect(
            throws: DatabaseServerLaunchConfigurationError.invalidTopology
        ) {
            _ = try DatabaseServerLaunchConfiguration.load(
                from: missingDomainURL
            )
        }
        #endif

        let sqlitePath = directory.appendingPathComponent("shared.sqlite").path
        let duplicateBackendURL = directory.appendingPathComponent(
            "duplicate-backend.json"
        )
        let duplicateBackendDocument = Data(
            (#"{"formatVersion":2,"controlDomain":"primary","domains":[{"id":"primary","namespace":["database","main"],"storage":{"kind":"sqlite","sqlite":{"mode":"file","path":"\#(sqlitePath)"}}},{"id":"secondary","namespace":["database","secondary"],"storage":{"kind":"sqlite","sqlite":{"mode":"file","path":"\#(sqlitePath)"}}}]"#
                + placementDocumentFragment
                + #", "host":"127.0.0.1","port":7878,"routing":{"databaseID":"main"},"tokenRegistryPath":"/tmp/tokens.json"}"#).utf8
        )
        try DatabaseServerConfigurationFile.create(
            duplicateBackendDocument,
            at: duplicateBackendURL
        )
        #if DATABASE_SERVER_HOST_MULTIPLE_BASES
        let duplicateBackendError = DatabaseServerLaunchConfigurationError
            .duplicatePhysicalBackend
        #else
        let duplicateBackendError = DatabaseServerLaunchConfigurationError
            .invalidDocument
        #endif
        #expect(throws: duplicateBackendError) {
            _ = try DatabaseServerLaunchConfiguration.load(
                from: duplicateBackendURL
            )
        }
    }
}

private var placementDocumentFragment: String {
    #if DATABASE_SERVER_HOST_MULTIPLE_BASES
    #", "placements":[{"id":"default","domain":"primary","path":["bases"]}],"defaultPlacement":"default""#
    #else
    ""
    #endif
}

private func launchConfiguration(
    storage: DatabaseServerLaunchConfiguration.Storage,
    tokenRegistryPath: String
) -> DatabaseServerLaunchConfiguration {
    #if DATABASE_SERVER_HOST_MULTIPLE_BASES
    DatabaseServerLaunchConfiguration(
        controlDomain: "primary",
        domains: [
            .init(
                id: "primary",
                namespace: ["database", "main"],
                storage: storage
            ),
        ],
        placements: [
            .init(
                id: "default",
                domain: "primary",
                path: ["bases"]
            ),
        ],
        defaultPlacement: "default",
        routing: .init(databaseID: "main"),
        tokenRegistryPath: tokenRegistryPath
    )
    #else
    DatabaseServerLaunchConfiguration(
        storage: storage,
        databaseRoot: .engine,
        routing: .init(databaseID: "main"),
        tokenRegistryPath: tokenRegistryPath
    )
    #endif
}
