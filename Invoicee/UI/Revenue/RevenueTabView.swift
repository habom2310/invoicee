internal import SwiftUI
import UniformTypeIdentifiers

/// Displays revenue summaries and daily entries with editing support.
struct RevenueTabView: View {
    @EnvironmentObject private var driveConnector: GoogleDriveConnector
    @StateObject private var viewModel: RevenueViewModel
    private let monthSymbols = Calendar.current.monthSymbols
    @State private var isShowingMonthPicker = false
    @State private var isExportingCSV = false
    @State private var exportDocument = CSVDocument(text: "")
    @State private var exportErrorMessage: String?

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
        .fileExporter(isPresented: $isExportingCSV,
                      document: exportDocument,
                      contentType: .commaSeparatedText,
                      defaultFilename: revenueExportFilename) { result in
            if case let .failure(error) = result {
                exportErrorMessage = error.localizedDescription
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
            filterControls
            summarySection

            Section(viewModel.selectedFilter == .year ? "Monthly Revenue" : "Daily Revenue") {
                if viewModel.listEntries.isEmpty {
                    Label("No revenue recorded yet.", systemImage: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(viewModel.listEntries) { entry in
                        RevenueEntryRow(title: viewModel.displayTitle(for: entry),
                                        total: entry.total.formattedCurrency(),
                                        subtitle: viewModel.formattedStreams(for: entry))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard viewModel.selectedFilter != .year else { return }
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

            if let exportErrorMessage {
                Section {
                    Label(exportErrorMessage, systemImage: "exclamationmark.triangle")
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
        .sheet(isPresented: $isShowingMonthPicker) {
            NavigationStack {
                VStack {
                    Text("Select Month")
                        .font(.headline)
                        .padding(.top)

                    HStack(spacing: 0) {
                        Picker("Month", selection: $viewModel.selectedMonth) {
                            ForEach(1...12, id: \.self) { month in
                                Text(monthSymbols[month - 1]).tag(month)
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
    }

    private var filterControls: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Period", selection: $viewModel.selectedFilter) {
                    ForEach(RevenueViewModel.SummaryFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                switch viewModel.selectedFilter {
                case .month:
                    Button {
                        isShowingMonthPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "calendar")
                            Text(verbatim: "\(monthSymbols[max(0, min(viewModel.selectedMonth - 1, monthSymbols.count - 1))]) \(viewModel.selectedYear)")
                                .font(.callout)
                                .foregroundStyle(.primary)
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
                            Text(verbatim: String(year)).tag(year)
                        }
                    }
                    .pickerStyle(.menu)
                default:
                    Text(viewModel.summarySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Text(viewModel.summaryTotalFormatted)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                }

                if viewModel.streamTotalsForSelection.isEmpty {
                    Text("No revenue streams recorded for this period.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    RevenueStreamBreakdownTable(streams: viewModel.streamTotalsForSelection,
                                                total: viewModel.summaryTotal)
                        .padding(.top, 8)
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

private extension RevenueTabView {
    func startRevenueExport() {
        let entries = viewModel.listEntries
        guard !entries.isEmpty else { return }

        let csvContent = makeRevenueCSV(from: entries)
        exportDocument = CSVDocument(text: csvContent)
        isExportingCSV = true

        let filename = revenueExportFilename
        Task {
            await uploadRevenueCSV(content: csvContent, filename: filename)
        }
    }

    var revenueExportFilename: String {
        "revenue_\(revenuePeriodIdentifier).csv"
    }

    var revenuePeriodIdentifier: String {
        switch viewModel.selectedFilter {
        case .week:
            if let range = viewModel.currentWeekRange {
                let start = weekFilenameFormatter.string(from: range.start)
                let end = weekFilenameFormatter.string(from: range.end)
                return "Week_\(start)_\(end)"
            }
            return "Week_Current"
        case .month:
            let monthIndex = max(1, min(viewModel.selectedMonth, revenueShortMonthSymbols.count))
            let month = revenueShortMonthSymbols[monthIndex - 1].replacingOccurrences(of: " ", with: "")
            return "\(month)_\(viewModel.selectedYear)"
        case .year:
            return "\(viewModel.selectedYear)"
        }
    }

    func makeRevenueCSV(from entries: [RevenueDayEntry]) -> String {
        let periodHeader = viewModel.selectedFilter == .year ? "Month" : "Date"
        var rows: [[String]] = [[periodHeader, "Stream", "Amount"]]
        var total: Decimal = .zero

        for entry in entries {
            let label = entryLabel(for: entry)
            if entry.streams.isEmpty {
                rows.append([label, "Total", entry.total.plainString])
                total += entry.total
                continue
            }

            for stream in entry.streams {
                rows.append([label, stream.name, stream.amount.plainString])
            }
            rows.append([label, "TOTAL", entry.total.plainString])
            total += entry.total
        }

        rows.append(["", "OVERALL TOTAL", total.plainString])
        return CSVExporting.makeCSV(from: rows)
    }

    func entryLabel(for entry: RevenueDayEntry) -> String {
        switch viewModel.selectedFilter {
        case .year:
            return revenueMonthFormatter.string(from: entry.date)
        default:
            return revenueDayFormatter.string(from: entry.date)
        }
    }

    func uploadRevenueCSV(content: String, filename: String) async {
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

private let revenueDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private let revenueMonthFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM yyyy"
    return formatter
}()

private let weekFilenameFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM_dd_yyyy"
    return formatter
}()

private let revenueShortMonthSymbols: [String] = {
    let formatter = DateFormatter()
    return formatter.shortMonthSymbols
}()

private struct RevenueEntryRow: View {
    let title: String
    let total: String
    let subtitle: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
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

private struct RevenueStreamBreakdownTable: View {
    let streams: [RevenueStreamValue]
    let total: Decimal

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Stream")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Amount")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .trailing)
                Text("%")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            .padding(.vertical, 6)

            Divider()

            ForEach(streams, id: \.name) { stream in
                HStack {
                    Text(stream.name)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                    Text(stream.amount.formattedCurrency())
                        .font(.footnote)
                        .frame(width: 100, alignment: .trailing)
                    Text(formattedPercent(for: stream.amount))
                        .font(.footnote)
                        .frame(width: 60, alignment: .trailing)
                }
                .padding(.vertical, 6)

                if stream.name != streams.last?.name {
                    Divider()
                }
            }
        }
    }

    private func formattedPercent(for value: Decimal) -> String {
        guard total > 0 else { return "—" }
        let ratio = (value as NSDecimalNumber).doubleValue / (total as NSDecimalNumber).doubleValue
        return ratio.formatted(.percent.precision(.fractionLength(0...1)))
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
                        .onChange(of: viewModel.formDate) { _, _ in
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
