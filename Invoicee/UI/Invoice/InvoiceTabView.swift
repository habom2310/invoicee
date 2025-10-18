import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Primary entry point for browsing, filtering, and syncing invoices.
struct InvoiceTabView: View {
    @EnvironmentObject private var categoryStore: InvoiceCategoryStore
    @EnvironmentObject private var archive: InvoiceArchive
    @EnvironmentObject private var driveConnector: GoogleDriveConnector
    @EnvironmentObject private var periodStore: ReportingPeriodStore
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @State private var isPresentingCaptureSheet = false
    @State private var invoices: [CapturedInvoice] = []
    @State private var isRemoteSyncing = false
    @State private var remoteSyncError: String? = nil
    @State private var hasAttemptedInitialSync = false

    @State private var searchText: String = ""
    @State private var selectedCategory: String? = nil
    @State private var isShowingMonthPicker = false
    @State private var isShowingSearchSheet = false
    @State private var isExportingCSV = false
    @State private var exportDocument = CSVDocument(text: "")

    var body: some View {
        NavigationStack {
            Group {
                if invoices.isEmpty {
                    VStack(spacing: 24) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 68))
                            .foregroundStyle(.blue)

                        Text("Capture your invoices or enter details manually to prepare them for processing.")
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.invoiceBackground)
                } else {
                    ZStack(alignment: .bottomTrailing) {
                        List {
                            if let linkIssue = driveConnector.linkIssueMessage {
                                Section {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Label(linkIssue, systemImage: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                            .font(.footnote)
                                            .multilineTextAlignment(.leading)

                                        if driveConnector.state == .signedOut {
                                            Button {
                                                Task { await driveConnector.linkAccount() }
                                            } label: {
                                                Label("Relink Google Drive", systemImage: "link")
                                                    .font(.footnote)
                                            }
                                            .buttonStyle(.borderless)
                                        } else if driveConnector.state == .failed {
                                            Button {
                                                driveConnector.refreshLinkState()
                                            } label: {
                                                Label("Retry Connection Check", systemImage: "arrow.clockwise")
                                                    .font(.footnote)
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }

                            if let remoteSyncError {
                                Section {
                                    Label(remoteSyncError, systemImage: "exclamationmark.triangle")
                                        .foregroundStyle(.orange)
                                        .font(.footnote)
                                }
                            }

                            filterSection

                            Section("Invoices") {
                                if filteredInvoices.isEmpty {
                                    Text("No invoices match your filters.")
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(filteredInvoices) { invoice in
                                        if let binding = binding(for: invoice) {
                                            NavigationLink {
                                                InvoiceDetailView(invoice: binding,
                                                                  onDelete: removeInvoice)
                                            } label: {
                                                CapturedInvoiceRow(invoice: invoice,
                                                                   isSynced: archive.syncedInvoiceIDs.contains(invoice.id))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)

                        Button {
                            isShowingSearchSheet.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                if searchText.isEmpty {
                                    Image(systemName: "magnifyingglass")
                                        .font(.headline)
                                } else {
                                    Text(searchText)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, searchText.isEmpty ? 14 : 16)
                            .padding(.vertical, 12)
                            .background(Color.blue.opacity(0.9))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                            .shadow(radius: 4)
                        }
                        .padding()
                        .accessibilityLabel("Search invoices")
                    }
                }
            }
            .navigationTitle("Invoices")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        startCSVExport()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(filteredInvoices.isEmpty)
                    .accessibilityLabel("Export filtered invoices")
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isPresentingCaptureSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Invoice")
                }
            }
            .sheet(isPresented: $isPresentingCaptureSheet) {
                InvoiceCaptureSheet(categoryStore: categoryStore,
                                    knownSuppliers: invoices.map { $0.supplier },
                                    isPresented: $isPresentingCaptureSheet) { invoice in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        invoices.insert(invoice, at: 0)
                    }
                }
                .presentationDetents([.large])
                .interactiveDismissDisabled(true)
            }
        }
            .sheet(isPresented: $isShowingSearchSheet) {
                NavigationStack {
                    Form {
                        Section("Supplier") {
                            TextField("Enter supplier name", text: $searchText)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    }
                }
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Clear") {
                            searchText = ""
                            isShowingSearchSheet = false
                        }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            isShowingSearchSheet = false
                        }
                    }
                }
                }
            }
            .sheet(isPresented: $isShowingMonthPicker) {
                let monthBinding = Binding<Int>(
                    get: { periodStore.selectedMonth },
                    set: { newValue in
                        periodStore.set(month: newValue, year: periodStore.selectedYear)
                        ensurePeriodSelectionIsValid()
                    }
                )

                let yearBinding = Binding<Int>(
                    get: { periodStore.selectedYear },
                    set: { newValue in
                        var targetMonth = periodStore.selectedMonth
                        let months = availableMonths(for: newValue)
                        if !months.isEmpty && !months.contains(targetMonth) {
                            if newValue == currentYear {
                                targetMonth = months.last ?? targetMonth
                            } else {
                                targetMonth = months.first ?? targetMonth
                            }
                        }
                        periodStore.set(month: targetMonth, year: newValue)
                        ensurePeriodSelectionIsValid()
                    }
                )

                NavigationStack {
                    VStack {
                        Text("Select Month")
                            .font(.headline)
                            .padding(.top)

                        HStack(spacing: 0) {
                            Picker("Month", selection: monthBinding) {
                                ForEach(availableMonths(for: yearBinding.wrappedValue), id: \.self) { month in
                                    Text(monthName(for: month)).tag(month)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                            .clipped()

                            Picker("Year", selection: yearBinding) {
                                ForEach(availableYears, id: \.self) { year in
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
        .fileExporter(isPresented: $isExportingCSV,
                          document: exportDocument,
                          contentType: .commaSeparatedText,
                          defaultFilename: csvFilename) { result in
                switch result {
                case .success:
                    remoteSyncError = nil
                case .failure(let error):
                    remoteSyncError = error.localizedDescription
                }
        }
        .onAppear {
            if !hasAttemptedInitialSync {
                hasAttemptedInitialSync = true
                invoices = archive.invoices
                ensurePeriodSelectionIsValid()
                Task { await synchronizeWithRemoteIfPossible() }
            } else {
                ensurePeriodSelectionIsValid()
            }
        }
        .onChange(of: invoices) { _, newValue in
            if archive.invoices != newValue {
                archive.update(with: newValue)
            }
        }
        .onReceive(archive.$invoices) { updated in
            if updated != invoices {
                invoices = updated
                ensurePeriodSelectionIsValid()
            }
        }
        .onChange(of: driveConnector.state) { _, newState in
            if newState == .linked {
                Task { await synchronizeWithRemoteIfPossible() }
            }
        }
    }
}

private let csvDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

/// Lightweight document wrapper for exporting filtered invoices as CSV.
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let string = String(data: data, encoding: .utf8) {
            text = string
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8) ?? Data()
        return .init(regularFileWithContents: data)
    }
}

extension InvoiceTabView {
    private var filtersActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty ||
        selectedCategory != nil
    }

    /// Applies search text, category, and period filtering to the archive.
    private var filteredInvoices: [CapturedInvoice] {
        invoices.filter { invoice in
            let matchesSearch: Bool
            let trimmedSearch = searchText.trimmingCharacters(in: .whitespaces)
            if trimmedSearch.isEmpty {
                matchesSearch = true
            } else {
                matchesSearch = invoice.supplier.range(of: trimmedSearch, options: .caseInsensitive) != nil
            }

            let matchesCategory: Bool
            if let selectedCategory {
                matchesCategory = invoice.category?.caseInsensitiveCompare(selectedCategory) == .orderedSame
            } else {
                matchesCategory = true
            }

            let invoiceComponents = Calendar.current.dateComponents([.year, .month], from: invoice.date)
            let matchesDate = invoiceComponents.year == periodStore.selectedYear &&
                              invoiceComponents.month == periodStore.selectedMonth

            return matchesSearch && matchesCategory && matchesDate
        }
        .sorted { $0.date > $1.date }
    }

    private func clearFilters() {
        searchText = ""
        selectedCategory = nil
    }

    private func binding(for invoice: CapturedInvoice) -> Binding<CapturedInvoice>? {
        guard let index = invoices.firstIndex(where: { $0.id == invoice.id }) else { return nil }
        return $invoices[index]
    }

    private func startCSVExport() {
        let invoicesToExport = filteredInvoices
        guard !invoicesToExport.isEmpty else { return }

        let csvContent = makeCSV(from: invoicesToExport)
        exportDocument = CSVDocument(text: csvContent)
        isExportingCSV = true

        let filename = csvFilename
        Task { await uploadCSVToDrive(content: csvContent, filename: filename) }
    }

    private var csvFilenameBase: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "Invoices-\(formatter.string(from: Date()))"
    }

    /// Default export filename combining filters and current date.
    private var csvFilename: String {
        "\(csvFilenameBase).csv"
    }

    private func makeCSV(from invoices: [CapturedInvoice]) -> String {
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
                csvDateFormatter.string(from: invoice.date),
                invoice.supplier,
                invoice.total.plainString,
                invoice.ourAmount.plainString,
                invoice.gst.plainString,
                invoice.category ?? ""
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

        return rows
            .map { row in row.map(csvEscape).joined(separator: ",") }
            .joined(separator: "\n")
    }

    private func csvEscape(_ value: String) -> String {
        let needsEscaping = value.contains(",") || value.contains("\n") || value.contains("\"")
        guard needsEscaping else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func uploadCSVToDrive(content: String, filename: String) async {
        let state = await MainActor.run { driveConnector.state }
        guard state == .linked else { return }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            try await driveConnector.transferService.uploadExport(fileURL: tempURL, fileName: filename)
            await MainActor.run { remoteSyncError = nil }
        } catch {
            await MainActor.run {
                remoteSyncError = error.localizedDescription
            }
        }
        try? FileManager.default.removeItem(at: tempURL)
    }

    private func removeInvoice(_ invoice: CapturedInvoice) {
        guard let index = invoices.firstIndex(where: { $0.id == invoice.id }) else { return }
        _ = withAnimation {
            invoices.remove(at: index)
        }
    }

    private func synchronizeWithRemoteIfPossible() async {
        guard !isRemoteSyncing else { return }
        guard driveConnector.state == .linked else { return }

        isRemoteSyncing = true
        remoteSyncError = nil
        do {
            let didChange = try await appEnvironment.remoteSynchronizer.synchronizeFromRemote()
            if didChange {
                let updated = archive.invoices
                if updated != invoices {
                    invoices = updated
                }
            }
        } catch {
            remoteSyncError = error.localizedDescription
        }
        isRemoteSyncing = false
    }

    /// Filters out invoices by search text, category, and period.
    private var filterSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Menu {
                        Button("All Categories") { selectedCategory = nil }
                        ForEach(categoryStore.categories, id: \.self) { category in
                            Button(category) { selectedCategory = category }
                        }
                    } label: {
                        HStack {
                            Text(selectedCategory ?? "All Categories")
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Button {
                        isShowingMonthPicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar")
                            Text(selectedPeriodLabel)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }

                if filtersActive {
                    Button(action: clearFilters) {
                        Text("Clear Filters")
                            .font(.caption)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filters")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedPeriodLabel: String {
        "\(shortMonthName(for: periodStore.selectedMonth))-\(periodStore.selectedYear)"
    }

    private var availableYears: [Int] {
        var years = Set(invoices.map { Calendar.current.component(.year, from: $0.date) })
        years.insert(currentYear)
        return years.filter { $0 <= currentYear }.sorted()
    }

    private var availableMonths: [Int] {
        availableMonths(for: periodStore.selectedYear)
    }

    private func availableMonths(for year: Int) -> [Int] {
        let calendar = Calendar.current
        var months = Set(invoices
            .filter { calendar.component(.year, from: $0.date) == year }
            .map { calendar.component(.month, from: $0.date) })

        if year == currentYear {
            months.formUnion(1...currentMonth)
        } else if year < currentYear {
            months.formUnion(1...12)
        }

        if months.isEmpty {
            if year == currentYear {
                months.formUnion(1...currentMonth)
            } else {
                months.formUnion(1...12)
            }
        }

        return months.sorted()
    }

    private func monthName(for month: Int) -> String {
        guard month >= 1 && month <= Self.monthSymbols.count else { return "Month" }
        return Self.monthSymbols[month - 1]
    }

    private func shortMonthName(for month: Int) -> String {
        guard month >= 1 && month <= Self.shortMonthSymbols.count else { return "Mon" }
        return Self.shortMonthSymbols[month - 1]
    }

    private func ensurePeriodSelectionIsValid() {
        let years = availableYears
        var targetYear = periodStore.selectedYear
        if !years.contains(targetYear), let replacement = years.last {
            targetYear = replacement
        }

        let months = availableMonths(for: targetYear)
        guard !months.isEmpty else { return }

        var targetMonth = periodStore.selectedMonth
        if !months.contains(targetMonth) {
            if targetYear == currentYear {
                targetMonth = months.last ?? targetMonth
            } else {
                targetMonth = months.first ?? targetMonth
            }
        }

        periodStore.set(month: targetMonth, year: targetYear)
    }

    private var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    private var currentMonth: Int {
        Calendar.current.component(.month, from: Date())
    }

    private static let monthSymbols: [String] = {
        let formatter = DateFormatter()
        return formatter.monthSymbols ?? []
    }()

    private static let shortMonthSymbols: [String] = {
        let formatter = DateFormatter()
        return formatter.shortMonthSymbols ?? []
    }()
}
