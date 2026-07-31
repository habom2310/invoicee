internal import SwiftUI

/// Primary entry point for browsing, filtering, and syncing invoices.
struct InvoiceTabView: View {
    @EnvironmentObject private var categoryStore: InvoiceCategoryStore
    @EnvironmentObject private var archive: InvoiceArchive
    @EnvironmentObject private var driveConnector: GoogleDriveConnector
    @EnvironmentObject private var periodStore: ReportingPeriodStore
    @EnvironmentObject private var appEnvironment: AppEnvironment

    @StateObject private var export = CSVExportController()
    @State private var isPresentingCaptureSheet = false
    @State private var isRemoteSyncing = false
    @State private var remoteSyncError: String?
    @State private var hasAttemptedInitialSync = false
    @State private var searchText = ""
    @State private var selectedCategory: String?
    @State private var isShowingMonthPicker = false
    @State private var isShowingSearchSheet = false

    var body: some View {
        // Both derived once per pass and handed down. `filteredInvoices` filters and sorts
        // the whole archive and `periodOptions` walks every invoice date; as computed
        // properties they ran three and four times respectively on every body evaluation.
        let options = ReportingPeriodOptions(dates: archive.invoices.map(\.date))
        let invoices = filteredInvoices

        NavigationStack {
            Group {
                if archive.invoices.isEmpty {
                    emptyState
                } else {
                    invoiceList(invoices)
                }
            }
            .navigationTitle("Invoices")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        startCSVExport(invoices)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(invoices.isEmpty)
                    .accessibilityLabel("Export filtered invoices")
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isPresentingCaptureSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("Add Invoice")
                }
            }
            .sheet(isPresented: $isPresentingCaptureSheet) {
                InvoiceCaptureSheet(categoryStore: categoryStore,
                                    knownSuppliers: archive.invoices.map(\.supplier),
                                    isPresented: $isPresentingCaptureSheet) { invoice in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        archive.upsert(invoice)
                    }
                }
                .presentationDetents([.large])
                .interactiveDismissDisabled(true)
            }
        }
        .sheet(isPresented: $isShowingSearchSheet) { searchSheet }
        .sheet(isPresented: $isShowingMonthPicker) {
            MonthYearPickerSheet(month: monthBinding,
                                 year: yearBinding(options),
                                 months: options.availableMonths(for: periodStore.selectedYear),
                                 years: options.availableYears)
        }
        .csvExporter(export)
        .onAppear {
            clampPeriodSelection(options)
            guard !hasAttemptedInitialSync else { return }
            hasAttemptedInitialSync = true
            Task { await synchronizeWithRemoteIfPossible() }
        }
        .onChange(of: archive.invoices.count) { _, _ in
            clampPeriodSelection(ReportingPeriodOptions(dates: archive.invoices.map(\.date)))
        }
        .onChange(of: driveConnector.state) { _, newState in
            guard newState == .linked else { return }
            Task { await synchronizeWithRemoteIfPossible() }
        }
    }

    // MARK: - Content

    private var emptyState: some View {
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
    }

    private func invoiceList(_ invoices: [CapturedInvoice]) -> some View {
        ZStack(alignment: .bottomTrailing) {
            List {
                if let linkIssue = driveConnector.linkIssueMessage {
                    Section { linkIssueRow(linkIssue) }
                }

                WarningSection(remoteSyncError ?? export.errorMessage)

                filterSection

                Section("Invoices") {
                    if invoices.isEmpty {
                        Text("No invoices match your filters.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(invoices) { invoice in
                            NavigationLink {
                                InvoiceDetailView(invoice: binding(for: invoice),
                                                  onDelete: { archive.remove(id: $0.id) })
                            } label: {
                                CapturedInvoiceRow(invoice: invoice,
                                                   isSynced: archive.syncedInvoiceIDs.contains(invoice.id))
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)

            searchButton
        }
    }

    private func linkIssueRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.footnote)
                .multilineTextAlignment(.leading)

            switch driveConnector.state {
            case .signedOut:
                Button {
                    Task { await driveConnector.linkAccount() }
                } label: {
                    Label("Relink Google Drive", systemImage: "link")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
            case .failed:
                Button {
                    driveConnector.refreshLinkState()
                } label: {
                    Label("Retry Connection Check", systemImage: "arrow.clockwise")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
            case .linked, .authorizing:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }

    private var searchButton: some View {
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

    private var searchSheet: some View {
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
                    Button("Done") { isShowingSearchSheet = false }
                }
            }
        }
    }

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
                        filterChip(label: selectedCategory ?? "All Categories",
                                   systemImage: nil,
                                   trailingImage: "chevron.up.chevron.down")
                    }

                    Button {
                        isShowingMonthPicker = true
                    } label: {
                        filterChip(label: selectedPeriodLabel,
                                   systemImage: "calendar",
                                   trailingImage: nil)
                    }
                    .buttonStyle(.plain)
                }

                if filtersActive {
                    Button {
                        searchText = ""
                        selectedCategory = nil
                    } label: {
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

    private func filterChip(label: String, systemImage: String?, trailingImage: String?) -> some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(label)
                .lineLimit(1)
            if let trailingImage {
                Image(systemName: trailingImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Filtering and period selection

private extension InvoiceTabView {
    var filtersActive: Bool {
        !searchText.trimmed.isEmpty || selectedCategory != nil
    }

    var selectedPeriodLabel: String {
        "\(ReportingDateFormatter.shortName(for: periodStore.selectedMonth))-\(periodStore.selectedYear)"
    }

    /// Applies search text, category, and period filtering to the archive.
    var filteredInvoices: [CapturedInvoice] {
        let calendar = Calendar.current
        guard let range = calendar.reportingMonth(month: periodStore.selectedMonth,
                                                  year: periodStore.selectedYear) else {
            return []
        }
        let search = searchText.trimmed

        return archive.invoices
            .filter { invoice in
                guard calendar.isDay(invoice.date, in: range) else { return false }
                if let selectedCategory,
                   invoice.category?.matchesIgnoringCase(selectedCategory) != true {
                    return false
                }
                return search.isEmpty || invoice.supplier.range(of: search, options: .caseInsensitive) != nil
            }
            .sorted { $0.date > $1.date }
    }

    /// Two-way binding into the archive so edits made in the detail view are stored.
    func binding(for invoice: CapturedInvoice) -> Binding<CapturedInvoice> {
        Binding(get: { archive.invoice(with: invoice.id) ?? invoice },
                set: { archive.upsert($0) })
    }

    var monthBinding: Binding<Int> {
        Binding(get: { periodStore.selectedMonth },
                set: { periodStore.set(month: $0, year: periodStore.selectedYear) })
    }

    /// Changing the year may leave the month unselectable, so clamp as part of the set.
    func yearBinding(_ options: ReportingPeriodOptions) -> Binding<Int> {
        Binding(get: { periodStore.selectedYear },
                set: { year in
                    let clamped = options.clamped(month: periodStore.selectedMonth, year: year)
                    periodStore.set(month: clamped.month, year: clamped.year)
                })
    }

    func clampPeriodSelection(_ options: ReportingPeriodOptions) {
        let clamped = options.clamped(month: periodStore.selectedMonth, year: periodStore.selectedYear)
        periodStore.set(month: clamped.month, year: clamped.year)
    }
}

// MARK: - Export and remote sync

private extension InvoiceTabView {
    func startCSVExport(_ invoices: [CapturedInvoice]) {
        guard !invoices.isEmpty else { return }
        export.export(rows: CSVExporting.invoiceRows(from: invoices),
                      filename: "Invoices-\(ReportingDateFormatter.fileNameTimestamp(Date())).csv",
                      mirroringTo: driveConnector)
    }

    func synchronizeWithRemoteIfPossible() async {
        guard !isRemoteSyncing, driveConnector.state == .linked else { return }

        isRemoteSyncing = true
        remoteSyncError = nil
        defer { isRemoteSyncing = false }

        do {
            try await appEnvironment.remoteSynchronizer.synchronizeFromRemote()
        } catch {
            remoteSyncError = error.userFacingDescription
        }
    }
}
