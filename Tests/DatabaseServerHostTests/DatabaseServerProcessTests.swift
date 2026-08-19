import DatabaseKit
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import Darwin
import Foundation
@testable import DatabaseServerHost
import Testing

@Suite("Database server process", .serialized)
struct DatabaseServerProcessTests {
    @Test("The stdio executable completes a DatabaseWire round trip and exits on EOF")
    func stdioRoundTripAndEOFShutdown() throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = try serverExecutableURL()
        process.arguments = ["stdio", "--memory"]
        #if MultiBase
        process.arguments?.append(
            contentsOf: ["--domain-namespace", "process-test"]
        )
        #endif
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput

        try process.run()
        do {
            let requestID: UInt64 = 91
            let request = try databaseServerHostCapabilitiesRequest(
                requestID: requestID
            )
            let codec = try DatabaseStdioFrameCodec(
                maximumFrameBytes: DatabaseWireLimits.default.maximumFrameBytes
            )
            let prefix = try codec.lengthPrefix(for: request)
            try input.fileHandleForWriting.write(contentsOf: data(prefix))
            try input.fileHandleForWriting.write(contentsOf: data(request))

            let responsePrefix = try readExactly(
                count: 4,
                from: output.fileHandleForReading
            )
            let responseLength = try codec.decodeLength(
                ByteString(Array(responsePrefix))
            )
            let responseData = try readExactly(
                count: responseLength,
                from: output.fileHandleForReading
            )
            let response = try DatabaseWireDecoder().decodeResponse(
                DatabaseOperationCatalog.capabilitiesDescribe,
                from: ByteString(Array(responseData)),
                matching: requestID
            )
            let payload = try response.get()

            #expect(payload.runtimeVersion == "26.0819.0")
            #expect(
                payload.features.contains {
                    $0.identifier == "schema.execute" && $0.version == 1
                }
            )

            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let diagnostics = try errorOutput.fileHandleForReading
                .readToEnd()
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(process.terminationStatus == 0, Comment(rawValue: diagnostics))
        } catch {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            throw error
        }
    }

    @Test("Bootstrap commits a credential only after a private-pipe acknowledgement")
    func bootstrapAcknowledgementControlsCredentialCommit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "database-server-bootstrap-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove bootstrap fixture: \(error)")
            }
        }
        let configURL = directory.appendingPathComponent("server.json")
        let databaseURL = directory.appendingPathComponent("database.sqlite")
        let registryURL = directory.appendingPathComponent("tokens.json")

        let rejected = try startBootstrap(
            configURL: configURL,
            databaseURL: databaseURL
        )
        let rejectedResponse = try readBootstrapResponse(
            from: rejected.output.fileHandleForReading
        )
        #expect(rejectedResponse["createdCredential"] as? Bool == true)
        #expect(rejectedResponse["token"] as? String != nil)
        try rejected.input.fileHandleForWriting.write(contentsOf: Data([0]))
        try rejected.input.fileHandleForWriting.close()
        rejected.process.waitUntilExit()
        #expect(rejected.process.terminationStatus != 0)
        #expect(try await DatabaseTokenRegistry(fileURL: registryURL).isEmpty)

        let accepted = try startBootstrap(
            configURL: configURL,
            databaseURL: databaseURL
        )
        let acceptedResponse = try readBootstrapResponse(
            from: accepted.output.fileHandleForReading
        )
        let rawToken = try #require(acceptedResponse["token"] as? String)
        try accepted.input.fileHandleForWriting.write(contentsOf: Data([1]))
        try accepted.input.fileHandleForWriting.close()
        accepted.process.waitUntilExit()
        #expect(accepted.process.terminationStatus == 0)
        let persistedRegistry = try String(
            contentsOf: registryURL,
            encoding: .utf8
        )
        #expect(!persistedRegistry.contains(rawToken))

        let existing = try startBootstrap(
            configURL: configURL,
            databaseURL: databaseURL
        )
        let existingResponse = try readBootstrapResponse(
            from: existing.output.fileHandleForReading
        )
        existing.input.fileHandleForWriting.closeFile()
        existing.process.waitUntilExit()
        #expect(existing.process.terminationStatus == 0)
        #expect(existingResponse["createdCredential"] as? Bool == false)
        #expect(existingResponse["token"] is NSNull)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: configURL.path
        )
        #expect(
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
        )
    }

    @Test("The serve executable reaches the runtime and stops accepting connections after SIGINT")
    func serveRoundTripAndNegativeReadiness() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "database-server-serve-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove serve fixture: \(error)")
            }
        }
        let configURL = directory.appendingPathComponent("server.json")
        let databaseURL = directory.appendingPathComponent("database.sqlite")
        let port = try reserveLoopbackPort()

        let bootstrap = try startBootstrap(
            configURL: configURL,
            databaseURL: databaseURL,
            port: port
        )
        let response = try readBootstrapResponse(
            from: bootstrap.output.fileHandleForReading
        )
        let token = try #require(response["token"] as? String)
        try bootstrap.input.fileHandleForWriting.write(contentsOf: Data([1]))
        try bootstrap.input.fileHandleForWriting.close()
        bootstrap.process.waitUntilExit()
        #expect(bootstrap.process.terminationStatus == 0)

        let process = Process()
        let diagnostics = Pipe()
        process.executableURL = try serverExecutableURL()
        process.arguments = ["serve", "--config", configURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = diagnostics
        try process.run()
        diagnostics.fileHandleForWriting.closeFile()

        let endpoint = try #require(
            URL(string: "http://127.0.0.1:\(port)/v1/database")
        )
        do {
            let requestID: UInt64 = 303
            let requestBytes = try databaseServerHostCapabilitiesRequest(
                requestID: requestID
            )
            let responseBytes = try await waitForCapabilities(
                endpoint: endpoint,
                token: token,
                requestBytes: requestBytes
            )
            let wireResponse = try DatabaseWireDecoder().decodeResponse(
                DatabaseOperationCatalog.capabilitiesDescribe,
                from: ByteString(Array(responseBytes)),
                matching: requestID
            )
            let capabilities = try wireResponse.get()
            #expect(capabilities.runtimeVersion == "26.0819.0")

            process.interrupt()
            let status = try await waitForTermination(
                process,
                timeout: .seconds(10)
            )
            let diagnosticText = try diagnostics.fileHandleForReading
                .readToEnd()
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(status == 0, Comment(rawValue: diagnosticText))
            try await requireNegativeReadiness(
                endpoint: endpoint,
                token: token,
                requestBytes: requestBytes
            )
        } catch {
            if process.isRunning {
                process.terminate()
                do {
                    _ = try await waitForTermination(
                        process,
                        timeout: .seconds(3)
                    )
                } catch {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = try await waitForTermination(
                        process,
                        timeout: .seconds(3)
                    )
                }
            }
            throw error
        }
    }

    private func serverExecutableURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let productsPath = environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"]
            ?? environment["BUILT_PRODUCTS_DIR"]
        guard let productsPath else {
            throw DatabaseServerProcessTestError.missingBuildProductsDirectory
        }
        let firstPath = productsPath.split(separator: ":", maxSplits: 1)
            .first
            .map(String.init) ?? productsPath
        let executableURL = URL(fileURLWithPath: firstPath)
            .appendingPathComponent("database-server")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw DatabaseServerProcessTestError.missingExecutable(
                executableURL.path
            )
        }
        return executableURL
    }

    private func startBootstrap(
        configURL: URL,
        databaseURL: URL,
        port: Int? = nil
    ) throws -> (process: Process, input: Pipe, output: Pipe) {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = try serverExecutableURL()
        process.arguments = [
            "bootstrap",
            "--config", configURL.path,
            "--path", databaseURL.path,
        ]
        #if MultiBase
        process.arguments?.append(
            contentsOf: ["--domain-namespace", "process-test"]
        )
        #endif
        if let port {
            process.arguments?.append(contentsOf: ["--port", String(port)])
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        return (process, input, output)
    }

    private func readBootstrapResponse(
        from handle: FileHandle
    ) throws -> [String: Any] {
        let prefix = try readExactly(count: 4, from: handle)
        let length = prefix.reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard length > 0, length <= 16 * 1_024 else {
            throw DatabaseServerProcessTestError.invalidBootstrapResponse
        }
        let payload = try readExactly(count: Int(length), from: handle)
        guard let object = try JSONSerialization.jsonObject(with: payload)
                as? [String: Any] else {
            throw DatabaseServerProcessTestError.invalidBootstrapResponse
        }
        return object
    }

    private func readExactly(
        count: Int,
        from handle: FileHandle
    ) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try handle.read(
                upToCount: count - result.count
            ), !chunk.isEmpty else {
                throw DatabaseServerProcessTestError.truncatedOutput(
                    expected: count,
                    actual: result.count
                )
            }
            result.append(chunk)
        }
        return result
    }

    private func data(_ bytes: ByteString) -> Data {
        bytes.withUnsafeBytes { Data($0) }
    }

    private func reserveLoopbackPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw DatabaseServerProcessTestError.cannotReservePort
        }
        defer { _ = Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindStatus == 0 else {
            throw DatabaseServerProcessTestError.cannotReservePort
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameStatus == 0 else {
            throw DatabaseServerProcessTestError.cannotReservePort
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func waitForCapabilities(
        endpoint: URL,
        token: String,
        requestBytes: ByteString
    ) async throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var lastError: (any Error)?
        while clock.now < deadline {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 0.5
                request.httpBody = data(requestBytes)
                request.setValue(
                    "application/octet-stream",
                    forHTTPHeaderField: "Content-Type"
                )
                request.setValue(
                    "Bearer \(token)",
                    forHTTPHeaderField: "Authorization"
                )
                request.setValue("main", forHTTPHeaderField: "x-database-id")
                let (body, response) = try await URLSession.shared.data(
                    for: request
                )
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    return body
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DatabaseServerProcessTestError.readinessTimedOut(
            String(describing: lastError)
        )
    }

    private func requireNegativeReadiness(
        endpoint: URL,
        token: String,
        requestBytes: ByteString
    ) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 0.5
        request.httpBody = data(requestBytes)
        request.setValue(
            "application/octet-stream",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("main", forHTTPHeaderField: "x-database-id")
        do {
            _ = try await URLSession.shared.data(for: request)
        } catch {
            return
        }
        throw DatabaseServerProcessTestError.serverRemainedReachable
    }

    private func waitForTermination(
        _ process: Process,
        timeout: Duration
    ) async throws -> Int32 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard !process.isRunning else {
            throw DatabaseServerProcessTestError.terminationTimedOut
        }
        return process.terminationReason == .exit
            ? process.terminationStatus
            : -process.terminationStatus
    }
}

private enum DatabaseServerProcessTestError: Error, Equatable {
    case missingBuildProductsDirectory
    case missingExecutable(String)
    case truncatedOutput(expected: Int, actual: Int)
    case invalidBootstrapResponse
    case cannotReservePort
    case readinessTimedOut(String)
    case terminationTimedOut
    case serverRemainedReachable
}
