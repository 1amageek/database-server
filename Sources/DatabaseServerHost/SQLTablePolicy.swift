/// Native role grants for one exact logical SQL schema and table.
public struct SQLTablePolicy: Codable, Sendable {
    public let schema: String
    public let table: String
    public let roles: [String: [String]]

    public init(schema: String, table: String, roles: [String: [String]]) {
        self.schema = schema
        self.table = table
        self.roles = roles
    }

    // Component bytes preserve SQL identifier identity without Unicode folding
    // or ambiguous concatenation of names containing dots.
    struct Target: Hashable, Sendable {
        let schema: [UInt8]
        let table: [UInt8]

        init(schema: String, table: String) {
            self.schema = Array(schema.utf8)
            self.table = Array(table.utf8)
        }
    }

    static func validate(_ policies: [Self]) throws {
        let operations: Set<String> = ["list", "get", "create", "update", "delete"]
        var targets: Set<Target> = []
        for policy in policies {
            guard !policy.schema.isEmpty, !policy.table.isEmpty,
                  !policy.schema.utf8.contains(0), !policy.table.utf8.contains(0),
                  targets.insert(Target(schema: policy.schema, table: policy.table)).inserted,
                  Set(policy.roles.keys).isSubset(of: operations) else {
                throw DatabaseServerLaunchConfigurationError.invalidSQLTablePolicy
            }
            for roles in policy.roles.values {
                guard !roles.isEmpty, roles.count <= 256,
                      Set(roles).count == roles.count,
                      roles.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
                    throw DatabaseServerLaunchConfigurationError.invalidSQLTablePolicy
                }
            }
        }
    }
}
