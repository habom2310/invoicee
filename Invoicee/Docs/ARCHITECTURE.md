# Invoicee Architecture Blueprint

This document captures the target structure that guides the ongoing refactor. It informs the dependency graph, ownership rules, and module boundaries introduced in this iteration.

## Core Principles

- **Explicit lifecycle** – shared state (reporting period, invoice archive, sync tracker) lives inside a container object that we inject where needed. The runtime environment owns those instances and defines their lifespan.
- **Service protocols** – UI and view models depend on lightweight protocols, making it easy to mock in tests and to transition implementations independently.
- **Feature-first organization** – SwiftUI views, models, and helpers sit inside feature folders (Invoice, Expense, Profile) to keep each feature cohesive.
- **Sync isolation** – Google Drive and Firebase concerns are separated from UI logic and rely on dedicated transfer/sync layers with documented behaviour.
- **Documented utilities** – shared helpers (formatters, CSV, date utilities) move into namespaced extensions with doc comments to avoid ad-hoc duplication.

## Module Overview

```
Invoicee/
  App/
    InvoiceeApp.swift
    AppEnvironment.swift            # Dependency container & environment keys

  Domain/
    Invoices/
      Models/
        CapturedInvoice.swift       # Codable domain models with docstrings
        ManualInvoiceItem.swift
      Stores/
        InvoiceArchive.swift        # ObservableObject + persistence helpers
        ReportingPeriodStore.swift  # Injected calendar, no singletons
      Persistence/
        LocalInvoiceStore.swift     # JSON read/write
        InvoiceSyncTracker.swift    # Actor tracking remote sync state

  Services/
    Sync/
      GoogleDrive/
        GoogleDriveConnector.swift  # Auth/link lifecycle, queue management
        GoogleDriveTransferService.swift
        GoogleDriveMetadataService.swift
        DriveUploadMetadata.swift
      Firebase/
        InvoiceFirestoreUploader.swift
      InvoiceRemoteSynchronizer.swift

  UI/
    Invoice/
      InvoiceTabView.swift
      InvoiceListView.swift
      InvoiceDetailView.swift
      InvoiceCaptureControls.swift
    Expense/
      ExpenseTabView.swift
      ExpenseAnalyticsViewModel.swift
      Charts/
        ExpenseCategoryBarChart.swift
        ExpenseSupplierBarChart.swift
        ExpenseComparisonView.swift
    Profile/
      ProfileTabView.swift

  Utilities/
    Extensions/
      Decimal+InvoiceFormatting.swift
      String+InvoiceTrimming.swift
      Date+InvoiceFormatting.swift
    Formatting/
      NumberFormatter+Currency.swift
    CSV/
      ExpenseCSVExporter.swift
```

## Dependency Injection

- `AppEnvironment` constructs the concrete implementations and exposes them via `EnvironmentKey`s. SwiftUI views read them using `@Environment` or `@EnvironmentObject`.
- `InvoiceArchive` accepts `InvoicePersistence` and `InvoiceSyncScheduling` protocols. The default implementation combines `LocalInvoiceStore` (JSON persistence) with the Drive sync scheduler.
- `ExpenseAnalyticsViewModel` now receives `InvoiceArchive` and `ReportingPeriodStore` via injection, making it testable without global state.

## Concurrency Notes

- Actors (`InvoiceSyncTracker`, async Drive transfer services) isolate mutable state.
- Networking and persistence tasks run on background priorities and hop back to the main actor when updating UI-bound state.

## Documentation & Testing

- README gets an updated "Architecture" section summarising these modules alongside setup steps for Drive/Firebase.
- New tests target persistence (JSON round trips), sync retry logic, and analytics filtering by supplier/category.

This structure informs the concrete refactor tasks that follow.
