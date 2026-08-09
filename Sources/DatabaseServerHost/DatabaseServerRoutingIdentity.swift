public struct DatabaseServerRoutingIdentity: Sendable, Hashable {
    public let databaseID: String
    public let tenantID: String?
    public let workspaceID: String?

    public init(
        databaseID: String,
        tenantID: String? = nil,
        workspaceID: String? = nil
    ) throws(DatabaseServerRoutingError) {
        guard !databaseID.isEmpty else {
            throw .invalidConfiguration
        }
        guard tenantID?.isEmpty != true,
              workspaceID?.isEmpty != true else {
            throw .invalidConfiguration
        }
        self.databaseID = databaseID
        self.tenantID = tenantID
        self.workspaceID = workspaceID
    }

    public func validate(
        databaseID: String?,
        tenantID: String?,
        workspaceID: String?
    ) throws(DatabaseServerRoutingError) {
        guard databaseID == self.databaseID,
              tenantID == self.tenantID,
              workspaceID == self.workspaceID else {
            throw .mismatch
        }
    }
}

public enum DatabaseServerRoutingError: Error, Sendable, Equatable {
    case invalidConfiguration
    case mismatch
}
