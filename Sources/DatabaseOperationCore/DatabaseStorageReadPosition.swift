import DatabaseTypes

/// A backend read position whose ordering is meaningful only to the storage
/// engine that produced it. Domain qualification is added only by the
/// `MultiBase` runtime at its public result boundary.
package enum DatabaseStorageReadPosition: Sendable, Hashable {
    case version(UInt64)
    case opaque(ByteString)
}
