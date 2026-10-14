@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseQueryOperations
import DatabaseTypes
import DatabaseWire
import Testing

@Suite("Positional query row encoding")
struct DatabasePositionalRowEncodingTests {
    @Test("The page adapter rejects arity mismatches before publication")
    func rejectsArityMismatch() throws {
        let columns = [try QueryColumn(number: 1, name: "value", type: .sql(.text), isNullable: false)]
        let row = try DatabaseEngine.QueryRow(values: [.primitive(.string("value"))], columns: columns)
        #expect(throws: QueryRowCodecError.arityMismatch(expected: 0, actual: 1)) {
            try DatabaseQueryRowEncoder.encode(row, columns: [])
        }
    }

    @Test("The page adapter rejects a cell incompatible with the bound type")
    func rejectsIncompatibleType() throws {
        let sourceColumns = [try QueryColumn(number: 1, name: "duplicate", type: .sql(.bigint), isNullable: false)]
        let destinationColumns = [try QueryColumn(number: 1, name: "duplicate", type: .sql(.text), isNullable: false)]
        let row = try DatabaseEngine.QueryRow(values: [.primitive(.int64(1))], columns: sourceColumns)
        #expect(throws: QueryRowCodecError.incompatibleValue(column: 1)) {
            try DatabaseQueryRowEncoder.encode(row, columns: destinationColumns)
        }
    }
}
