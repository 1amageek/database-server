@_spi(DatabaseExecution) import DatabaseEngine
@_spi(DatabaseExecution) import DatabaseWire

/// A response page whose materialized elements are charged against the
/// request's output budget.
///
/// The canonical response pages count different elements, but both spend the
/// same budget: one element returned to the caller is one output row. A
/// conformance is the only place that decides which count a page contributes,
/// so no publication path restates it.
protocol ResponseOutputPage {
    /// The number of materialized elements the page returns to the caller.
    var outputRowCount: Int { get }
}

extension QueryRowPage: ResponseOutputPage {
    var outputRowCount: Int { rowCount }
}

extension RDFGraphPage: ResponseOutputPage {
    var outputRowCount: Int { quadCount }
}

extension DatabaseWorkMeter {
    /// Claims a response page against the request's output row budget.
    ///
    /// Every publication path claims its page through this method, and claims
    /// it while the write reservation that produced the page is still
    /// releasable, so a refused or cancelled claim aborts the reservation
    /// instead of leaving a committed manifest whose continuation was never
    /// returned to a caller.
    ///
    /// A page whose element count exceeds the budget counter's range is refused
    /// rather than truncated: a truncated claim would charge the principal less
    /// than the response actually returns.
    func recordOutput(_ page: some ResponseOutputPage) throws {
        guard let rows = UInt32(exactly: page.outputRowCount) else {
            throw DatabaseWorkLimitError.maximumRows(
                stage: .resultMaterialization,
                consumed: consumedRows,
                requested: UInt32.max,
                maximum: budget.maximumRows
            )
        }
        try recordOutputRows(rows)
    }
}
