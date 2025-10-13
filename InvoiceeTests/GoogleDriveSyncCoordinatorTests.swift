import XCTest
@testable import Invoicee

final class GoogleDriveSyncCoordinatorTests: XCTestCase {
    private var tracker: InvoiceSyncTracker!
    private var transferService: MockTransferService!
    private var firestoreUploader: MockFirestoreUploader!
    private var coordinator: GoogleDriveSyncCoordinator!
    private var userDefaultsSuite: UserDefaults!

    override func setUpWithError() throws {
        userDefaultsSuite = UserDefaults(suiteName: "InvoiceeSyncCoordinatorTests")
        userDefaultsSuite.removePersistentDomain(forName: "InvoiceeSyncCoordinatorTests")
        tracker = InvoiceSyncTracker(userDefaults: userDefaultsSuite)
        transferService = MockTransferService()
        firestoreUploader = MockFirestoreUploader()
        coordinator = GoogleDriveSyncCoordinator(transferService: transferService,
                                                 tracker: tracker,
                                                 firestoreUploader: firestoreUploader)
    }

    override func tearDownWithError() throws {
        userDefaultsSuite?.removePersistentDomain(forName: "InvoiceeSyncCoordinatorTests")
        userDefaultsSuite = nil
        tracker = nil
        transferService = nil
        firestoreUploader = nil
        coordinator = nil
    }

    func testSyncUploadsUnsyncedInvoices() async throws {
        let invoice = CapturedInvoice.stub()

        let syncedCount = try await coordinator.syncInvoices([invoice], quality: .large)

        XCTAssertEqual(syncedCount, 1)
        XCTAssertEqual(firestoreUploader.uploaded.count, 1)
        XCTAssertTrue(transferService.ensureFolderCalled)
        XCTAssertTrue(await tracker.isUpToDate(invoice))
    }

    func testSubsequentSyncSkipsAlreadyUpToDateInvoices() async throws {
        let invoice = CapturedInvoice.stub()
        _ = try await coordinator.syncInvoices([invoice], quality: .large)

        firestoreUploader.uploaded.removeAll()
        transferService.uploadedMetadata.removeAll()

        let secondRun = try await coordinator.syncInvoices([invoice], quality: .large)
        XCTAssertEqual(secondRun, 0)
        XCTAssertTrue(firestoreUploader.uploaded.isEmpty)
        XCTAssertTrue(transferService.uploadedMetadata.isEmpty)
    }
}

private final class MockTransferService: CloudStorageTransferService {
    var ensureFolderCalled = false
    var uploadedMetadata: [DriveUploadMetadata] = []
    var currentUserID: String? = "user-123"

    func currentAuthorizationState() -> GoogleDriveAuthorizationState { .linked }
    func authorize() async throws {}
    func disconnect() { currentUserID = nil }
    func ensureFolder(named name: String) async throws { ensureFolderCalled = true }
    func upload(fileURL: URL, metadata: DriveUploadMetadata) async throws {
        uploadedMetadata.append(metadata)
    }
    func uploadExport(fileURL: URL, fileName: String) async throws {}
    func downloadInvoiceImage(fileName: String, invoiceDate: Date) async throws -> Data { Data() }
    func deleteInvoiceImage(fileName: String, invoiceDate: Date) async throws {}
}

private final class MockFirestoreUploader: InvoiceFirestoreUploading {
    var uploaded: [(CapturedInvoice, String?)] = []

    func upload(invoice: CapturedInvoice, imageFileName: String?, userID: String) async throws {
        uploaded.append((invoice, imageFileName))
    }

    func delete(invoiceID: UUID) async throws {}

    func fetchInvoices(for userID: String) async throws -> [CapturedInvoice] { [] }
}

private extension CapturedInvoice {
    static func stub() -> CapturedInvoice {
        CapturedInvoice(
            supplier: "ACME",
            total: 120,
            ourAmount: 100,
            gst: 20,
            date: Date(),
            method: .manual,
            category: "Office",
            items: [],
            imageData: Data([0xFF])
        )
    }
}
