import Foundation
internal import SwiftUI
import Combine

/// Centralises dependency wiring for the Invoicee app.
@MainActor
final class AppEnvironment: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    let reportingPeriodStore: ReportingPeriodStore
    let invoiceArchive: InvoiceArchive
    let driveConnector: GoogleDriveConnector
    let firestoreUploader: InvoiceFirestoreUploading
    let remoteSynchronizer: InvoiceRemoteSynchronizer
    let syncTracker: InvoiceSyncTracker
    let categoryStore: InvoiceCategoryStore
    let revenueStore: RevenueStoring
    private var cancellables: Set<AnyCancellable> = []

    init(reportingPeriodStore: ReportingPeriodStore,
         invoiceArchive: InvoiceArchive,
         driveConnector: GoogleDriveConnector,
         firestoreUploader: InvoiceFirestoreUploading,
         remoteSynchronizer: InvoiceRemoteSynchronizer,
         syncTracker: InvoiceSyncTracker,
         categoryStore: InvoiceCategoryStore,
         revenueStore: RevenueStoring) {
        self.reportingPeriodStore = reportingPeriodStore
        self.invoiceArchive = invoiceArchive
        self.driveConnector = driveConnector
        self.firestoreUploader = firestoreUploader
        self.remoteSynchronizer = remoteSynchronizer
        self.syncTracker = syncTracker
        self.categoryStore = categoryStore
        self.revenueStore = revenueStore

        categoryStore.updateCategories(from: invoiceArchive.invoices)
        invoiceArchive.$invoices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] invoices in
                self?.categoryStore.updateCategories(from: invoices)
            }
            .store(in: &cancellables)
    }

    func makeDriveLinkViewModel() -> GoogleDriveLinkViewModel {
        GoogleDriveLinkViewModel(connector: driveConnector, archive: invoiceArchive)
    }

    static func makeDefault() -> AppEnvironment {
        let reportingPeriodStore = ReportingPeriodStore()
        let syncTracker = InvoiceSyncTracker()
        let firestoreUploader = InvoiceFirestoreUploader()
        let transferService = GoogleDriveTransferService()
        let syncCoordinator = GoogleDriveSyncCoordinator(transferService: transferService,
                                                         tracker: syncTracker,
                                                         firestoreUploader: firestoreUploader)
        let connector = GoogleDriveConnector(transferService: transferService,
                                             syncCoordinator: syncCoordinator,
                                             tracker: syncTracker)
        let invoiceArchive = InvoiceArchive(persistence: LocalInvoiceStore(),
                                            syncScheduler: connector,
                                            syncStatusProvider: syncTracker)
        connector.updateInvoicesProvider { [weak invoiceArchive] in
            invoiceArchive?.invoices ?? []
        }
        connector.updateSyncStatusRefresh { [weak invoiceArchive] in
            invoiceArchive?.refreshSyncStatus()
        }
        connector.configureArchiveHandlers(clearAll: { [weak invoiceArchive] in
            invoiceArchive?.update(with: [])
        }, removeInvoices: { [weak invoiceArchive] ids in
            guard let archive = invoiceArchive else { return }
            let remaining = archive.invoices.filter { !ids.contains($0.id) }
            archive.update(with: remaining)
        })
        connector.updateSyncedRegistration { [weak invoiceArchive] ids in
            invoiceArchive?.markInvoicesSynced(ids)
        }
        let remoteSynchronizer = InvoiceRemoteSynchronizer(connector: connector,
                                                           archive: invoiceArchive,
                                                           firestoreUploader: firestoreUploader)
        connector.updateRemoteFetcher { [weak remoteSynchronizer] in
            guard let synchronizer = remoteSynchronizer else { return }
            _ = try? await synchronizer.synchronizeFromRemote()
        }
        let categoryStore = InvoiceCategoryStore()
        let revenueStore = RevenueFirestoreStore()
        let environment = AppEnvironment(reportingPeriodStore: reportingPeriodStore,
                                         invoiceArchive: invoiceArchive,
                                         driveConnector: connector,
                                         firestoreUploader: firestoreUploader,
                                         remoteSynchronizer: remoteSynchronizer,
                                         syncTracker: syncTracker,
                                         categoryStore: categoryStore,
                                         revenueStore: revenueStore)
        return environment
    }
}
