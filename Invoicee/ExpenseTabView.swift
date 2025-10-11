import SwiftUI

struct ExpenseTabView: View {
    @StateObject private var viewModel = ExpenseAnalyticsViewModel()
    @State private var isShowingMonthPicker = false
    @State private var comparisonContext: ExpenseComparisonContext? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.invoiceBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Expenses")
            .navigationDestination(item: $comparisonContext) { _ in
                ExpenseComparisonView(categoryTotals: viewModel.categoryTotals,
                                       previousTotals: viewModel.previousMonthTotals,
                                       metric: viewModel.selectedMetric,
                                       currentLabel: viewModel.selectedPeriodDescription,
                                       previousLabel: viewModel.previousMonthDescription ?? "Previous Month")
            }
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
            Section {
                HStack(spacing: 12) {
                    Menu {
                        Picker("", selection: $viewModel.selectedMetric) {
                            ForEach(ExpenseAnalyticsViewModel.Metric.allCases) { metric in
                                Text(metric.displayName).tag(metric)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HStack {
                            Text(viewModel.selectedMetric.displayName)
                                .font(.callout)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Spacer()

                    Button {
                        isShowingMonthPicker = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar")
                            Text(viewModel.selectedPeriodDescriptionFormatted)
                                .font(.callout)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("\(viewModel.selectedMetric.displayName) for \(viewModel.selectedPeriodDescription)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.totalFormatted)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(viewModel.selectedPeriodDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if !viewModel.categoryTotals.isEmpty {
                Section("Category Breakdown") {
                    Button {
                        openComparison()
                    } label: {
                        ExpenseCategoryBarChart(totals: viewModel.categoryTotals,
                                                 metric: viewModel.selectedMetric)
                            .frame(height: CGFloat(viewModel.categoryTotals.count) * 28 + 40)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("\(viewModel.selectedMetric.displayName) by Category") {
                if viewModel.categoryTotals.isEmpty {
                    Text("No expenses recorded for \(viewModel.selectedPeriodDescription.lowercased()).")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.categoryTotals) { categoryTotal in
                        HStack {
                            Text(categoryTotal.category)
                            Spacer()
                            Text(categoryTotal.total.formattedCurrency())
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }

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

    private func openComparison() {
        guard !viewModel.categoryTotals.isEmpty else { return }
        comparisonContext = ExpenseComparisonContext()
    }
}

private struct ExpenseComparisonContext: Identifiable, Hashable {
    let id = UUID()
}
