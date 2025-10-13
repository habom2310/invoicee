# Testing Guide

## Available Tests

- `LocalInvoiceStoreTests` verifies JSON persistence round-trips and missing file behaviour.
- `GoogleDriveSyncCoordinatorTests` exercises sync retries by faking Drive + Firestore dependencies.
- `ExpenseAnalyticsViewModelTests` covers category/supplier aggregations for the reporting month.

Drop the `InvoiceeTests` folder into an `XCTest` target in Xcode (File ▸ New ▸ Target ▸ Unit Testing Bundle) and add the folder as a group. The files already import `@testable import Invoicee`; no additional wiring is needed beyond setting the bundle to depend on the `Invoicee` app target.

## Coverage Gaps

- UI snapshot tests are still outstanding (Invoice list/detail, Expense charts, Drive settings).
- Firebase/Drive integration paths are mocked; integration tests will require instrumentation against staging services.
- OCR pipelines and manual form validation only receive indirect coverage; consider adding focused tests once the OCR module stabilises.

Run the suite from Xcode (`⌘U`) once the test target is configured. For CI, add `xcodebuild test -scheme Invoicee -destination "platform=iOS Simulator,name=iPhone 15"` to ensure the analytics + persistence regressions are caught.
