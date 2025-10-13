# Invoicee

Modernised SwiftUI invoicing app with modular services and feature-focused views.

## Project Structure

- `Invoicee/App` – app entry point and dependency container (`AppEnvironment`).
- `Invoicee/Domain` – domain models, stores, and persistence helpers (e.g. `CapturedInvoice`, `InvoiceArchive`, `LocalInvoiceStore`).
- `Invoicee/Services` – Google Drive + Firebase syncing and supporting actors (`GoogleDriveConnector`, `GoogleDriveSyncCoordinator`, `InvoiceSyncTracker`).
- `Invoicee/UI` – feature-specific SwiftUI views (Invoice, Expense, Profile) and reusable components.
- `Invoicee/Utilities` – shared extensions and formatting utilities (`NumberFormatter.invoiceCurrency`, `ReportingDateFormatter`).
- `Invoicee/Docs` – architecture notes, testing guide, and contributor documentation.
- `InvoiceeTests` – unit tests for persistence, sync retry, and analytics aggregation.

## Dependencies

- Google Drive API (custom OAUTH flow via `GoogleDriveTransferService`).
- Firebase Firestore (`InvoiceFirestoreUploader`), gated by `#if canImport(FirebaseFirestore)`.
- SwiftUI & Combine for state management.

## Development Workflow

1. Launch `InvoiceeApp` – `AppEnvironment.makeDefault()` wires all services without relying on singletons.
2. Invoices persist to `Application Support/Invoicee/invoices.json` via `LocalInvoiceStore`.
3. Google Drive auto-sync is scheduled through `GoogleDriveConnector`, which delegates uploads to `GoogleDriveSyncCoordinator` and records status in `InvoiceSyncTracker`.
4. Firebase updates are abstracted behind the `InvoiceFirestoreUploading` protocol.
5. Expense analytics pulls data from `InvoiceArchive` and derives category/supplier totals inside `ExpenseAnalyticsViewModel`.

## Testing

1. Add a new **Unit Testing Bundle** target in Xcode and drop in the `InvoiceeTests` folder.
2. Run `⌘U` or `xcodebuild test -scheme Invoicee -destination "platform=iOS Simulator,name=iPhone 15"`.
3. Refer to `Docs/TESTING.md` for current coverage and outstanding gaps.

## Sync Setup

1. Register the app in Google Cloud Console and update `GoogleDriveTransferService.Constants` with client ID + redirect URI.
2. Create the `Invoicee` folder in Drive; the connector will manage year/month subfolders automatically.
3. Configure Firebase by adding `GoogleService-Info.plist` and enabling Firestore (see `InvoiceFirestoreUploader`).

## Contributing

- Follow the architecture described in `Docs/ARCHITECTURE.md`.
- Reuse the dependency container instead of introducing new singletons.
- Prefer adding utilities under `Invoicee/Utilities` with doc comments.
- Keep feature views inside their respective `UI/<Feature>` folders.
