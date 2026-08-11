import Crypto
import DatabaseKit
import DatabaseWireRuntime
import Darwin
import Foundation

public actor DatabaseTokenRegistry: DatabaseServerAuthenticator {
    private static let maximumRegistryBytes = 16 * 1_024 * 1_024
    private static let maximumPrincipalIdentifierBytes = 1_024
    private static let maximumRoleCount = 256
    private static let maximumRoleBytes = 256

    private struct RegistryDocument: Codable {
        let formatVersion: Int
        var tokens: [StoredToken]
    }

    private struct StoredToken: Codable {
        let identifier: String
        let digest: String
        let principalIdentifier: String
        let roles: [String]
        let createdAt: Date
        var revokedAt: Date?
    }

    public struct Registration: Sendable, Hashable {
        public let token: DatabaseServerToken
        public let principal: Principal

        public init(token: DatabaseServerToken, principal: Principal) {
            self.token = token
            self.principal = principal
        }
    }

    private let fileURL: URL
    private var document: RegistryDocument
    private var tokensByIdentifier: [String: StoredToken]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let document = try Self.load(from: fileURL)
        self.document = document
        self.tokensByIdentifier = Dictionary(
            uniqueKeysWithValues: document.tokens.map {
                ($0.identifier, $0)
            }
        )
    }

    public var isEmpty: Bool {
        document.tokens.isEmpty
    }

    public func register(
        principal: Principal,
        now: Date = Date()
    ) throws -> Registration {
        guard principal.claims.isEmpty else {
            throw DatabaseServerAuthenticationError.claimsNotSupported
        }
        guard Self.isValidPrincipal(
            identifier: principal.identifier,
            roles: principal.roles
        ) else {
            throw DatabaseServerAuthenticationError.invalidPrincipal
        }
        let token = DatabaseServerToken.generate()
        let stored = StoredToken(
            identifier: token.identifier,
            digest: Data(token.digest).base64EncodedString(),
            principalIdentifier: principal.identifier,
            roles: principal.roles.sorted(),
            createdAt: now,
            revokedAt: nil
        )
        document.tokens.append(stored)
        tokensByIdentifier[stored.identifier] = stored
        do {
            try persist()
        } catch let failure as RegistryPersistenceFailure {
            if !failure.wasCommitted {
                document.tokens.removeLast()
                tokensByIdentifier.removeValue(forKey: stored.identifier)
            }
            throw DatabaseServerAuthenticationError.registryWriteFailed
        }
        return Registration(token: token, principal: principal)
    }

    public func revoke(
        tokenIdentifier: String,
        now: Date = Date()
    ) throws {
        guard let index = document.tokens.firstIndex(where: {
            $0.identifier == tokenIdentifier
        }) else {
            throw DatabaseServerAuthenticationError.invalidCredential
        }
        let prior = document.tokens[index].revokedAt
        document.tokens[index].revokedAt = now
        tokensByIdentifier[tokenIdentifier] = document.tokens[index]
        do {
            try persist()
        } catch let failure as RegistryPersistenceFailure {
            if !failure.wasCommitted {
                document.tokens[index].revokedAt = prior
                tokensByIdentifier[tokenIdentifier] = document.tokens[index]
            }
            throw DatabaseServerAuthenticationError.registryWriteFailed
        }
    }

    public func remove(tokenIdentifier: String) throws {
        guard let index = document.tokens.firstIndex(where: {
            $0.identifier == tokenIdentifier
        }) else {
            throw DatabaseServerAuthenticationError.invalidCredential
        }
        let removed = document.tokens.remove(at: index)
        tokensByIdentifier.removeValue(forKey: tokenIdentifier)
        do {
            try persist()
        } catch let failure as RegistryPersistenceFailure {
            if !failure.wasCommitted {
                document.tokens.insert(removed, at: index)
                tokensByIdentifier[tokenIdentifier] = removed
            }
            throw DatabaseServerAuthenticationError.registryWriteFailed
        }
    }

    public func authenticate(
        _ credential: DatabaseServerCredential
    ) async throws -> DatabaseServerAuthentication {
        let rawValue: String
        switch credential {
        case .bearer(let value):
            rawValue = value
        }
        let token = try DatabaseServerToken(parsing: rawValue)
        guard let stored = tokensByIdentifier[token.identifier] else {
            throw DatabaseServerAuthenticationError.invalidCredential
        }
        guard stored.revokedAt == nil else {
            throw DatabaseServerAuthenticationError.revokedCredential
        }
        guard let expected = Data(base64Encoded: stored.digest),
              constantTimeEqual(token.digest, expected) else {
            throw DatabaseServerAuthenticationError.invalidCredential
        }
        return DatabaseServerAuthentication(
            authorization: .authenticated(Principal(
                identifier: stored.principalIdentifier,
                roles: Set(stored.roles)
            )),
            jobAuthorizationReference: try DatabaseJobAuthorizationReference(
                stored.identifier
            )
        )
    }

    public func revalidate(
        _ reference: DatabaseJobAuthorizationReference
    ) async throws -> AuthorizationContext {
        guard let stored = tokensByIdentifier[reference.value] else {
            throw DatabaseServerAuthenticationError.invalidCredential
        }
        guard stored.revokedAt == nil else {
            throw DatabaseServerAuthenticationError.revokedCredential
        }
        return .authenticated(
            Principal(
                identifier: stored.principalIdentifier,
                roles: Set(stored.roles)
            )
        )
    }

    private func persist() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try DatabasePrivateDirectory.ensure(directoryURL)
            try Self.validateDirectoryPermissions(directoryURL)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            guard data.count <= Self.maximumRegistryBytes else {
                throw RegistryPersistenceFailure.notCommitted
            }
            try Self.writeAtomically(data, to: fileURL)
        } catch let failure as RegistryPersistenceFailure {
            throw failure
        } catch {
            throw RegistryPersistenceFailure.notCommitted
        }
    }

    private static func load(from fileURL: URL) throws -> RegistryDocument {
        let descriptor = Darwin.open(
            fileURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        if descriptor < 0, errno == ENOENT {
            return RegistryDocument(formatVersion: 1, tokens: [])
        }
        guard descriptor >= 0 else {
            throw DatabaseServerAuthenticationError
                .invalidRegistryPermissions
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        defer { handle.closeFile() }
        try validateDirectoryPermissions(fileURL.deletingLastPathComponent())
        let byteCount = try validateFile(
            descriptor: descriptor,
            maximumBytes: maximumRegistryBytes
        )
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try handle.read(upToCount: byteCount + 1) ?? Data()
            guard data.count == byteCount else {
                throw DatabaseServerAuthenticationError.invalidRegistry
            }
            let document = try decoder.decode(
                RegistryDocument.self,
                from: data
            )
            guard document.formatVersion == 1,
                  Set(document.tokens.map(\.identifier)).count
                    == document.tokens.count,
                  document.tokens.allSatisfy({
                      !$0.identifier.isEmpty
                          && Self.isValidPrincipal(
                              identifier: $0.principalIdentifier,
                              roles: Set($0.roles)
                          )
                          && Set($0.roles).count == $0.roles.count
                          && Data(base64Encoded: $0.digest)?.count
                            == SHA256.Digest.byteCount
                  }) else {
                throw DatabaseServerAuthenticationError.invalidRegistry
            }
            return document
        } catch let error as DatabaseServerAuthenticationError {
            throw error
        } catch {
            throw DatabaseServerAuthenticationError.invalidRegistry
        }
    }

    private static func validateDirectoryPermissions(_ url: URL) throws {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o777 == 0o700,
              metadata.st_uid == geteuid() else {
            throw DatabaseServerAuthenticationError
                .invalidRegistryPermissions
        }
    }

    private static func validateFile(
        descriptor: Int32,
        maximumBytes: Int
    ) throws -> Int {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_uid == geteuid(),
              metadata.st_size >= 0,
              metadata.st_size <= maximumBytes else {
            throw DatabaseServerAuthenticationError
                .invalidRegistryPermissions
        }
        return Int(metadata.st_size)
    }

    private static func writeAtomically(
        _ data: Data,
        to destinationURL: URL
    ) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw RegistryPersistenceFailure.notCommitted
        }
        var shouldRemoveTemporaryFile = true
        var didCloseDescriptor = false
        defer {
            if !didCloseDescriptor {
                _ = Darwin.close(descriptor)
            }
            if shouldRemoveTemporaryFile {
                _ = Darwin.unlink(temporaryURL.path)
            }
        }

        var operationFailed = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    operationFailed = true
                    return
                }
            }
        }
        if Darwin.fsync(descriptor) != 0 {
            operationFailed = true
        }
        if Darwin.close(descriptor) != 0 {
            operationFailed = true
        }
        didCloseDescriptor = true
        guard !operationFailed else {
            throw RegistryPersistenceFailure.notCommitted
        }
        guard Darwin.rename(temporaryURL.path, destinationURL.path) == 0 else {
            throw RegistryPersistenceFailure.notCommitted
        }
        shouldRemoveTemporaryFile = false
        do {
            try synchronizeDirectory(directoryURL)
        } catch {
            throw RegistryPersistenceFailure.committed
        }
    }

    private static func synchronizeDirectory(_ directoryURL: URL) throws {
        let descriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw RegistryPersistenceFailure.committed
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw RegistryPersistenceFailure.committed
        }
    }

    private func constantTimeEqual<C: Collection>(
        _ left: C,
        _ right: Data
    ) -> Bool where C.Element == UInt8 {
        guard left.count == SHA256.Digest.byteCount,
              right.count == SHA256.Digest.byteCount else {
            return false
        }
        var difference: UInt8 = 0
        for (leftByte, rightByte) in zip(left, right) {
            difference |= leftByte ^ rightByte
        }
        return difference == 0
    }

    private static func isValidPrincipal(
        identifier: String,
        roles: Set<String>
    ) -> Bool {
        let identifierBytes = identifier.utf8.count
        guard identifierBytes > 0,
              identifierBytes <= maximumPrincipalIdentifierBytes,
              roles.count <= maximumRoleCount else {
            return false
        }
        return roles.allSatisfy {
            let byteCount = $0.utf8.count
            return byteCount > 0 && byteCount <= maximumRoleBytes
        }
    }
}

private enum RegistryPersistenceFailure: Error {
    case notCommitted
    case committed

    var wasCommitted: Bool {
        switch self {
        case .notCommitted: false
        case .committed: true
        }
    }
}
