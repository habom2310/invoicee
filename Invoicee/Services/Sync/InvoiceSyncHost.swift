import Foundation

/// What `GoogleDriveConnector` needs from the rest of the app.
///
/// The connector used to reach back into the archive through five separately-installed
/// closures (`updateInvoicesProvider`, `updateSyncStatusRefresh`,
/// `configureArchiveHandlers`, `updateSyncedRegistration`, `updateRemoteFetcher`).
/// Nothing stopped a caller from wiring three of the five, and the defaults were silent
/// no-ops, so a missed call produced a connector that looked healthy and synced nothing.
///
/// One protocol with one assignment makes the dependency total: either the host is set
/// or it is `nil`.
@MainActor
protocol InvoiceSyncHost: AnyObject {
    /// The invoices the connector should consider for upload.
    var invoicesToSync: [CapturedInvoice] { get }

    /// Recompute which invoices show as synced in the UI.
    func refreshSyncStatus()

    /// Drop every locally stored invoice, e.g. after unlinking the account.
    func removeAllInvoices()

    /// Pull remote invoices into the local archive. Errors are the host's to report.
    func fetchRemoteInvoices() async
}
