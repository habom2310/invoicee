internal import SwiftUI

/// Presents profit summaries derived from revenue and expenses.
struct ProfitTabView: View {
    @EnvironmentObject private var driveConnector: GoogleDriveConnector
    @StateObject private var viewModel: ProfitAnalyticsViewModel
    @StateObject private var export = CSVExportController()

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
    }

    private var profitList: some View {
        List {
            ReportingPeriodSelector(selection: $viewModel.selection)
            summarySection

            if viewModel.selection.period == .year {
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

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Profit")
                            .font(.headline)
                        // The selector already names the period; this spells out its span.
                        if let description = viewModel.selection.rangeDescription {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(viewModel.profitText)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        // A year's figure is wide enough to wrap and orphan a digit.
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
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
                Text("No profit data for \(viewModel.selection.title) yet.")
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
                      filename: "profit_\(viewModel.selection.exportIdentifier).csv",
                      mirroringTo: driveConnector)
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

        guard viewModel.selection.period == .year, !viewModel.monthlyBreakdown.isEmpty else { return rows }

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
