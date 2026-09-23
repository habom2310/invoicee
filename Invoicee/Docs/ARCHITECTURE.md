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
        ReportingPeriod.swift       # Day/Week/Month/Year + Calendar range helpers
        ReportingPeriodSelection.swift  # A period + the range of days it covers
      Stores/
        InvoiceArchive.swift        # Single source of truth for invoices
        InvoiceCategoryStore.swift  # Categories + supplier→category memory
        ReportingPeriodStore.swift  # The period the three reporting tabs share
        InvoiceMonthStore.swift     # The month the invoice list is showing
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
      ReportingControls.swift       # WarningSection
      ReportingPeriodSelector.swift # Shared period control, timeframe + custom date sheets
      CalendarRangePicker.swift     # Month grid for picking a custom span in one pass
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

`ReportingPeriodStore` and `ExpenseMetricStore` let the tabs share a selection. Each view
model keeps its own copy and mirrors the store both ways, guarded by an
`isApplyingExternal…` flag so the echo stops there. The subscriptions are delivered on
`RunLoop.main` so a change never publishes back into the middle of a view update.

`ReportingPeriodOptions` is the only place a year list is derived. Expense and Profit each
used to build their own, and they had drifted: one excluded future years, one added the
current year, one added neither. They now differ only in how they keep a `Picker` from
rendering blank when its selection holds no data — a `Picker` whose selection is absent
from its options shows nothing:

- Invoice and Expense **clamp the selection** onto the options (`clamped(month:year:)`).
- Profit **widens the options** to include the selection (`availableYears(including:)`),
  because its selection is free to roam.

Each view model rebuilds its options when its data changes, not inside `availableYears` —
the year menu reads that property from `body` on every pass. Month lists are unchanged:
Invoice and Expense restrict them via `availableMonths(for:)`, while Profit still offers
all twelve.

## How the reporting tabs choose a period

All three navigate rather than pick, and all three navigate **together**.
`ReportingPeriodSelection` holds a `ReportingPeriod` and the **range** it covers, and
`ReportingPeriodSelector` — one control, shared — steps that range one span back or
forward, or opens the timeframe sheet to switch between Today, This week, This month,
This year and a custom date range. Each view model owns a single
`@Published var selection`, recomputes from it, and mirrors it through
`ReportingPeriodStore`: the three tabs answer questions about the same stretch of
trading, so choosing a period on any one of them moves the other two.

`range` is stored rather than derived, because a custom span is the user's own dates and
no anchor arithmetic would produce it. For every other period the range comes from the
anchor, and `anchor` is simply `range.start`.

Two invariants make the arithmetic safe:

- A preset's range always starts on the **first day of its period**, otherwise stepping
  back from a 31st would land on a 28th and stay there.
- Forward travel stops at the span in progress, since nothing can be recorded past today.

### What each period is measured against

`precedingRange(for:matching:)` answers this, and the rule differs by kind:

- A **period still in progress** compares like for like — on a Wednesday, "this week"
  measures against last week up to *its* Wednesday.
- A **finished period** compares against the whole of the period before it.
- A **day** compares against the same weekday a week earlier (`comparisonComponent`),
  because takings swing too hard between weekdays for yesterday to mean anything.
- A **custom span** compares against the same number of days immediately before it
  (`precedingSpan(matching:)`): one day against the day before, ten days against the ten
  before those. Nothing is "in progress" there — the user chose the dates — and a step
  back lands exactly on the span it was comparing with.

A custom span is picked on `CalendarRangePicker`, one month grid rather than a start and
an end field. A tap sets the start, the next completes the span, and a tap after that
starts over from the day tapped — so there is no mode to explain and no way to leave a
half-finished pair behind. Days after today are not selectable, since a span running into
the future would compare against days that cannot hold figures.

Only Revenue renders that comparison today; the type is screen-agnostic.

The invoice list is the one screen that still *picks*, and it sits outside that share. It
drives its own `InvoiceMonthStore` through `MonthYearPickerSheet`, clamping onto
`ReportingPeriodOptions` so its picker never renders a month it does not offer. That clamp
runs on appear and whenever the invoice count changes, so pointing it at the shared store
would move all three reports to whichever month happens to hold invoices — which is why
the two stores are separate.

## Known issue: GST is treated as exclusive

`GSTRate` documents this, but it is worth stating plainly: revenue totals and invoice
totals are treated as **GST-exclusive** (GST = amount × 0.1). If the amounts users enter
are GST-*inclusive*, as they are on most Australian receipts, GST should be amount ÷ 11 and
the net should be amount × 10/11. `GSTRate.inclusiveGST(in:)` / `inclusiveNet(of:)` exist
for that reading; switching is a per-call-site change in `GSTValidator`,
`RevenueViewModel.summaryGST`, and `ProfitSummary.revenueNet`.
