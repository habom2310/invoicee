internal import SwiftUI

/// Presents profit summaries derived from revenue and expenses.
struct ProfitTabView: View {
    @EnvironmentObject private var driveConnector: GoogleDriveConnector
    @StateObject private var viewModel: ProfitAnalyticsViewModel
    @StateObject private var export = CSVExportController()
    @State private var isShowingMonthPicker = false

    init(viewModel: @autoclosure @escaping () -> ProfitAnalyticsViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isDriveLinked {
                    profitList
                } else {
                    LinkPromptView(message: "Link Google Drive to calculate profit.")
                }
            }
            .navigationTitle("Profit")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        startProfitExport()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(!viewModel.hasAnyData)
                    .accessibilityLabel("Export profit data")
                }
            }
            .background(Color.invoiceBackground.ignoresSafeArea())
        }
        .task { await viewModel.refresh() }
        .csvExporter(export)
        .sheet(isPresented: $isShowingMonthPicker) {
            MonthYearPickerSheet(month: $viewModel.selectedMonth,
                                 year: $viewModel.selectedYear,
                                 years: viewModel.availableYears)
        }
    }

    private var profitList: some View {
        List {
            filterSection
            summarySection

            if viewModel.selectedPeriod == .year {
                yearlyBreakdownSection
            }

            if !viewModel.hasAnyData {
                Section {
                    Text("Record revenue and expenses to start tracking profit.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }

            WarningSection(viewModel.errorMessage)
            WarningSection(export.errorMessage)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.invoiceBackground)
        .refreshable { await viewModel.refresh() }
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
        }
    }

    private var filterSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Period", selection: $viewModel.selectedPeriod) {
                    ForEach(ReportingPeriod.allCases) { period in
                        Text(period.displayName).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                switch viewModel.selectedPeriod {
                case .week:
                    if let description = viewModel.weekRangeDescription {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .month:
                    MonthPickerButton(title: viewModel.monthPickerLabel) {
                        isShowingMonthPicker = true
                    }
                case .year:
                    YearMenuButton(selection: $viewModel.selectedYear, years: viewModel.availableYears)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.summaryTitle)
                            .font(.headline)
                        if !viewModel.summarySubtitle.isEmpty {
                            Text(viewModel.summarySubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(viewModel.profitText)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                }

                Text(viewModel.profitPercentageText ?? "No revenue recorded for this period yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var yearlyBreakdownSection: some View {
        Section("Monthly Profit") {
            if viewModel.monthlyBreakdown.isEmpty {
                Text("No profit data for \(viewModel.selectedYear) yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(viewModel.monthlyBreakdown) { breakdown in
                    ProfitMonthRow(monthName: viewModel.monthName(for: breakdown.month),
                                   profitText: breakdown.summary.profit.formattedCurrency(),
                                   percentageText: ProfitAnalyticsViewModel.percentageText(breakdown.summary.profitPercentage))
                }
            }
        }
    }

    private func startProfitExport() {
        guard viewModel.hasAnyData else { return }
        export.export(rows: makeProfitRows(),
                      filename: "profit_\(periodIdentifier).csv",
                      mirroringTo: driveConnector)
    }

    private var periodIdentifier: String {
        switch viewModel.selectedPeriod {
        case .week: ReportingDateFormatter.weekIdentifier(viewModel.selectedDateRange)
        case .month: ReportingDateFormatter.monthIdentifier(month: viewModel.selectedMonth, year: viewModel.selectedYear)
        case .year: "\(viewModel.selectedYear)"
        }
    }

    private func makeProfitRows() -> [[String]] {
        let summary = viewModel.summary
        var rows: [[String]] = [
            ["Metric", "Amount"],
            ["Revenue Gross", summary.revenueGross.plainString],
            ["Revenue Net", summary.revenueNet.plainString],
            ["Expense Total", summary.expenseTotal.plainString],
            ["Expense GST", summary.expenseGST.plainString],
            ["Expense Net", summary.expenseNet.plainString],
            ["Profit", summary.profit.plainString],
            ["Profit %", percentOrNA(summary.profitPercentage)]
        ]

        guard viewModel.selectedPeriod == .year, !viewModel.monthlyBreakdown.isEmpty else { return rows }

        rows.append(["", ""])
        rows.append(Self.monthlyHeader)
        rows.append(contentsOf: viewModel.monthlyBreakdown.map { breakdown in
            let summary = breakdown.summary
            return [
                viewModel.monthName(for: breakdown.month),
                summary.revenueGross.plainString,
                summary.revenueNet.plainString,
                summary.expenseTotal.plainString,
                summary.expenseGST.plainString,
                summary.expenseNet.plainString,
                summary.profit.plainString,
                percentOrNA(summary.profitPercentage)
            ]
        })
        return rows
    }

    private static let monthlyHeader = [
        "Month",
        "Revenue Gross",
        "Revenue Net",
        "Expense Total",
        "Expense GST",
        "Expense Net",
        "Profit",
        "Profit %"
    ]

    private func percentOrNA(_ value: Decimal?) -> String {
        ProfitAnalyticsViewModel.percentageText(value) ?? "N/A"
    }
}

private struct ProfitMonthRow: View {
    let monthName: String
    let profitText: String
    let percentageText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(monthName)
                    .font(.subheadline)
                Spacer()
                Text(profitText)
                    .font(.subheadline.weight(.semibold))
            }

            Text(percentageText.map { "\($0) of revenue" } ?? "No revenue recorded for this month.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
