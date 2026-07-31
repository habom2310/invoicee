import Foundation
import Combine

/// Centralises dependency wiring for the Invoicee app.
///
/// Also owns the reporting view models. They used to be constructed by `ContentView`,
/// which meant their lifetime was a SwiftUI implementation detail; holding them here
/// keeps one instance each and lets the tabs stay value types.
@MainActor
final class AppEnvironment: ObservableObject {
    let reportingPeriodStore: ReportingPeriodStore
    let invoiceArchive: InvoiceArchive
    let driveConnector: GoogleDriveConnector
    let firestoreUploader: InvoiceFirestoreUploading
    let remoteSynchronizer: InvoiceRemoteSynchronizer
    let syncTracker: InvoiceSyncTracker
    let categoryStore: InvoiceCategoryStore
    let revenueStore: RevenueStoring
    let revenueSummaryProvider: RevenueSummaryProviding
    let expenseMetricStore: ExpenseMetricStore

    private var cancellables: Set<AnyCancellable> = []

    init(reportingPeriodStore: ReportingPeriodStore,
         invoiceArchive: InvoiceArchive,
         driveConnector: GoogleDriveConnector,
         firestoreUploader: InvoiceFirestoreUploading,
         remoteSynchronizer: InvoiceRemoteSynchronizer,
         syncTracker: InvoiceSyncTracker,
         categoryStore: InvoiceCategoryStore,
         revenueStore: RevenueStoring,
         revenueSummaryProvider: RevenueSummaryProviding,
         expenseMetricStore: ExpenseMetricStore) {
        self.reportingPeriodStore = reportingPeriodStore
        self.invoiceArchive = invoiceArchive
        self.driveConnector = driveConnector
        self.firestoreUploader = firestoreUploader
        self.remoteSynchronizer = remoteSynchronizer
        self.syncTracker = syncTracker
        self.categoryStore = categoryStore
        self.revenueStore = revenueStore
        self.revenueSummaryProvider = revenueSummaryProvider
        self.expenseMetricStore = expenseMetricStore

        categoryStore.updateCategories(from: invoiceArchive.invoices)
        // Delivered on the next run loop pass: `$invoices` fires during `willSet`, and
        // republishing the category list from there lands in the middle of a view update.
        invoiceArchive.$invoices
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak categoryStore] invoices in
                categoryStore?.updateCategories(from: invoices)
            }
            .store(in: &cancellables)
    }

    // MARK: - View models

    func makeExpenseViewModel() -> ExpenseAnalyticsViewModel {
        ExpenseAnalyticsViewModel(archive: invoiceArchive,
                                  periodStore: reportingPeriodStore,
                                  metricStore: expenseMetricStore,
                                  revenueSummaryProvider: revenueSummaryProvider)
    }

    func makeRevenueViewModel() -> RevenueViewModel {
        RevenueViewModel(store: revenueStore,
                         driveConnector: driveConnector,
                         summaryProvider: revenueSummaryProvider)
    }

    func makeProfitViewModel() -> ProfitAnalyticsViewModel {
        ProfitAnalyticsViewModel(invoiceArchive: invoiceArchive,
                                 revenueStore: revenueStore,
                                 driveConnector: driveConnector,
                                 metricStore: expenseMetricStore)
    }

    // MARK: - Composition root

    static func makeDefault() -> AppEnvironment {
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
        let remoteSynchronizer = InvoiceRemoteSynchronizer(connector: connector,
                                                           archive: invoiceArchive,
                                                           firestoreUploader: firestoreUploader)
        // The connector needs the archive, and the archive's remote half needs the
        // connector to know whether Drive is linked, so the link is closed here.
        connector.host = remoteSynchronizer

        let revenueStore = RevenueFirestoreStore()
        return AppEnvironment(reportingPeriodStore: ReportingPeriodStore(),
                              invoiceArchive: invoiceArchive,
                              driveConnector: connector,
                              firestoreUploader: firestoreUploader,
                              remoteSynchronizer: remoteSynchronizer,
                              syncTracker: syncTracker,
                              categoryStore: InvoiceCategoryStore(),
                              revenueStore: revenueStore,
                              revenueSummaryProvider: RevenueSummaryProvider(store: revenueStore,
                                                                            driveConnector: connector),
                              expenseMetricStore: ExpenseMetricStore())
    }
}
