internal import SwiftUI

/// Presents profit summaries derived from revenue and expenses.
struct ProfitTabView: View {
    @StateObject private var viewModel: ProfitAnalyticsViewModel
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
                    linkPrompt
                }
            }
            .navigationTitle("Profit")
            .background(Color.invoiceBackground.ignoresSafeArea())
        }
        .task {
            await viewModel.refresh()
        }
        .sheet(isPresented: $isShowingMonthPicker) {
            monthPickerSheet
        }
    }

    private var profitList: some View {
        List {
            filterSection
            summarySection

            if viewModel.selectedFilter == .year {
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

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
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
            }
        }
    }

    private var filterSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Period", selection: $viewModel.selectedFilter) {
                    ForEach(ProfitAnalyticsViewModel.Filter.allCases) { filter in
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
                    Button {
                        isShowingMonthPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "calendar")
                            Text(viewModel.monthPickerLabel)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                case .year:
                    Picker("Year", selection: $viewModel.selectedYear) {
                        ForEach(viewModel.availableYears, id: \.self) { year in
                            Text(String(year)).tag(year)
                        }
                    }
                    .pickerStyle(.menu)
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
                if let percentage = viewModel.profitPercentageText {
                    Text(percentage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No revenue recorded for this period yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                                   profitText: breakdown.profit.formattedCurrency(),
                                   percentageText: viewModel.formattedPercentage(for: breakdown))
                }
            }
        }
    }

    private var monthPickerSheet: some View {
        NavigationStack {
            VStack {
                Text("Select Month")
                    .font(.headline)
                    .padding(.top)

                HStack(spacing: 0) {
                    Picker("Month", selection: $viewModel.selectedMonth) {
                        ForEach(1...12, id: \.self) { month in
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

    private var linkPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "link.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Link Google Drive to calculate profit.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
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

            if let percentageText {
                Text("\(percentageText) of revenue")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No revenue recorded for this month.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
