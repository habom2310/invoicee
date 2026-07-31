# Testing Guide

## Current state: there are no tests

This file previously listed `LocalInvoiceStoreTests`, `GoogleDriveSyncCoordinatorTests`,
and `ExpenseAnalyticsViewModelTests` under "Available Tests". None of them exist, there is
no `InvoiceeTests` folder, and the Xcode project has no test target. Nothing is verified
automatically.

## Adding a test target

The project uses a filesystem-synchronized group (`objectVersion = 77`), so files added on
disk join the app target automatically. A test target still has to be created once:

1. Xcode ▸ File ▸ New ▸ Target ▸ Unit Testing Bundle, named `InvoiceeTests`, with
   `Invoicee` as the target to test.
2. `@testable import Invoicee` in each test file.
3. Run with `⌘U`, or:
   `xcodebuild test -scheme Invoicee -destination "platform=iOS Simulator,name=iPhone 16"`

## Where tests would pay off most

Ordered by how much logic is at risk and how easy it is to reach without a simulator or a
network. The first four are pure functions or use injectable protocols — no mocking of
Firebase or Drive required.

1. **`ReportingPeriodOptions.clamped(month:year:)`** – governs what every reporting picker
   can select. The fallback rules (out-of-range year → most recent; out-of-range month →
   latest of the current year, earliest of a past year) are entirely untested and drive
   what the user sees on launch.
2. **`DriveUploadMetadata.parseFileName(from:)`** – round-trip it against `fileName` for
   suppliers with punctuation, unicode, empty names, and legacy `_imageN` suffixes. A wrong
   parse silently re-uploads an attachment under a new name instead of overwriting.
3. **`GSTValidator` / `GSTRate`** – the cap, and whether amounts are exclusive or inclusive
   (see the note in `ARCHITECTURE.md`). This is money.
4. **`InvoiceRemoteSynchronizer.merging(remote:into:)`** – decides when a remote copy wins.
   Worth a test per branch: remote newer, local newer but remote adds a file name, both
   equal. The "local newer but remote adds a file name" case used to overwrite local edits
   with stale remote values.
5. **`ExpenseAnalyticsViewModel`** – inject a `Calendar` with a fixed
   `firstWeekday`/timezone and a stub `RevenueSummaryProviding`, then assert the published
   `categoryBreakdown` / `supplierBreakdown` shares. Also covers the clamp re-entry in
   `applyInvoices` → `clampSelection` → `periodDidChange`.
6. **`LocalInvoiceStore`** – pass a `baseURL` in a temp directory; assert a round trip, a
   missing file returning `[]`, and that an out-of-order write is discarded.
7. **`GoogleDriveSyncCoordinator`** – fake `CloudStorageTransferService` and
   `InvoiceFirestoreUploading`; assert that an unchanged invoice is skipped, that a
   supplier rename triggers a relocate, and that increments keep counting up.

## Not reachable by unit tests

- The OAuth flow (`ASWebAuthenticationSession`) and keychain storage.
- OCR accuracy — needs sample invoice images and is inherently fuzzy. The layout helpers
  (`nearestValue(to:among:rowTolerance:)`, `itemsExcludingTotalRow`) *are* testable with
  synthetic bounding boxes, and are where the logic actually lives.
- SwiftUI layout. Snapshot tests would need a host application target.
