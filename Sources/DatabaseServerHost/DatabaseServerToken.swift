import Crypto
import DatabaseKit
import Foundation

public struct DatabaseServerToken: Sendable, Hashable {
    public let identifier: String
    public let rawValue: String

    private init(identifier: String, rawValue: String) {
        self.identifier = identifier
        self.rawValue = rawValue
    }

    public static func generate() -> DatabaseServerToken {
        var generator = SystemRandomNumberGenerator()
        let identifierBytes = (0..<16).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        }
        let secretBytes = (0..<32).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        }
        let identifier = Base64URL.encode(identifierBytes)
        let secret = Base64URL.encode(secretBytes)
        return DatabaseServerToken(
            identifier: identifier,
            rawValue: "dbt.\(identifier).\(secret)"
        )
    }

    init(parsing rawValue: String) throws(DatabaseServerAuthenticationError) {
        let components = rawValue.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 3,
              components[0] == "dbt",
              let identifierBytes = Base64URL.decode(String(components[1])),
              identifierBytes.count == 16,
              let secretBytes = Base64URL.decode(String(components[2])),
              secretBytes.count == 32 else {
            throw .malformedCredential
        }
        self.identifier = String(components[1])
        self.rawValue = rawValue
    }

    var digest: [UInt8] {
        Array(SHA256.hash(data: Data(rawValue.utf8)))
    }
}

private enum Base64URL {
    static func encode<C: Collection>(_ bytes: C) -> String
    where C.Element == UInt8 {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> [UInt8]? {
        guard !value.isEmpty,
              value.utf8.allSatisfy({
                  ($0 >= 65 && $0 <= 90)
                      || ($0 >= 97 && $0 <= 122)
                      || ($0 >= 48 && $0 <= 57)
                      || $0 == 45
                      || $0 == 95
              }) else {
            return nil
        }
        let remainder = value.utf8.count % 4
        let paddingCount = remainder == 0 ? 0 : 4 - remainder
        let base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: paddingCount)
        guard let data = Data(base64Encoded: base64) else {
            return nil
        }
        return Array(data)
    }
}
