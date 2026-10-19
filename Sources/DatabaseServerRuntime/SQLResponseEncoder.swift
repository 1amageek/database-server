import DatabaseKit
import DatabaseQueryOperations
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseEngine
@_spi(DatabaseExecution) import DatabaseWire

/// Projects borrowed SQL outcomes directly into the Wire-owned scoped writer.
package struct SQLResponseEncoder: SQLBlockResponseEncoder {
    package let requestID: UInt64
    package let limits: DatabaseWireLimits

    package func measure(_ output: borrowing SQLBlockOutputView) throws -> UInt64 {
        do {
            let count = try DatabaseWireEncoder(limits: limits).measureSQLResponse(
                requestID: requestID, resultCount: output.statementCount
            ) { writer in
                try write(output, into: &writer)
            }
            guard let bytes = UInt64(exactly: count) else { throw DatabaseWireError.byteCountOverflow }
            return bytes
        } catch let error as DatabaseWireError {
            try throwResponseFailure(error)
        }
    }

    package func encode(
        _ output: borrowing SQLBlockOutputView,
        into destination: inout MutableSpan<UInt8>
    ) throws {
        // The span owns the complete initialized destination for this synchronous
        // borrow. Wire neither retains the pointer nor changes its byte capacity.
        do {
            try destination.withUnsafeMutableBytes { buffer in
                try DatabaseWireEncoder(limits: limits).encodeSQLResponse(
                    requestID: requestID, resultCount: output.statementCount, into: buffer
                ) { writer in
                    try write(output, into: &writer)
                }
            }
        } catch let error as DatabaseWireError {
            try throwResponseFailure(error)
        }
    }

    private func throwResponseFailure(_ error: DatabaseWireError) throws -> Never {
        let isLimit: Bool
        switch error {
        case .frameTooLarge, .stringTooLarge, .byteStringTooLarge,
             .collectionTooLarge, .nestingTooDeep, .objectBudgetExceeded:
            isLimit = true
        case .invalidQueryValue(.resourceLimit),
             .invalidQueryStructure(.resourceLimitExceeded):
            isLimit = true
        default: isLimit = false
        }
        guard isLimit else { throw error }
        throw SQLExecutionFailure(underlyingError: DatabaseResponsePreparationError(wireError: error),
            diagnostic: try SQLDiagnostic(sqlState: "54000", category: .resource,
                message: "SQL response exceeds the configured Wire resource limits"))
    }

    private func write(
        _ output: borrowing SQLBlockOutputView,
        into writer: inout SQLResponseWriter
    ) throws {
        for index in 0..<output.statementCount {
            try output.withStatement(at: index, command: { kind, affectedRows in
                try writer.writeCommand(kind, affectedRows: affectedRows)
            }, rows: { rows in
                let affectedRows: UInt64?
                if let count = rows.affectedRows {
                    guard let value = UInt64(exactly: count) else { throw DatabaseWireError.invalidSQLResponse }
                    affectedRows = value
                } else { affectedRows = nil }
                try writer.writeRows(columnCount: rows.columnCount, rowCount: rows.rowCount,
                    affectedRows: affectedRows) { rowWriter in
                    for column in 0..<rows.columnCount {
                        try rows.withColumn(at: column) { try rowWriter.writeColumn($0) }
                    }
                    for row in 0..<rows.rowCount {
                        try rows.withRow(at: row) { value in
                            try rowWriter.beginRow()
                            for cell in 0..<value.valueCount {
                                try value.withValue(at: cell) { try rowWriter.writeValue($0) }
                            }
                            try value.withAnnotations { annotations in
                                let fields = try DatabaseQueryRowEncoder.encodeFields(annotations)
                                try value.withVersion { token in
                                    let version: ByteString?
                                    if let token { version = try PersistableVersionTokenCodec.digest(from: token) }
                                    else { version = nil }
                                    try rowWriter.endRow(annotations: fields, version: version)
                                }
                            }
                        }
                    }
                }
            }, copy: { copied in
                try copied.withBytes { try writer.writeCopy(bytes: $0, affectedRows: copied.affectedRows) }
            })
        }
    }
}
