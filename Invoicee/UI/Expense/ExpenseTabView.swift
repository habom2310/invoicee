internal import SwiftUI

/// Summarises expenses and breaks them down by category and supplier.
struct ExpenseTabView: View {
    @EnvironmentObject private var driveConnector: GoogleDriveConnector
    @StateObject private var viewModel: ExpenseAnalyticsViewModel
    @StateObject private var export = CSVExportController()

    init(viewModel: @autoclosure @escaping () -> ExpenseAnalyticsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    /// Rows shown before the "Show All" toggle reveals the rest.
    private static let breakdownLimit = 10

    @State private var showAllCategoryRows = false
    @State private var showAllSupplierRows = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Expenses")
                .background(Color.invoiceBackground.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            startExpenseExport()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(!viewModel.hasDataForSelection)
                        .accessibilityLabel("Export expenses")
                    }
                }
        }
        .task { await viewModel.refresh() }
        .csvExporter(export)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.invoices.isEmpty {
            emptyState
        } else {
            expenseList
        }
    }

    private var expenseList: some View {
        List {
            ReportingPeriodSelector(selection: $viewModel.selection)
            metricSection
            totalSection
            breakdownSection(title: "Category Breakdown",
                             nameHeader: "Category",
                             rows: viewModel.categoryBreakdown,
                             emptyMessage: "No categories with spending for \(viewModel.selection.title).",
                             showAll: $showAllCategoryRows,
                             explainMissingRevenue: true)
            breakdownSection(title: "Supplier Breakdown",
                             nameHeader: "Supplier",
                             rows: viewModel.supplierBreakdown,
                             emptyMessage: "Supplier totals are unavailable for \(viewModel.selection.title).",
                             showAll: $showAllSupplierRows,
                             explainMissingRevenue: false)

            if let message = viewModel.errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Latest refresh failed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            WarningSection(export.errorMessage)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.invoiceBackground)
        .refreshable { await viewModel.refresh() }
        // Collapse the expanded lists whenever the figures underneath them change, so a
        // 40-row list from one month does not stay open over a 3-row month.
        .onChange(of: viewModel.selection) { _, _ in resetBreakdownExpansion() }
        .onChange(of: viewModel.selectedMetric) { _, _ in resetBreakdownExpansion() }
    }

    private var totalSection: some View {
        Section(viewModel.selectedMetric.displayName) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(viewModel.totalFormatted)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer()
                    Text("\(viewModel.totalGSTFormatted) GST")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    // The selector already names the period; this spells out its span.
                    if let description = viewModel.selection.rangeDescription {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let comparison = viewModel.totalVsRevenueDescription {
                        Text(comparison)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var metricSection: some View {
        Section {
            metricSelector
                .padding(.vertical, 4)
        }
    }

    private var metricSelector: some View {
        VStack(spacing: 8) {
            ForEach(ExpenseMetric.allCases) { metric in
                Button {
                    viewModel.selectedMetric = metric
                } label: {
                    let isSelected = viewModel.selectedMetric == metric
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        Text(metric.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(viewModel.selectedMetric == metric ? [.isSelected] : [])
            }
        }
    }

    /// One breakdown table plus its empty state and "Show All" toggle. Both breakdowns
    /// rendered identical 25-line blocks before.
    @ViewBuilder
    private func breakdownSection(title: String,
                                  nameHeader: String,
                                  rows: [ExpenseAnalyticsViewModel.Breakdown],
                                  emptyMessage: String,
                                  showAll: Binding<Bool>,
                                  explainMissingRevenue: Bool) -> some View {
        Section(title) {
            if rows.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ExpenseBreakdownTable(nameHeader: nameHeader,
                                      rows: showAll.wrappedValue ? rows : Array(rows.prefix(Self.breakdownLimit)),
                                      revenueAvailable: viewModel.hasRevenueComparison)

                if explainMissingRevenue, viewModel.selection.period == .month, !viewModel.hasRevenueComparison {
                    Text("Revenue % becomes available once revenue is recorded for this month.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }

                if rows.count > Self.breakdownLimit {
                    Button(showAll.wrappedValue ? "Show Top \(Self.breakdownLimit)" : "Show All") {
                        showAll.wrappedValue.toggle()
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            }
        }
    }

    private func resetBreakdownExpansion() {
        showAllCategoryRows = false
        showAllSupplierRows = false
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)

            Text(viewModel.errorMessage ?? "No expenses to show yet.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("Fetch Latest Invoices", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func startExpenseExport() {
        let invoices = viewModel.invoicesForSelection
        guard !invoices.isEmpty else { return }

        // Named for the period actually on show; it used to always say the month, even
        // when the figures were a week's.
        export.export(rows: CSVExporting.invoiceRows(from: invoices, uncategorizedLabel: "Uncategorized"),
                      filename: "expense_\(viewModel.selection.exportIdentifier).csv",
                      mirroringTo: driveConnector)
    }
}

private struct ExpenseBreakdownTable: View {
    let nameHeader: String
    let rows: [ExpenseAnalyticsViewModel.Breakdown]
    /// Whether a revenue figure exists; when it does not, the column is dimmed rather
    /// than hidden so the layout does not shift as revenue is recorded.
    let revenueAvailable: Bool

    private enum Column {
        static let amount: CGFloat = 90
        static let expenseShare: CGFloat = 65
        static let revenueShare: CGFloat = 75
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
                .padding(.vertical, 6)
            Divider()
            ForEach(rows) { row in
                rowView(for: row)
                    .padding(.vertical, 8)
                if row.id != rows.last?.id {
                    Divider()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var headerRow: some View {
        HStack {
            columnHeader(nameHeader, width: nil)
            columnHeader("Amount", width: Column.amount)
            columnHeader("Expense %", width: Column.expenseShare)
            columnHeader("Revenue %", width: Column.revenueShare)
        }
    }

    @ViewBuilder
    private func columnHeader(_ title: String, width: CGFloat?) -> some View {
        let text = Text(title)
            .font(.caption.smallCaps())
            .foregroundStyle(.secondary)
        if let width {
            text.frame(width: width, alignment: .trailing)
        } else {
            text.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rowView(for row: ExpenseAnalyticsViewModel.Breakdown) -> some View {
        HStack(spacing: 8) {
            Text(row.name)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)

            Text(row.amount.formattedCurrency())
                .font(.footnote)
                .frame(width: Column.amount, alignment: .trailing)

            Text(ExpenseAnalyticsViewModel.percentText(row.shareOfExpenses))
                .font(.footnote)
                .frame(width: Column.expenseShare, alignment: .trailing)

            Text(ExpenseAnalyticsViewModel.percentText(row.shareOfRevenue))
                .font(.footnote)
                .frame(width: Column.revenueShare, alignment: .trailing)
                .foregroundStyle(revenueAvailable ? .primary : .tertiary)
        }
    }
}
