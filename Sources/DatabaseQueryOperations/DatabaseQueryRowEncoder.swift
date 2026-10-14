import DatabaseOperationCore
import DatabaseKit
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire

package enum DatabaseQueryRowEncoder {
    package static func encodeFields(
        _ values: [String: FieldValue]
    ) throws -> FieldObject {
        let sortedValues = values.sorted { $0.key < $1.key }
        return try FieldObject(
            sortedValues.map { field in
                (key: field.key, value: field.value)
            }
        )
    }

    package static func encode(
        _ row: DatabaseEngine.QueryRow,
        columns: [QueryColumn]
    ) throws -> DatabaseWire.QueryRow {
        try row.validate(columns: columns)
        let version: ByteString?
        if let token = row.version {
            version = try PersistableVersionTokenCodec.digest(from: token)
        } else {
            version = nil
        }
        return DatabaseWire.QueryRow(
            values: row.values,
            annotations: try encodeFields(row.annotations),
            version: version
        )
    }
}
