import XCTest
@testable import Invoicee

@MainActor
final class ExpenseAnalyticsViewModelTests: XCTestCase {
    private var archive: InvoiceArchive!
    private var persistence: MemoryInvoicePersistence!

    override func setUp() async throws {
        let invoices = [
            CapturedInvoice.stub(supplier: "ACME", category: "Office", total: 100, date: DateComponents(calendar: .current, year: 2024, month: 5, day: 2).date!),
            CapturedInvoice.stub(supplier: "ACME", category: "Office", total: 60, date: DateComponents(calendar: .current, year: 2024, month: 5, day: 14).date!),
            CapturedInvoice.stub(supplier: "Fresh Foods", category: "Supplies", total: 80, date: DateComponents(calendar: .current, year: 2024, month: 5, day: 20).date!)
        ]
        persistence = MemoryInvoicePersistence(invoices: invoices)
        archive = InvoiceArchive(persistence: persistence,
                                 syncScheduler: NoopSyncScheduler(),
                                 syncStatusProvider: NoopSyncStatusProvider())
    }

    override func tearDown() async throws {
        archive = nil
        persistence = nil
    }

    func testCategoryTotalsAggregatedForSelectedMonth() async throws {
        let viewModel = ExpenseAnalyticsViewModel(archive: archive)
        viewModel.selectedYear = 2024
        viewModel.selectedMonth = 5

        XCTAssertEqual(viewModel.categoryTotals.count, 2)
        XCTAssertEqual(viewModel.categoryTotals.first?.category, "Office")
        XCTAssertEqual(viewModel.categoryTotals.first?.total, 160)
    }

    func testSupplierTotalsAggregatedForSelectedMonth() async throws {
        let viewModel = ExpenseAnalyticsViewModel(archive: archive)
        viewModel.selectedYear = 2024
        viewModel.selectedMonth = 5

        XCTAssertEqual(viewModel.supplierTotals.count, 2)
        XCTAssertEqual(viewModel.supplierTotals.first?.supplier, "ACME")
        XCTAssertEqual(viewModel.supplierTotals.first?.total, 160)
    }
}

private final class MemoryInvoicePersistence: InvoicePersistence {
    var invoices: [CapturedInvoice]

    init(invoices: [CapturedInvoice]) {
        self.invoices = invoices
    }

    func loadInvoices() -> [CapturedInvoice] { invoices }
    func saveInvoices(_ invoices: [CapturedInvoice]) { self.invoices = invoices }
}

private struct NoopSyncScheduler: InvoiceAutoSyncScheduling {
    func enqueueAutoSync(with invoices: [CapturedInvoice]) {}
}

private struct NoopSyncStatusProvider: InvoiceSyncStatusProvider {
    func syncedInvoiceIDs(for invoices: [CapturedInvoice]) async -> Set<UUID> { [] }
}

private extension CapturedInvoice {
    static func stub(supplier: String, category: String?, total: Decimal, date: Date) -> CapturedInvoice {
        CapturedInvoice(
            supplier: supplier,
            total: total,
            ourAmount: total,
            gst: 0,
            date: date,
            method: .manual,
            category: category,
            items: []
        )
    }
}
