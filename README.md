# Invoicee

SwiftUI invoicing app: capture invoices by camera, photo, PDF, or by hand; sync attachments
to Google Drive and metadata to Firestore; report on expenses, revenue, and profit.

Requires iOS 18. Swift 5 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

## Project Structure

- `Invoicee/App` – app entry point, tab bar, and the dependency container (`AppEnvironment`).
- `Invoicee/Domain` – domain models, stores, persistence, and the GST rate
  (`CapturedInvoice`, `InvoiceArchive`, `LocalInvoiceStore`, `GSTRate`).
- `Invoicee/Services` – Google Drive + Firestore syncing, OCR, and revenue caching.
- `Invoicee/UI` – one folder per tab, each holding its view and view model, plus shared
  `Components`.
- `Invoicee/Utilities` – shared extensions, formatters, imaging, and logging.
- `Invoicee/Docs` – `ARCHITECTURE.md` (real module map and concurrency rules) and
  `TESTING.md`.

See `Invoicee/Docs/ARCHITECTURE.md` for the dependency graph and the list of deliberately
`nonisolated` types.

## Dependencies

- Google Drive API via a hand-rolled OAuth flow in `GoogleDriveTransferService`.
- Firebase Firestore (`InvoiceFirestoreUploader`, `RevenueFirestoreStore`), gated by
  `#if canImport(FirebaseFirestore)`.
- SwiftUI + Combine for state management. No third-party packages beyond Firebase.

## How it runs

1. `InvoiceeApp` builds the graph with `AppEnvironment.makeDefault()` and injects the
   shared stores via `View.invoiceeEnvironment(_:)`.
2. Invoices persist to `Application Support/Invoicee/invoices.json` through
   `LocalInvoiceStore`, whose writes are serialised by an actor and sequence-tagged so a
   slow encode cannot clobber a newer snapshot.
3. `GoogleDriveConnector` verifies the stored session ~5s after launch, pulls remote
   invoices in, then schedules uploads. Auto-sync debounces 1s and backs off to a 60s
   ceiling over at most 5 attempts.
4. `InvoiceSyncTracker` (an actor) records what has been uploaded and under which file
   name; it is the only source of truth for "is this invoice synced".
5. Each reporting tab's view model subscribes to `InvoiceArchive` and publishes finished
   figures — views never aggregate inside `body`.

## Setup

1. **Google Drive** – register an iOS OAuth client in the Google Cloud Console and update
   `GoogleDriveTransferService.Constants.clientID` / `redirectURI`. Register the redirect
   scheme (`ha.Invoicee`) under URL Types in the target's Info settings. The connector
   creates and manages the `Invoicee/<yyyy>/<MM>/` folder tree itself.
2. **Firebase** – add `GoogleService-Info.plist` to the app target and enable Firestore.
   Without it the app still builds and runs; the sync paths throw
   `FirestoreUnavailableError`.

### Known gaps

- The OAuth flow does not use PKCE or a `state` parameter. For a public client on a custom
  URL scheme, both are worth adding.
- GST is computed as if amounts were GST-exclusive. See the note at the end of
  `Docs/ARCHITECTURE.md`.

## Testing

There is no test target yet, and nothing is verified automatically. `Docs/TESTING.md` lists
how to add one and which logic is most worth covering first.

## Contributing

- Follow `Docs/ARCHITECTURE.md`; update it in the same change when the structure moves.
- Use `AppEnvironment` rather than introducing singletons.
- Mark pure helpers `nonisolated`, and keep expensive work (OCR, rasterising, resizing,
  file writes) off the main actor.
- Put a feature's view and view model together under `UI/<Feature>/`.
- Comments should explain *why*, especially where a non-obvious ordering or guard exists.
