import DatabaseKit
import DatabaseQueryOperations
import DatabaseWire
import Testing

@testable import DatabaseServerRuntime

@Suite("Database statement admission")
struct DatabaseStatementAdmissionTests {
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
            _ = try admission.admit(.ir(statement), parameters: [])
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
                .ir(statement),
                parameters: [
                    QueryParameter(
                        position: 1,
                        name: "value",
                        value: value
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
