internal import SwiftUI

/// Displays revenue summaries and daily entries with editing support.
struct RevenueTabView: View {
    @EnvironmentObject private var driveConnector: GoogleDriveConnector
    @StateObject private var viewModel: RevenueViewModel
    @StateObject private var export = CSVExportController()

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
            ReportingPeriodSelector(selection: $viewModel.selection)
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
    }

    private var entriesSection: some View {
        Section(viewModel.selection.period == .year ? "Monthly Revenue" : "Daily Revenue") {
            if viewModel.listEntries.isEmpty {
                Label("No revenue recorded for this period.", systemImage: "chart.line.uptrend.xyaxis")
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

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Total Revenue")
                            .font(.headline)
                        // Only worth saying when there is a figure beside it to compare.
                        if viewModel.periodComparison != nil {
                            Text(viewModel.selection.comparisonLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(viewModel.summaryTotalFormatted)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if let comparison = viewModel.periodComparison {
                            PeriodComparisonBadge(comparison: comparison)
                        }
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
                      filename: "revenue_\(viewModel.selection.exportIdentifier).csv",
                      mirroringTo: driveConnector)
    }

    private func makeRevenueRows(from entries: [RevenueDayEntry]) -> [[String]] {
        let isYearly = viewModel.selection.period == .year
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

/// `($1,000.00 ↑ 20%)` - what the period before this one earned over the same span,
/// and which way the total has moved since.
private struct PeriodComparisonBadge: View {
    let comparison: RevenuePeriodComparison

    var body: some View {
        label
            .font(.caption)
            // Wrapping beats truncating: at accessibility text sizes a single line
            // clips the arrow and the percentage, which is the whole point of the badge.
            .lineLimit(2)
            // Enough headroom for the amount to stay whole on its own line rather than
            // breaking mid-number, which the widest text sizes would otherwise force.
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel(accessibilityDescription)
    }

    /// Built by concatenation rather than an `HStack` so the arrow sits on the text
    /// baseline and scales with the caption like any other glyph.
    private var label: Text {
        var text = Text(verbatim: "(\(comparison.previousTotal.formattedCurrency()) ")
            .foregroundStyle(.secondary)
        text = text + Text(Image(systemName: symbolName)).foregroundStyle(tint)
        if let percentText {
            text = text + Text(verbatim: " \(percentText)").foregroundStyle(tint)
        }
        return text + Text(verbatim: ")").foregroundStyle(.secondary)
    }

    private var symbolName: String {
        switch comparison.direction {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .unchanged: "equal"
        }
    }

    private var tint: Color {
        switch comparison.direction {
        case .up: .green
        case .down: .red
        case .unchanged: .secondary
        }
    }

    /// The arrow already carries the sign, so the percentage is shown unsigned.
    private var percentText: String? {
        guard let change = comparison.percentChange else { return nil }
        return ExpenseAnalyticsViewModel.percentText(abs(change))
    }

    private var accessibilityDescription: String {
        let prefix = "Compared with \(comparison.previousTotal.formattedCurrency())"
            + " for \(comparison.previousRange.description)"
        switch comparison.direction {
        case .unchanged:
            return "\(prefix), unchanged."
        case .up, .down:
            let word = comparison.direction == .up ? "up" : "down"
            guard let percentText else { return "\(prefix), \(word)." }
            return "\(prefix), \(word) \(percentText)."
        }
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
