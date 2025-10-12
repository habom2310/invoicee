import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct InvoiceTabView: View {
    @ObservedObject private var categoryStore = InvoiceCategoryStore.shared
    @ObservedObject private var archive = InvoiceArchive.shared
    @ObservedObject private var driveConnector = GoogleDriveConnector.shared
    @State private var isPresentingCaptureSheet = false
    @State private var invoices: [CapturedInvoice] = []
    @State private var isRemoteSyncing = false
    @State private var remoteSyncError: String? = nil
    @State private var hasAttemptedInitialSync = false

    @State private var searchText: String = ""
    @State private var selectedCategory: String? = nil
    @State private var selectedDateComponents: Set<DateComponents> = []
    @State private var isShowingDatePicker = false
    @State private var isShowingSearchSheet = false
    @State private var previousRange: [Date]? = nil
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
                                                                  categoryStore: categoryStore,
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
                Task { await synchronizeWithRemoteIfPossible() }
            }
        }
        .onChange(of: invoices) { _, newValue in
            if archive.invoices != newValue {
                InvoiceArchive.shared.update(with: newValue)
            }
        }
        .onReceive(archive.$invoices) { updated in
            if updated != invoices {
                invoices = updated
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
        selectedCategory != nil ||
        !selectedDates.isEmpty
    }

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

            let matchesDate: Bool
            if selectedDates.isEmpty {
                matchesDate = true
            } else if selectedDates.count == 1 {
                matchesDate = Calendar.current.isDate(invoice.date, inSameDayAs: selectedDates[0])
            } else if let range = normalizedDateRange() {
                matchesDate = invoice.date >= range.lowerBound && invoice.date <= range.upperBound
            } else {
                matchesDate = true
            }

            return matchesSearch && matchesCategory && matchesDate
        }
        .sorted { $0.date > $1.date }
    }

    private func normalizedDateRange() -> ClosedRange<Date>? {
        let sortedDates = selectedDates.sorted()
        guard sortedDates.count >= 2 else { return nil }
        return sortedDates.first!...sortedDates.last!
    }

    private func clearFilters() {
        searchText = ""
        selectedCategory = nil
        selectedDateComponents = []
        isShowingDatePicker = false
        previousRange = nil
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
            let didChange = try await InvoiceRemoteSynchronizer.shared.synchronizeFromRemote()
            if didChange {
                let updated = InvoiceArchive.shared.invoices
                if updated != invoices {
                    invoices = updated
                }
            }
        } catch {
            remoteSyncError = error.localizedDescription
        }
        isRemoteSyncing = false
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
                        isShowingDatePicker.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar")
                            Text(dateFilterLabel)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                if isShowingDatePicker {
                    VStack(alignment: .leading, spacing: 8) {
                        MultiDatePicker("Select dates", selection: $selectedDateComponents)
                            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                            .onChange(of: selectedDateComponents) { _, newValue in
                                enforceDateSelectionLimit(newValue)
                            }
                    }
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

    private var dateFilterLabel: String {
        if selectedDates.isEmpty {
            return "Any Date"
        } else if selectedDates.count == 1 {
            return selectedDates[0].formattedInvoiceDate()
        } else if let range = normalizedDateRange() {
            return "\(range.lowerBound.formattedInvoiceDate()) – \(range.upperBound.formattedInvoiceDate())"
        }

        return "Any Date"
    }

    private var selectedDates: [Date] {
        let calendar = Calendar.current
        return selectedDateComponents.compactMap { calendar.date(from: $0) }
            .map { calendar.startOfDay(for: $0) }
            .sorted()
    }

    private func enforceDateSelectionLimit(_ newValue: Set<DateComponents>) {
        let calendar = Calendar.current
        let sorted = newValue.compactMap { calendar.date(from: $0) }
            .map { calendar.startOfDay(for: $0) }
            .sorted()

        guard let first = sorted.first else {
            selectedDateComponents.removeAll()
            previousRange = nil
            return
        }

        let newSet = Set(sorted)

        if let previousSelection = previousRange {
            let previousSet = Set(previousSelection.map { calendar.startOfDay(for: $0) })
            if newSet == previousSet {
                return
            }
        }

        switch sorted.count {
        case 1:
            selectedDateComponents = [calendar.dateComponents([.year, .month, .day], from: first)]
            previousRange = nil
        case 2:
            if let last = sorted.last {
                updateSelectionForRange(start: first, end: last)
            }
        default:
            if let last = sorted.last {
                selectedDateComponents = [calendar.dateComponents([.year, .month, .day], from: last)]
            }
            previousRange = nil
        }
    }

    private func updateSelectionForRange(start: Date, end: Date) {
        let calendar = Calendar.current
        let rangeDates = datesBetween(start, end)
        previousRange = rangeDates
        let components = rangeDates.map { calendar.dateComponents([.year, .month, .day], from: $0) }
        selectedDateComponents = Set(components)
    }

    private func datesBetween(_ start: Date, _ end: Date) -> [Date] {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        guard startDay <= endDay else { return [] }

        var dates: [Date] = []
        var current = startDay
        while current <= endDay {
            dates.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return dates
    }
}

struct CapturedInvoiceRow: View {
    var invoice: CapturedInvoice
    var isSynced: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSynced ? "cloud.fill" : "cloud.slash")
                .foregroundStyle(isSynced ? .blue : .secondary)
                .font(.title2)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(invoice.supplier.isEmpty ? "Unnamed Supplier" : invoice.supplier)
                    .font(.headline)

                HStack(spacing: 8) {
                    Image(systemName: invoice.method.iconName)
                        .foregroundStyle(.secondary)
                    Text(invoice.method.title)
                    Text(invoice.formattedDate)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(invoice.displayTotal)
                    .font(.headline)

                if let category = invoice.category, !category.isEmpty {
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if invoice.gst > 0 {
                    Text("GST " + invoice.displayGST)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct InvoiceDetailView: View {
    @Binding var invoice: CapturedInvoice
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var categoryStore: InvoiceCategoryStore
    let onDelete: (CapturedInvoice) -> Void
    @ObservedObject private var driveConnector = GoogleDriveConnector.shared
    @State private var draft: CapturedInvoice
    @State private var newCategoryName: String = ""
    @State private var itemsExpanded: Bool = false
    @State private var isDownloadingImage = false
    @State private var downloadErrorMessage: String? = nil
    @State private var isShowingDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String? = nil

    init(invoice: Binding<CapturedInvoice>,
         categoryStore: InvoiceCategoryStore = .shared,
         onDelete: @escaping (CapturedInvoice) -> Void = { _ in }) {
        _invoice = invoice
        _categoryStore = ObservedObject(wrappedValue: categoryStore)
        _draft = State(initialValue: invoice.wrappedValue)
        self.onDelete = onDelete
    }

    private var draftItemsBinding: Binding<[ManualInvoiceItem]> {
        Binding(
            get: { draft.items },
            set: { draft.items = $0 }
        )
    }

    var body: some View {
        Form {
            Section("Invoice Info") {
                VStack(alignment: .leading, spacing: 16) {
                    InvoiceFieldLabel("Supplier")
                    TextField("Supplier", text: $draft.supplier)
                        .invoiceInputStyle()

                    InvoiceFieldLabel("Total Amount")
                    InvoiceCurrencyField("Total amount", text: totalAmountBinding)

                    InvoiceFieldLabel("Our Amount")
                    InvoiceCurrencyField("Our amount", text: ourAmountBinding)

                    InvoiceFieldLabel("GST Amount")
                    InvoiceCurrencyField("GST amount", text: gstAmountBinding)

                    InvoiceFieldLabel("Category")
                    Menu {
                        Button("None") { draft.category = nil }
                        ForEach(categoryStore.categories, id: \.self) { category in
                            Button(category) { draft.category = category }
                        }
                    } label: {
                        HStack {
                            Text(draft.category ?? "Select category")
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    HStack {
                        TextField("Add new category", text: $newCategoryName)
                            .textInputAutocapitalization(.words)
                        Button("Add") {
                            addCategory()
                        }
                        .disabled(!canAddNewCategory)
                    }

                    InvoiceFieldLabel("Date")
                    DatePicker("", selection: $draft.date, displayedComponents: .date)
                        .labelsHidden()

                    InvoiceFieldLabel("Capture Method")
                    HStack(spacing: 8) {
                        Image(systemName: draft.method.iconName)
                            .foregroundStyle(.secondary)
                        Text(draft.method.title)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

#if canImport(UIKit)
                    if let imageData = draft.imageData, let uiImage = UIImage(data: imageData) {
                        capturedImagePreview(Image(uiImage: uiImage))
                    }
#elseif canImport(AppKit)
                    if let imageData = draft.imageData, let nsImage = NSImage(data: imageData) {
                        capturedImagePreview(Image(nsImage: nsImage))
                    }
#endif

                    if draft.imageData == nil,
                       draft.method == .camera,
                       let remoteFileName = draft.remoteImageFileName {
                        VStack(alignment: .leading, spacing: 8) {
                            InvoiceFieldLabel("Captured Image")
                            Button {
                                downloadRemoteImage(named: remoteFileName)
                            } label: {
                                if isDownloadingImage {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Label("Download from Google Drive", systemImage: "arrow.down.circle")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isDownloadingImage || driveConnector.state != .linked || isDeleting)

                            if driveConnector.state != .linked && !isDownloadingImage {
                                Text("Link Google Drive to download the original image.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            if let downloadErrorMessage {
                                Text(downloadErrorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }

                    if let deleteErrorMessage {
                        Text(deleteErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                DisclosureGroup(isExpanded: $itemsExpanded) {
                    if draft.items.isEmpty {
                        Text("No items recorded.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(draftItemsBinding) { $item in
                        InvoiceItemFields(item: $item) {
                            removeItem(withID: item.id)
                        }
                    }

                    Button {
                        addItem()
                    } label: {
                        Label("Add Item", systemImage: "plus.circle")
                    }
                } label: {
                    HStack {
                        Text("Items [\(draft.items.count)]")
                            .font(.headline)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle(draft.supplier.isEmpty ? "Invoice Details" : draft.supplier)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(role: .destructive) {
                    isShowingDeleteConfirmation = true
                } label: {
                    if isDeleting {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Text("Delete")
                    }
                }
                .disabled(isDeleting)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveChanges()
                }
                .bold()
                .disabled(isDeleting)
            }
        }
        .onAppear {
            draft = invoice
            itemsExpanded = false
            downloadErrorMessage = nil
            isDownloadingImage = false
            deleteErrorMessage = nil
        }
        .confirmationDialog("Delete Invoice?", isPresented: $isShowingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                isShowingDeleteConfirmation = false
                Task { await deleteInvoice() }
            }
            Button("Cancel", role: .cancel) {
                isShowingDeleteConfirmation = false
            }
        } message: {
            Text("This will remove the invoice from Invoicee and synced services.")
        }
    }

    private func capturedImagePreview(_ image: Image) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            InvoiceFieldLabel("Captured Image")
            image
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func addItem() {
        var updatedItems = draftItemsBinding.wrappedValue
        updatedItems.append(ManualInvoiceItem())
        draftItemsBinding.wrappedValue = updatedItems
    }

    private func removeItem(withID id: ManualInvoiceItem.ID) {
        var updatedItems = draftItemsBinding.wrappedValue
        updatedItems.removeAll { $0.id == id }
        draftItemsBinding.wrappedValue = updatedItems
    }

    private func saveChanges() {
        guard !isDeleting else { return }
        draft.lastEdited = Date()
        categoryStore.rememberCategory(draft.category, for: draft.supplier)
        invoice = draft
        dismiss()
    }

    private func downloadRemoteImage(named fileName: String) {
        guard !isDownloadingImage else { return }
        guard !isDeleting else { return }
        guard driveConnector.state == .linked else {
            downloadErrorMessage = "Google Drive is not linked."
            return
        }

        isDownloadingImage = true
        downloadErrorMessage = nil

        Task {
            do {
                let data = try await driveConnector.transferService.downloadInvoiceImage(fileName: fileName, invoiceDate: draft.date)
                await MainActor.run {
                    draft.imageData = data
                    draft.remoteImageFileName = fileName
                    invoice.imageData = data
                    invoice.remoteImageFileName = fileName
                    isDownloadingImage = false
                }
            } catch {
                await MainActor.run {
                    downloadErrorMessage = error.localizedDescription
                    isDownloadingImage = false
                }
            }
        }
    }

    private func deleteInvoice() async {
        await MainActor.run {
            isDeleting = true
            deleteErrorMessage = nil
        }

        let invoiceToDelete = await MainActor.run { invoice }
        var remoteFileName = await MainActor.run { invoice.remoteImageFileName }
        let invoiceDate = invoiceToDelete.date
        let tracker = InvoiceSyncTracker.shared
        if remoteFileName == nil {
            if let path = await tracker.record(for: invoiceToDelete.id)?.imagePath {
                remoteFileName = path.split(separator: "/").last.map(String.init)
            }
        }

        do {
            let driveState = await MainActor.run { driveConnector.state }

            if let remoteFileName, !remoteFileName.isEmpty, driveState != .linked {
                throw InvoiceDeletionError.driveNotLinked
            }

            if let remoteFileName, !remoteFileName.isEmpty, driveState == .linked {
                try await driveConnector.transferService.deleteInvoiceImage(fileName: remoteFileName, invoiceDate: invoiceDate)
            }

            try await InvoiceFirestoreUploader.shared.delete(invoiceID: invoiceToDelete.id)
            await tracker.removeRecord(for: invoiceToDelete.id)

            await MainActor.run {
                onDelete(invoiceToDelete)
                dismiss()
            }
        } catch {
            await MainActor.run {
                deleteErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        await MainActor.run {
            isDeleting = false
        }
    }

    private enum InvoiceDeletionError: LocalizedError {
        case driveNotLinked

        var errorDescription: String? {
            switch self {
            case .driveNotLinked:
                return "Link Google Drive before deleting a synced invoice."
            }
        }
    }

    private var canAddNewCategory: Bool {
        let trimmed = newCategoryName.trimmed
        guard !trimmed.isEmpty else { return false }
        return !categoryStore.categories.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private func addCategory() {
        let trimmed = newCategoryName.trimmed
        guard !trimmed.isEmpty else { return }
        categoryStore.addCategory(trimmed)
        draft.category = trimmed
        newCategoryName = ""
    }

    private var totalAmountBinding: Binding<String> {
        Binding(
            get: { draft.total.plainString },
            set: { newValue in
                let filtered = newValue.filteredNumeric(allowDecimal: true)
                let previousTotal = draft.total
                draft.total = Decimal(string: filtered) ?? 0
                if draft.ourAmount == previousTotal {
                    draft.ourAmount = draft.total
                }
                let sanitizedGST = GSTValidator.sanitizedAmount(for: draft.gst, total: draft.total)
                draft.gst = sanitizedGST ?? 0
            }
        )
    }

    private var gstAmountBinding: Binding<String> {
        Binding(
            get: { draft.gst.plainString },
            set: { newValue in
                let filtered = newValue.filteredNumeric(allowDecimal: true)
                guard !filtered.isEmpty else {
                    draft.gst = 0
                    return
                }

                if let decimal = Decimal(string: filtered) {
                    draft.gst = GSTValidator.sanitizedAmount(for: decimal, total: draft.total) ?? 0
                } else {
                    draft.gst = 0
                }
            }
        )
    }

    private var ourAmountBinding: Binding<String> {
        Binding(
            get: { draft.ourAmount.plainString },
            set: { newValue in
                let filtered = newValue.filteredNumeric(allowDecimal: true)
                if filtered.isEmpty {
                    draft.ourAmount = draft.total
                } else {
                    draft.ourAmount = Decimal(string: filtered) ?? draft.total
                }
            }
        )
    }
}
