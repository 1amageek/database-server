import DatabaseKit
import DatabaseQueryOperations
import DatabaseWire
import Testing

@testable import DatabaseServerRuntime

@Suite("Database statement admission")
struct DatabaseStatementAdmissionTests {
    @Test("SQL admission preserves parameter references and declarations")
    func sqlParametersRetainIdentity() throws {
        let parameters = [
            QueryParameter(position: 1, value: .primitive(.null), type: .sql(.integer))
        ]
        let admitted = try DatabaseStatementAdmission(
            structuralLimits: .default
        ).admit(.text(language: .sql, statement: "SELECT $1::integer AS value, $1::text AS label"), parameters: parameters)
        #expect(admitted.parameters == parameters)
        guard case .select(let query) = admitted.statement,
              let item = query.projection.first,
              case .expression(.cast(.parameter(.position(1)), _), _) = item else {
            Issue.record("SQL admission erased the parameter occurrence")
            return
        }
    }

    @Test("Statement mutation preparation uses configured structural limits")
    func mutationPreparationUsesConfiguredStructuralLimits() throws {
        let admission = DatabaseStatementAdmission(
            structuralLimits: QueryStructuralLimits(
                maximumCollectionElements: 1
            )
        )
        let statement = QueryStatement.insert(
            InsertQuery(
                target: TableRef("AdmissionEntity"),
                columns: ["id", "title"],
                source: .defaultValues
            )
        )

        do {
            _ = try admission.admit(.statement(statement), parameters: [])
            Issue.record("Expected the collection limit to reject the mutation")
        } catch QueryParameterBindingError.invalidStructure(let error) {
            #expect(
                error == .resourceLimitExceeded(
                    resource: .collectionElements,
                    actual: 2,
                    maximum: 1
                )
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Mutation parameters are rejected before recursive binding")
    func mutationParametersAreValidatedBeforeBinding() throws {
        var value = FieldValue.object(FieldObject())
        for _ in 0..<7 {
            value = .array([value])
        }
        let admission = DatabaseStatementAdmission(
            structuralLimits: QueryStructuralLimits(
                maximumNestingDepth: 6
            )
        )
        let statement = QueryStatement.insert(
            InsertQuery(
                target: TableRef("AdmissionEntity"),
                columns: ["title"],
                source: .values([[.parameter(.position(1))]])
            )
        )

        do {
            _ = try admission.admit(
                .statement(statement),
                parameters: [
                    QueryParameter(
                        position: 1,
                        name: "value",
                        value: .primitive(value)
                    ),
                ]
            )
            Issue.record(
                "Expected parameter preflight to reject recursive binding"
            )
        } catch QueryParameterBindingError.invalidStructure(let error) {
            #expect(
                error == .resourceLimitExceeded(
                    resource: .nestingDepth,
                    actual: 7,
                    maximum: 6
                )
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
