/// Host-owned selection of the one ordinary database root.
public enum NativeDatabaseRootConfiguration: Sendable, Hashable {
    /// Use the complete key space of a dedicated storage engine.
    case engine

    /// Resolve or create one namespace in a shared storage engine.
    case namespace(path: [String])
}
