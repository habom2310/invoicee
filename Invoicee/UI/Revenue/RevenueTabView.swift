internal import SwiftUI

/// Displays revenue summaries and daily entries with editing support.
struct RevenueTabView: View {
    @StateObject private var viewModel: RevenueViewModel
    private let monthSymbols = Calendar.current.monthSymbols

    init(viewModel: @autoclosure @escaping () -> RevenueViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Revenue")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if viewModel.canRecordRevenue {
                            Button {
                                viewModel.beginAddingRevenue()
                            } label: {
                                Image(systemName: "plus.circle.fill")
                            }
                            .accessibilityLabel("Add Revenue")
                        }
                    }
                }
        }
        .sheet(isPresented: $viewModel.isPresentingForm) {
            RevenueFormSheet(viewModel: viewModel)
        }
        .task {
            if viewModel.canRecordRevenue {
                await viewModel.refresh()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.canRecordRevenue {
            linkPrompt
        } else {
            revenueList
        }
    }

    private var revenueList: some View {
        List {
            summarySection

            Section("Daily Revenue") {
                if viewModel.entries.isEmpty {
                    Label("No revenue recorded yet.", systemImage: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(viewModel.entries) { entry in
                        RevenueEntryRow(entry: entry,
                                        total: entry.total.formattedCurrency(),
                                        subtitle: viewModel.formattedStreams(for: entry))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.beginAddingRevenue(for: entry.date)
                            }
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
        }
        .background(Color.invoiceBackground)
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.summaryTitle)
                            .font(.headline)
                        Text(viewModel.summarySubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(viewModel.summaryTotalFormatted)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                }

                Picker("Period", selection: $viewModel.selectedFilter) {
                    ForEach(RevenueViewModel.SummaryFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                if viewModel.selectedFilter == .selectedMonth {
                    HStack {
                        Picker("Month", selection: $viewModel.selectedMonth) {
                            ForEach(1...12, id: \.self) { month in
                                Text(monthSymbols[month - 1]).tag(month)
                            }
                        }
                        .pickerStyle(.menu)

                        Picker("Year", selection: $viewModel.selectedYear) {
                            ForEach(viewModel.availableYears, id: \.self) { year in
                                Text(String(year)).tag(year)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } else if viewModel.selectedFilter == .year {
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

    private var linkPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "link.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Link Google Drive to start tracking revenue.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct RevenueEntryRow: View {
    let entry: RevenueDayEntry
    let total: String
    let subtitle: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.date, style: .date)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(total)
                    .font(.subheadline.weight(.semibold))
            }

            if !subtitle.isEmpty {
                Text(subtitle.joined(separator: " • "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RevenueFormSheet: View {
    @ObservedObject var viewModel: RevenueViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    DatePicker("Revenue Date",
                               selection: $viewModel.formDate,
                               in: ...Date(),
                               displayedComponents: .date)
                        .onChange(of: viewModel.formDate) { _ in
                            viewModel.handleFormDateChange()
                        }
                }

                Section("Streams") {
                    ForEach($viewModel.formStreams) { $stream in
                        HStack(spacing: 12) {
                            TextField("Name", text: $stream.name)
                                .textInputAutocapitalization(.words)
                                .disableAutocorrection(true)

                            TextField("Amount", text: $stream.amountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 110)
                        }
                    }
                    .onDelete(perform: viewModel.removeStreams)

                    Button {
                        viewModel.addStream()
                    } label: {
                        Label("Add Stream", systemImage: "plus.circle")
                    }
                }

                if viewModel.isEditingExistingForm {
                    Section {
                        Label("Editing existing revenue for this day.", systemImage: "square.and.pencil")
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = viewModel.formErrorMessage {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(viewModel.isEditingExistingForm ? "Edit Revenue" : "Add Revenue")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.isPresentingForm = false
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await viewModel.saveCurrentForm() }
                    } label: {
                        if viewModel.isSavingForm {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(viewModel.isSavingForm)
                }
            }
        }
    }
}
