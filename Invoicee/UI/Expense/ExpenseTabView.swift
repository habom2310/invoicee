internal import SwiftUI
import UniformTypeIdentifiers

/// Summarises expenses and charts trends over time.
struct ExpenseTabView: View {
    @EnvironmentObject private var driveConnector: GoogleDriveConnector
    @StateObject private var viewModel: ExpenseAnalyticsViewModel
    init(viewModel: @autoclosure @escaping () -> ExpenseAnalyticsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }
    private static let breakdownLimit = 10
    @State private var isShowingMonthPicker = false
    @State private var showAllCategoryRows = false
    @State private var showAllSupplierRows = false
    @State private var isExportingCSV = false
    @State private var exportDocument = CSVDocument(text: "")
    @State private var exportErrorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.invoiceBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Expenses")
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
        .task {
            await viewModel.refresh()
        }
        .fileExporter(isPresented: $isExportingCSV,
                      document: exportDocument,
                      contentType: .commaSeparatedText,
                      defaultFilename: expenseExportFilename) { result in
            if case let .failure(error) = result {
                exportErrorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.invoices.isEmpty {
            ProgressView("Loading expenses…")
                .progressViewStyle(.circular)
        } else if viewModel.invoices.isEmpty {
            emptyState
        } else {
            expenseList
        }
    }

    private var expenseList: some View {
        List {
            filterSection

            Section("\(viewModel.selectedMetric.displayName) for \(viewModel.selectedPeriodDisplayTitle)") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(viewModel.totalFormatted)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Spacer()
                        Text("\(viewModel.totalGSTFormatted) GST")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.selectedPeriodDetailDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let percentage = totalVsRevenueText {
                            Text(percentage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            categorySection
            supplierSection

            if let errorMessage = viewModel.errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Latest refresh failed", systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            if let exportErrorMessage {
                Section {
                    Label(exportErrorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.invoiceBackground)
        .refreshable {
            await viewModel.refresh()
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
            }
        }
        .sheet(isPresented: $isShowingMonthPicker) {
            NavigationStack {
                VStack {
                    Text("Select Month")
                        .font(.headline)
                        .padding(.top)

                    HStack(spacing: 0) {
                        Picker("Month", selection: $viewModel.selectedMonth) {
                            ForEach(viewModel.availableMonths, id: \.self) { month in
                                Text(viewModel.monthName(for: month)).tag(month)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .clipped()

                        Picker("Year", selection: $viewModel.selectedYear) {
                            ForEach(viewModel.availableYears, id: \.self) { year in
                                Text(verbatim: String(year)).tag(year)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .clipped()
                    }
                    .padding(.horizontal)

                    Spacer()
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            isShowingMonthPicker = false
                        }
                    }
                }
            }
            .presentationDetents([.height(320), .medium])
        }
        .onChange(of: viewModel.selectedMonth) { _, _ in resetBreakdownExpansion() }
        .onChange(of: viewModel.selectedYear) { _, _ in resetBreakdownExpansion() }
        .onChange(of: viewModel.selectedMetric) { _, _ in resetBreakdownExpansion() }
        .onChange(of: viewModel.selectedFilter) { _, _ in resetBreakdownExpansion() }
    }

    private var filterSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                metricSelector

                Picker("Period", selection: $viewModel.selectedFilter) {
                    ForEach(ExpenseAnalyticsViewModel.Filter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                switch viewModel.selectedFilter {
                case .week:
                    if let description = viewModel.weekRangeDescription {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .month:
                    periodButton
                case .year:
                    yearPicker
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var metricSelector: some View {
        VStack(spacing: 8) {
            ForEach(ExpenseAnalyticsViewModel.Metric.allCases) { metric in
                Button {
                    viewModel.selectedMetric = metric
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: viewModel.selectedMetric == metric ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(viewModel.selectedMetric == metric ? Color.accentColor : Color.secondary)
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
            }
        }
    }

    private var periodButton: some View {
        Button {
            isShowingMonthPicker = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                Text(viewModel.monthPickerLabel)
                    .font(.callout)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var yearPicker: some View {
        Menu {
            Picker("Year", selection: $viewModel.selectedYear) {
                ForEach(viewModel.availableYears, id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                Text(verbatim: "Year \(viewModel.selectedYear)")
                    .font(.callout)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var categorySection: some View {
        Section("Category Breakdown") {
            if categoryRows.isEmpty {
                Text("No categories with spending for \(viewModel.selectedPeriodSentence).")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ExpenseBreakdownTable(nameHeader: "Category",
                                       rows: displayedCategoryRows,
                                       revenueAvailable: viewModel.selectedFilter == .month && viewModel.monthlyRevenueTotal != nil)
                if viewModel.selectedFilter == .month && viewModel.monthlyRevenueTotal == nil {
                    Text("Revenue % becomes available once revenue is recorded for this month.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
                if categoryRows.count > Self.breakdownLimit {
                    Button(showAllCategoryRows ? "Show Top 10" : "Show All") {
                        showAllCategoryRows.toggle()
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var supplierSection: some View {
        Section("Supplier Breakdown") {
            if supplierRows.isEmpty {
                Text("Supplier totals are unavailable for \(viewModel.selectedPeriodSentence).")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ExpenseBreakdownTable(nameHeader: "Supplier",
                                       rows: displayedSupplierRows,
                                       revenueAvailable: viewModel.selectedFilter == .month && viewModel.monthlyRevenueTotal != nil)
                if supplierRows.count > Self.breakdownLimit {
                    Button(showAllSupplierRows ? "Show Top 10" : "Show All") {
                        showAllSupplierRows.toggle()
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            }
        }
    }

    private var categoryRows: [ExpenseBreakdownRow] {
        breakdownRows(from: viewModel.categoryTotals.map { ($0.category, $0.total) })
    }

    private var supplierRows: [ExpenseBreakdownRow] {
        breakdownRows(from: viewModel.supplierTotals.map { ($0.supplier, $0.total) })
    }

    private var displayedCategoryRows: [ExpenseBreakdownRow] {
        showAllCategoryRows ? categoryRows : Array(categoryRows.prefix(Self.breakdownLimit))
    }

    private var displayedSupplierRows: [ExpenseBreakdownRow] {
        showAllSupplierRows ? supplierRows : Array(supplierRows.prefix(Self.breakdownLimit))
    }

    private var totalVsRevenueText: String? {
        guard viewModel.selectedFilter == .month,
              let revenue = viewModel.monthlyRevenueTotal,
              revenue > 0 else { return nil }
        let ratio = viewModel.totalForSelection / revenue
        let clamped = max(min((ratio as NSDecimalNumber).doubleValue, 999), 0)
        let formatted = clamped.formatted(.percent.precision(.fractionLength(0...1)))
        return "\(formatted) of revenue"
    }

    private func breakdownRows(from entries: [(name: String, total: Decimal)]) -> [ExpenseBreakdownRow] {
        let periodTotal = viewModel.totalForSelection
        let revenueTotal = viewModel.selectedFilter == .month ? viewModel.monthlyRevenueTotal : nil
        return entries
            .filter { $0.total > 0 }
            .map { entry in
                let expenseRatio: Decimal = periodTotal > 0 ? entry.total / periodTotal : 0
                let revenueRatio: Decimal?
                if let revenueTotal, revenueTotal > 0 {
                    revenueRatio = entry.total / revenueTotal
                } else {
                    revenueRatio = nil
                }
                return ExpenseBreakdownRow(name: entry.name,
                                           amount: entry.total,
                                           expensePercentage: expenseRatio,
                                           revenuePercentage: revenueRatio)
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

            if let message = viewModel.errorMessage {
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Text("No expenses to show yet.")
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Label("Fetch Latest Invoices", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

}

private extension ExpenseTabView {
    func startExpenseExport() {
        let invoices = viewModel.invoicesForSelection
        guard !invoices.isEmpty else { return }

        let csvContent = makeExpenseCSV(from: invoices)
        exportDocument = CSVDocument(text: csvContent)
        isExportingCSV = true

        let filename = expenseExportFilename
        Task {
            await uploadExpenseCSV(content: csvContent, filename: filename)
        }
    }

    var expenseExportFilename: String {
        "expense_\(expensePeriodIdentifier).csv"
    }

    var expensePeriodIdentifier: String {
        let rawMonth = viewModel.monthName(for: viewModel.selectedMonth, short: true)
        let sanitizedMonth = rawMonth.replacingOccurrences(of: " ", with: "")
        return "\(sanitizedMonth)_\(viewModel.selectedYear)"
    }

    func makeExpenseCSV(from invoices: [CapturedInvoice]) -> String {
        var rows: [[String]] = [[
            "Date",
            "Supplier",
            "Total Amount",
            "Our Amount",
            "GST",
            "Category"
        ]]

        for invoice in invoices {
            rows.append([
                expenseCSVDateFormatter.string(from: invoice.date),
                invoice.supplier,
                invoice.total.plainString,
                invoice.ourAmount.plainString,
                invoice.gst.plainString,
                invoice.category ?? "Uncategorized"
            ])
        }

        let totalsRow = [
            "",
            "TOTAL",
            invoices.reduce(Decimal.zero) { $0 + $1.total }.plainString,
            invoices.reduce(Decimal.zero) { $0 + $1.ourAmount }.plainString,
            invoices.reduce(Decimal.zero) { $0 + $1.gst }.plainString,
            ""
        ]
        rows.append(totalsRow)

        return CSVExporting.makeCSV(from: rows)
    }

    func uploadExpenseCSV(content: String, filename: String) async {
        let transferService = await MainActor.run { driveConnector.transferService }
        let state = await MainActor.run { driveConnector.state }
        guard state == .linked else { return }

        do {
            try await CSVExporting.uploadToDrive(content: content,
                                                 filename: filename,
                                                 transferService: transferService)
            await MainActor.run { exportErrorMessage = nil }
        } catch {
            await MainActor.run {
                exportErrorMessage = error.localizedDescription
            }
        }
    }
}

private let expenseCSVDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private struct ExpenseBreakdownRow: Identifiable {
    let name: String
    let amount: Decimal
    let expensePercentage: Decimal
    let revenuePercentage: Decimal?

    var id: String { name }
}

private struct ExpenseBreakdownTable: View {
    let nameHeader: String
    let rows: [ExpenseBreakdownRow]
    let revenueAvailable: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerRow
                .padding(.vertical, 6)
            Divider()
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowView(for: row)
                    .padding(.vertical, 8)
                if index < rows.count - 1 {
                    Divider()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var headerRow: some View {
        HStack {
            Text(nameHeader)
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Amount")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text("Expense %")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .frame(width: 65, alignment: .trailing)
            Text("Revenue %")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .frame(width: 75, alignment: .trailing)
        }
    }

    private func rowView(for row: ExpenseBreakdownRow) -> some View {
        HStack(spacing: 8) {
            Text(row.name)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)

            Text(row.amount.formattedCurrency())
                .font(.footnote)
                .frame(width: 90, alignment: .trailing)

            Text(formattedPercent(row.expensePercentage))
                .font(.footnote)
                .frame(width: 65, alignment: .trailing)

            Text(formattedPercent(row.revenuePercentage))
                .font(.footnote)
                .frame(width: 75, alignment: .trailing)
                .foregroundStyle(revenueAvailable ? .primary : .tertiary)
        }
    }

    private func formattedPercent(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let clamped = max(min((value as NSDecimalNumber).doubleValue, 999), -999)
        return clamped.formatted(.percent.precision(.fractionLength(0...1)))
    }
}
