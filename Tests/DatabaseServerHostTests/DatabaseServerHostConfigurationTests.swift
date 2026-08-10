import Foundation
@testable import DatabaseServerHost
import Testing

@Suite("Database server host configuration")
struct DatabaseServerHostConfigurationTests {
    @Test("Loopback permits an authenticated plaintext listener")
    func loopbackListener() throws {
        let routing = try DatabaseServerRoutingIdentity(databaseID: "main")
        let configuration = try DatabaseServerHostConfiguration(
            routingIdentity: routing,
            hasAuthenticator: true
        )

        #expect(configuration.host == "127.0.0.1")
        #expect(configuration.port == 7_878)
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
                routingIdentity: routing,
                hasAuthenticator: true
            )
        }
    }

    @Test("Every network listener requires authentication")
    func listenerRequiresAuthentication() throws {
        let routing = try DatabaseServerRoutingIdentity(databaseID: "main")
        #expect(
            throws: DatabaseServerHostConfigurationError.missingAuthenticator
        ) {
            _ = try DatabaseServerHostConfiguration(
                routingIdentity: routing,
                hasAuthenticator: false
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

    @Test("Launch configuration is private, durable, and never follows a symbolic link")
    func secureLaunchConfigurationFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "database-server-configuration-\(UUID().uuidString)",
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
        let storage = DatabaseServerLaunchConfiguration.Storage(
            sqlite: .init(
                mode: .file,
                path: directory.appendingPathComponent("database.sqlite").path
            )
        )
        let configuration = DatabaseServerLaunchConfiguration(
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
            tokenRegistryPath: directory
                .appendingPathComponent("tokens.json").path
        )
        try configuration.create(at: configurationURL)

        let loaded = try DatabaseServerLaunchConfiguration.load(
            from: configurationURL
        )
        #expect(loaded.routing.databaseID == "main")
        #expect(loaded.formatVersion == 2)
        #expect(loaded.domains.first?.storage.kind == .sqlite)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: configurationURL.path
        )
        #expect(
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
        )

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
            #"{"formatVersion":2,"controlDomain":"primary","domains":[{"id":"primary","namespace":["database","main"],"storage":{"kind":"sqlite","sqlite":{"mode":"memory","unexpected":true}}}],"placements":[{"id":"default","domain":"primary","path":["bases"]}],"defaultPlacement":"default","host":"127.0.0.1","port":7878,"routing":{"databaseID":"main"},"tokenRegistryPath":"/tmp/tokens.json"}"#.utf8
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
            #"{"formatVersion":2,"controlDomain":"primary","domains":[{"id":"primary","namespace":["database","main"],"storage":{"kind":"sqlite","sqlite":{"mode":"memory"}}},{"id":"primary","namespace":["database","other"],"storage":{"kind":"sqlite","sqlite":{"mode":"memory"}}}],"placements":[{"id":"default","domain":"primary","path":["bases"]}],"defaultPlacement":"default","host":"127.0.0.1","port":7878,"routing":{"databaseID":"main"},"tokenRegistryPath":"/tmp/tokens.json"}"#.utf8
        )
        try DatabaseServerConfigurationFile.create(
            duplicateDomainDocument,
            at: duplicateDomainURL
        )
        #expect(
            throws: DatabaseServerLaunchConfigurationError.invalidTopology
        ) {
            _ = try DatabaseServerLaunchConfiguration.load(
                from: duplicateDomainURL
            )
        }

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

        let sqlitePath = directory.appendingPathComponent("shared.sqlite").path
        let duplicateBackendURL = directory.appendingPathComponent(
            "duplicate-backend.json"
        )
        let duplicateBackendDocument = Data(
            #"{"formatVersion":2,"controlDomain":"primary","domains":[{"id":"primary","namespace":["database","main"],"storage":{"kind":"sqlite","sqlite":{"mode":"file","path":"\#(sqlitePath)"}}},{"id":"secondary","namespace":["database","secondary"],"storage":{"kind":"sqlite","sqlite":{"mode":"file","path":"\#(sqlitePath)"}}}],"placements":[{"id":"default","domain":"primary","path":["bases"]}],"defaultPlacement":"default","host":"127.0.0.1","port":7878,"routing":{"databaseID":"main"},"tokenRegistryPath":"/tmp/tokens.json"}"#.utf8
        )
        try DatabaseServerConfigurationFile.create(
            duplicateBackendDocument,
            at: duplicateBackendURL
        )
        #expect(
            throws: DatabaseServerLaunchConfigurationError
                .duplicatePhysicalBackend
        ) {
            _ = try DatabaseServerLaunchConfiguration.load(
                from: duplicateBackendURL
            )
        }
    }
}
