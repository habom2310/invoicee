internal import SwiftUI

/// Displays revenue summaries and daily entries with editing support.
struct RevenueTabView: View {
    @EnvironmentObject private var driveConnector: GoogleDriveConnector
    @StateObject private var viewModel: RevenueViewModel
    @StateObject private var export = CSVExportController()
    @State private var isShowingMonthPicker = false

    init(viewModel: @autoclosure @escaping () -> RevenueViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Revenue")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            startRevenueExport()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(viewModel.listEntries.isEmpty)
                        .accessibilityLabel("Export revenue")
                    }

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
        .csvExporter(export)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.canRecordRevenue {
            revenueList
        } else {
            LinkPromptView(message: "Link Google Drive to start tracking revenue.")
        }
    }

    private var revenueList: some View {
        List {
            filterControls
            summarySection
            entriesSection
            WarningSection(viewModel.errorMessage)
            WarningSection(export.errorMessage)
        }
        .listStyle(.insetGrouped)
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
        }
        .background(Color.invoiceBackground)
        .sheet(isPresented: $isShowingMonthPicker) {
            MonthYearPickerSheet(month: $viewModel.selectedMonth,
                                 year: $viewModel.selectedYear,
                                 years: viewModel.availableYears)
        }
    }

    private var entriesSection: some View {
        Section(viewModel.selectedPeriod == .year ? "Monthly Revenue" : "Daily Revenue") {
            if viewModel.listEntries.isEmpty {
                Label("No revenue recorded yet.", systemImage: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.listEntries) { entry in
                    RevenueEntryRow(title: viewModel.displayTitle(for: entry),
                                    total: entry.total.formattedCurrency(),
                                    streams: viewModel.formattedStreams(for: entry))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Yearly rows are rollups of many days, so there is no single
                            // entry for the editor to open.
                            guard viewModel.rowsAreEditable else { return }
                            viewModel.beginAddingRevenue(for: entry.date)
                        }
                }
            }
        }
    }

    private var filterControls: some View {
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
                    Text(viewModel.summarySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .month:
                    MonthPickerButton(title: "\(ReportingDateFormatter.name(for: viewModel.selectedMonth)) \(viewModel.selectedYear)") {
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
                        Text(viewModel.summarySubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(viewModel.summaryTotalFormatted)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("Plus \(viewModel.summaryGSTFormatted) GST")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                let streams = viewModel.streamTotalsForSelection
                if streams.isEmpty {
                    Text("No revenue streams recorded for this period.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    RevenueStreamBreakdownTable(streams: streams, total: viewModel.summaryTotal)
                        .padding(.top, 8)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func startRevenueExport() {
        let entries = viewModel.listEntries
        guard !entries.isEmpty else { return }
        export.export(rows: makeRevenueRows(from: entries),
                      filename: "revenue_\(periodIdentifier).csv",
                      mirroringTo: driveConnector)
    }

    private var periodIdentifier: String {
        switch viewModel.selectedPeriod {
        case .week: ReportingDateFormatter.weekIdentifier(viewModel.currentWeekRange)
        case .month: ReportingDateFormatter.monthIdentifier(month: viewModel.selectedMonth, year: viewModel.selectedYear)
        case .year: "\(viewModel.selectedYear)"
        }
    }

    private func makeRevenueRows(from entries: [RevenueDayEntry]) -> [[String]] {
        let isYearly = viewModel.selectedPeriod == .year
        var rows: [[String]] = [[isYearly ? "Month" : "Date", "Stream", "Amount"]]
        var total: Decimal = .zero

        for entry in entries {
            let label = isYearly
                ? ReportingDateFormatter.monthAndYear(entry.date)
                : ReportingDateFormatter.isoDay(entry.date)

            if entry.streams.isEmpty {
                rows.append([label, "Total", entry.total.plainString])
            } else {
                rows.append(contentsOf: entry.streams.map { [label, $0.name, $0.amount.plainString] })
                rows.append([label, "TOTAL", entry.total.plainString])
            }
            total += entry.total
        }

        rows.append(["", "OVERALL TOTAL", total.plainString])
        return rows
    }
}

/// Shown in place of a report when Drive is not linked and the data lives remotely.
struct LinkPromptView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "link.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct RevenueEntryRow: View {
    let title: String
    let total: String
    let streams: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(total)
                    .font(.subheadline.weight(.semibold))
            }

            if !streams.isEmpty {
                Text(streams.joined(separator: " • "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RevenueStreamBreakdownTable: View {
    let streams: [RevenueStreamValue]
    let total: Decimal

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                header("Stream", width: nil)
                header("Amount", width: 100)
                header("%", width: 60)
            }
            .padding(.vertical, 6)

            Divider()

            ForEach(streams) { stream in
                HStack {
                    Text(stream.name)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                    Text(stream.amount.formattedCurrency())
                        .font(.footnote)
                        .frame(width: 100, alignment: .trailing)
                    Text(share(of: stream.amount))
                        .font(.footnote)
                        .frame(width: 60, alignment: .trailing)
                }
                .padding(.vertical, 6)

                if stream.id != streams.last?.id {
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func header(_ title: String, width: CGFloat?) -> some View {
        let text = Text(title)
            .font(.caption.smallCaps())
            .foregroundStyle(.secondary)
        if let width {
            text.frame(width: width, alignment: .trailing)
        } else {
            text.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func share(of value: Decimal) -> String {
        guard total > 0 else { return "—" }
        return ExpenseAnalyticsViewModel.percentText(value / total)
    }
}

private struct RevenueFormSheet: View {
    @ObservedObject var viewModel: RevenueViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    DatePicker("Revenue Date",
                               selection: $viewModel.formDate,
                               in: ...Date(),
                               displayedComponents: .date)
                        .onChange(of: viewModel.formDate) { _, _ in
                            viewModel.handleFormDateChange()
                        }
                }

                Section("Streams") {
                    ForEach($viewModel.formStreams) { $stream in
                        HStack(spacing: 12) {
                            TextField("Name", text: $stream.name)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()

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
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(viewModel.isEditingExistingForm ? "Edit Revenue" : "Add Revenue")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // The sheet is driven by `isPresentingForm`, so clearing it is what
                    // dismisses; calling `dismiss()` as well left the flag set on cancel.
                    Button("Cancel") { viewModel.isPresentingForm = false }
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
