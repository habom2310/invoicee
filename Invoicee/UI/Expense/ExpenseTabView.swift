internal import SwiftUI

/// Summarises expenses and charts trends over time.
struct ExpenseTabView: View {
    @StateObject private var viewModel: ExpenseAnalyticsViewModel
    init(viewModel: @autoclosure @escaping () -> ExpenseAnalyticsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }
    private static let breakdownLimit = 10
    @State private var isShowingMonthPicker = false
    @State private var showAllCategoryRows = false
    @State private var showAllSupplierRows = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.invoiceBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Expenses")
        }
        .task {
            await viewModel.refresh()
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

            Section("\(viewModel.selectedMetric.displayName) for \(viewModel.selectedPeriodDescription)") {
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
                        Text(viewModel.selectedPeriodDescription)
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
                                Text(String(year)).tag(year)
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
    }

    private var filterSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                metricSelector

                HStack(spacing: 12) {
                    periodButton
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
                Text(viewModel.selectedPeriodDescriptionFormatted)
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
                Text("Year \(viewModel.selectedYear)")
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
                Text("No categories with spending for \(viewModel.selectedPeriodDescription.lowercased()).")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ExpenseBreakdownTable(nameHeader: "Category",
                                       rows: displayedCategoryRows,
                                       revenueAvailable: viewModel.monthlyRevenueTotal != nil)
                if viewModel.monthlyRevenueTotal == nil {
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
                Text("Supplier totals are unavailable for \(viewModel.selectedPeriodDescription.lowercased()).")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ExpenseBreakdownTable(nameHeader: "Supplier",
                                       rows: displayedSupplierRows,
                                       revenueAvailable: viewModel.monthlyRevenueTotal != nil)
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
        guard let revenue = viewModel.monthlyRevenueTotal, revenue > 0 else { return nil }
        let ratio = viewModel.totalForSelection / revenue
        let clamped = max(min((ratio as NSDecimalNumber).doubleValue, 999), 0)
        let formatted = clamped.formatted(.percent.precision(.fractionLength(0...1)))
        return "\(formatted) of revenue"
    }

    private func breakdownRows(from entries: [(name: String, total: Decimal)]) -> [ExpenseBreakdownRow] {
        let periodTotal = viewModel.totalForSelection
        let revenueTotal = viewModel.monthlyRevenueTotal
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
