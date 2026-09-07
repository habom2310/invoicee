# Invoicee Architecture

This describes the structure as it actually is. Keep it in step with the tree — an
architecture doc that lists files which don't exist is worse than none.

## Core Principles

- **Explicit lifecycle** – shared state (reporting period, invoice archive, sync tracker,
  expense metric) lives in `AppEnvironment`, which owns the instances and defines their
  lifespan. No singletons.
- **Service protocols** – view models depend on protocols (`InvoicePersistence`,
  `CloudStorageTransferService`, `RevenueStoring`, `InvoiceFirestoreUploading`,
  `InvoiceSyncHost`) so implementations can be swapped or faked.
- **Feature-first organization** – each tab's view and view model sit together under
  `UI/<Feature>/`.
- **Sync isolation** – Drive and Firebase concerns live under `Services/`; UI never talks
  to either directly, except through the connector it is handed.
- **Shared utilities, not copies** – formatting, money bindings, CSV, logging, and the
  GST rate each have exactly one definition under `Utilities/` or `Domain/Tax/`.

## Module Overview

```
Invoicee/
  App/
    InvoiceeApp.swift               # @main; Firebase configure; environment injection
    ContentView.swift               # Tab bar
    AppEnvironment.swift            # Composition root + view model factories

  Domain/
    Invoices/
      Models/
        CapturedInvoice.swift       # Invoice, ManualInvoiceData, ManualInvoiceItem
        ExpenseMetric.swift         # Total vs Our Amount
        ReportingPeriod.swift       # Week/Month/Year + Calendar range helper
      Stores/
        InvoiceArchive.swift        # Single source of truth for invoices
        InvoiceCategoryStore.swift  # Categories + supplier→category memory
        ReportingPeriodStore.swift  # Shared month/year selection
        ReportingPeriodOptions.swift# Which periods are selectable, and clamping
        ExpenseMetricStore.swift    # Shared metric selection
      Persistence/
        LocalInvoiceStore.swift     # JSON in Application Support, serialised by an actor
        InvoiceSyncTracker.swift    # Actor: what has been uploaded, and as what name
    Revenue/
      RevenueModels.swift           # RevenueDayEntry, RevenueStreamValue
    Tax/
      GSTRate.swift                 # The only definition of the 10% rate
      GSTValidator.swift            # Caps an implausible GST figure

  Services/
    OCR/
      InvoiceOCR.swift              # nonisolated Vision pass + field parsing
    Revenue/
      RevenueSummaryProvider.swift  # Cached monthly revenue totals
    Firebase/
      InvoiceFirestoreUploader.swift
      RevenueFirestoreStore.swift
    Sync/
      InvoiceSyncHost.swift         # What the connector needs from the app
      InvoiceRemoteSynchronizer.swift # Remote→local merge; the connector's host
      GoogleDrive/
        GoogleDriveConnector.swift  # Link lifecycle, auto-sync scheduling
        GoogleDriveSyncCoordinator.swift # Per-invoice upload orchestration
        GoogleDriveTransferService.swift # OAuth flow + Drive REST
        GoogleDriveCredentials.swift # Token/profile models + keychain store
        DriveWireModels.swift       # Drive request/response DTOs, DriveServiceError
        CloudStorageTransferService.swift # The protocol the above satisfies
        DriveUploadMetadata.swift   # Folder/file naming and parsing
        InvoiceDriveExporter.swift  # Attachment → temp file, resized
        InvoiceImageQuality.swift
        GoogleDriveAuthorizationState.swift

  UI/
    Components/
      CSVExportController.swift     # Shared "build CSV → save sheet → mirror to Drive"
      MonthYearPickerSheet.swift
      ReportingControls.swift       # YearMenuButton, WarningSection
    Invoice/
      InvoiceTabView.swift
      InvoiceCaptureSheet.swift     # Camera / photo / PDF capture
      InvoiceFormViews.swift        # ManualInvoiceFormView, InvoiceItemFields
      Components/
        CapturedInvoiceRow.swift
        InvoiceFormControls.swift
        DocumentScannerView.swift   # VisionKit scanner, kept out of Services/
        MediaPickers.swift          # Photo library + PDF document pickers
      Detail/
        InvoiceDetailView.swift
    Expense/
      ExpenseTabView.swift
      ExpenseAnalyticsViewModel.swift
    Revenue/
      RevenueTabView.swift
      RevenueViewModel.swift
    Profit/
      ProfitTabView.swift
      ProfitAnalyticsViewModel.swift
    Profile/
      ProfileTabView.swift          # + GoogleDriveSettingsView

  Utilities/
    CSV/CSVExporting.swift
    Extensions/                     # Binding+MoneyText, Calendar+ReportingPeriods,
                                    # Color, Date, Decimal, Error+UserFacing,
                                    # NSRegularExpression+Matching, String
    Formatting/                     # NumberFormatter+Currency, ReportingDateFormatter
    Imaging/PDFPageRenderer.swift
    Logging/AppLog.swift
```

## Dependency Injection

`AppEnvironment.makeDefault()` is the composition root. It builds the graph bottom-up and
closes the one cycle explicitly:

```
transferService → syncCoordinator → connector → invoiceArchive → remoteSynchronizer
                                        ↑                              │
                                        └──── connector.host = ────────┘
```

The connector needs the archive (to know what to upload); the archive's remote half needs
the connector (to know whether Drive is linked). `InvoiceSyncHost` is that one back-edge,
assigned once, held weakly. It replaced five separately-installed closures where a
forgotten call produced a connector that looked healthy and synced nothing.

Views receive the stores through `@EnvironmentObject`, injected by
`View.invoiceeEnvironment(_:)` so the list exists in one place.

## Concurrency

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so **everything is main-actor
isolated unless marked `nonisolated`**. That default is right for the stores and view
models and wrong for anything expensive, so the following are deliberately `nonisolated`:

- `InvoiceOCRProcessor` – the Vision text pass; it blocked the UI for seconds.
- `PDFPageRenderer` – page rasterisation.
- `InvoiceDriveExporter` – image resizing and temp-file writes.
- `CSVExporting`, `ReportingDateFormatter`, `NumberFormatter+Currency`,
  `Decimal`/`String`/`Error`/`Calendar`/`NSRegularExpression` extensions, `GSTRate`,
  `GSTValidator`, `DriveUploadMetadata` – pure helpers, callable from any isolation.

`InvoiceSyncTracker` and `LocalInvoiceStore`'s file writer are actors. The writer tags
each snapshot with a sequence number so a slow encode cannot overwrite a newer one.

## Reporting data flow

`InvoiceArchive` publishes `invoices`. Each analytics view model subscribes, recomputes its
aggregates once, and publishes the *finished* figures — including percentages. Views read
published values and never aggregate in `body`, because `body` runs several times per
update and each of those aggregations walks the whole archive.

`ReportingPeriodStore` and `ExpenseMetricStore` let the tabs share a selection. The
subscriptions are delivered on `RunLoop.main` so a picker change never publishes back into
the middle of a view update.

`ReportingPeriodOptions` is the only place a year list is derived. Expense, Revenue, and
Profit each used to build their own, and the three had drifted: one excluded future years,
one added the current year, one added neither. They now differ only in how they keep a
`Picker` from rendering blank when its selection holds no data — a `Picker` whose selection
is absent from its options shows nothing:

- Invoice and Expense **clamp the selection** onto the options (`clamped(month:year:)`).
- Revenue and Profit **widen the options** to include the selection
  (`availableYears(including:)`), because their selection is free to roam.

Each view model rebuilds its options when its data changes, not inside `availableYears` —
the year menu reads that property from `body` on every pass. Month lists are unchanged:
Invoice and Expense restrict them via `availableMonths(for:)`, while Revenue and Profit
still offer all twelve.

## Known issue: GST is treated as exclusive

`GSTRate` documents this, but it is worth stating plainly: revenue totals and invoice
totals are treated as **GST-exclusive** (GST = amount × 0.1). If the amounts users enter
are GST-*inclusive*, as they are on most Australian receipts, GST should be amount ÷ 11 and
the net should be amount × 10/11. `GSTRate.inclusiveGST(in:)` / `inclusiveNet(of:)` exist
for that reading; switching is a per-call-site change in `GSTValidator`,
`RevenueViewModel.summaryGST`, and `ProfitSummary.revenueNet`.
