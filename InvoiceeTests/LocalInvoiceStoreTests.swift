import XCTest
@testable import Invoicee

final class LocalInvoiceStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = temporaryDirectory {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectory = nil
    }

    func testRoundTripPersistence() throws {
        let invoices = [CapturedInvoice.stub(total: 120), CapturedInvoice.stub(total: 45)]
        let store = LocalInvoiceStore(fileManager: .default, baseURL: temporaryDirectory)

        store.saveInvoices(invoices)

        // Allow async write to complete.
        let expectation = expectation(description: "Wait for write")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        let persisted = store.loadInvoices()
        XCTAssertEqual(persisted.count, invoices.count)
        XCTAssertEqual(Set(persisted.map(\.total)), Set(invoices.map(\.total)))
    }

    func testMissingFileReturnsEmptyArray() {
        let store = LocalInvoiceStore(fileManager: .default, baseURL: temporaryDirectory.appendingPathComponent("missing"))
        let invoices = store.loadInvoices()
        XCTAssertTrue(invoices.isEmpty)
    }
}

private extension CapturedInvoice {
    static func stub(total: Decimal) -> CapturedInvoice {
        CapturedInvoice(
            supplier: "Supplier",
            total: total,
            ourAmount: total,
            gst: 0,
            date: Date(),
            method: .manual,
            category: nil,
            items: []
        )
    }
}
