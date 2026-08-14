@_spi(DatabaseExecution) import DatabaseWire

public enum DatabaseServerFrameError:
    Error,
    Sendable,
    CustomStringConvertible {
    case invalidRequestFrame(DatabaseWireError)
    case responseEncodingFailed(DatabaseWireError)

    public var description: String {
        switch self {
        case .invalidRequestFrame(let error):
            "Database request frame is invalid: \(error)"
        case .responseEncodingFailed(let error):
            "Database response frame could not be encoded: \(error)"
        }
    }
}
