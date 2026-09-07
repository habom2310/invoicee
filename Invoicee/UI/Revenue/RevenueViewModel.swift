import Foundation
import Combine
// For `RangeReplaceableCollection.remove(atOffsets:)`, which SwiftUI defines and
// `removeStreams(at:)` needs to service the form's `.onDelete`. The project builds with
// `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`, so a member is only visible when its
// defining module is imported *in this file*.
internal import SwiftUI

/// Business logic for loading, summarising, and editing revenue entries.
///
/// The summary, the stream breakdown, and the list rows are published rather than
/// computed on demand: each one filters and re-groups every entry, and the views read
/// them several times per `body` pass (toolbar state, empty check, then the rows).
@MainActor
final class RevenueViewModel: ObservableObject {
    struct EditableRevenueStream: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var amountText: String
    }

    @Published private(set) var entries: [RevenueDayEntry] = []
    @Published private(set) var knownStreams: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var canRecordRevenue = false

    /// Rows for the current selection — days, or months when viewing a year.
    @Published private(set) var listEntries: [RevenueDayEntry] = []
    @Published private(set) var streamTotalsForSelection: [RevenueStreamValue] = []
    @Published private(set) var summaryTotal: Decimal = .zero

    @Published var selectedPeriod: ReportingPeriod = .week {
        didSet {
            guard selectedPeriod != oldValue else { return }
            recomputeSelection()
        }
    }

    @Published var selectedMonth: Int {
        didSet {
            let clamped = min(max(selectedMonth, 1), 12)
            guard clamped == selectedMonth else {
                selectedMonth = clamped
                return
            }
            guard selectedMonth != oldValue else { return }
            recomputeSelection()
        }
    }

    @Published var selectedYear: Int {
        didSet {
            guard selectedYear != oldValue else { return }
            recomputeSelection()
        }
    }

    // Form state
    @Published var formDate: Date
    @Published var formStreams: [EditableRevenueStream] = []
    @Published var formErrorMessage: String?
    @Published var isPresentingForm = false
    @Published var isSavingForm = false

    private let store: RevenueStoring
    private let driveConnector: GoogleDriveConnector
    private let summaryProvider: RevenueSummaryProviding?
    private let calendar: Calendar
    private var cancellables = Set<AnyCancellable>()
    /// Rebuilt in `applyEntries` rather than derived in `availableYears`, because the
    /// year menu reads that property from `body` on every pass.
    private var periodOptions: ReportingPeriodOptions

    init(store: RevenueStoring,
         driveConnector: GoogleDriveConnector,
         summaryProvider: RevenueSummaryProviding? = nil,
         calendar: Calendar = .current) {
        self.store = store
        self.driveConnector = driveConnector
        self.summaryProvider = summaryProvider
        self.calendar = calendar
        periodOptions = ReportingPeriodOptions(dates: [], calendar: calendar)

        let today = calendar.startOfDay(for: Date())
        selectedMonth = calendar.component(.month, from: today)
        selectedYear = calendar.component(.year, from: today)
        formDate = today

        canRecordRevenue = driveConnector.authorizationState() == .linked
        observeDriveState()
        // The view's `.task` performs the first load; the observer covers later links.
    }

    var isEditingExistingForm: Bool {
        entry(for: formDate) != nil
    }

    // MARK: - Loading

    func refresh() async {
        guard !isLoading else { return }
        guard let identity = driveConnector.currentSyncIdentity else {
            applyEntries([])
            errorMessage = Self.linkPromptMessage
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            applyEntries(try await store.fetchEntries(for: identity))
        } catch {
            errorMessage = error.userFacingDescription
            applyEntries([])
        }
    }

    // MARK: - Summary

    /// The range the current selection covers.
    var selectedDateRange: ReportingDateRange? {
        calendar.range(for: selectedPeriod, month: selectedMonth, year: selectedYear)
    }

    var currentWeekRange: ReportingDateRange? {
        calendar.reportingWeek(containing: Date())
    }

    var summaryTitle: String {
        switch selectedPeriod {
        case .week:
            "This Week"
        case .month:
            isViewingCurrentMonth
                ? "This Month"
                : "\(ReportingDateFormatter.name(for: selectedMonth)) \(selectedYear)"
        case .year:
            "\(selectedYear)"
        }
    }

    var summarySubtitle: String {
        switch selectedPeriod {
        case .week: currentWeekRange?.description ?? ""
        case .month: isViewingCurrentMonth ? ReportingDateFormatter.name(for: selectedMonth) : "Custom Month"
        case .year: "Calendar Year"
        }
    }

    var summaryTotalFormatted: String {
        summaryTotal.formattedCurrency()
    }

    /// GST the period's revenue attracts. See `GSTRate` for the exclusive/inclusive
    /// distinction — revenue is recorded here as a GST-exclusive figure.
    var summaryGST: Decimal {
        GSTRate.exclusiveGST(on: summaryTotal)
    }

    var summaryGSTFormatted: String {
        summaryGST.formattedCurrency()
    }

    var availableYears: [Int] {
        periodOptions.availableYears(including: selectedYear)
    }

    // MARK: - Form

    func beginAddingRevenue(for date: Date? = nil) {
        let target = calendar.startOfDay(for: date ?? Date())
        formDate = target
        formStreams = streamsForNewEntry(on: target)
        formErrorMessage = nil
        isPresentingForm = true
    }

    func handleFormDateChange() {
        let normalized = calendar.startOfDay(for: formDate)
        if formDate != normalized {
            formDate = normalized
        }
        formStreams = streamsForNewEntry(on: normalized)
    }

    func addStream(named name: String? = nil) {
        formStreams.append(EditableRevenueStream(name: name ?? "", amountText: ""))
    }

    func removeStreams(at offsets: IndexSet) {
        formStreams.remove(atOffsets: offsets)
        if formStreams.isEmpty {
            formStreams = [EditableRevenueStream(name: "", amountText: "")]
        }
    }

    func saveCurrentForm() async {
        guard !isSavingForm else { return }
        guard let identity = driveConnector.currentSyncIdentity else {
            formErrorMessage = "Link Google Drive to record revenue."
            return
        }

        let sanitizedStreams = sanitizeFormStreams()
        guard !sanitizedStreams.isEmpty else {
            formErrorMessage = "Add at least one stream with a valid amount."
            return
        }

        isSavingForm = true
        formErrorMessage = nil
        defer { isSavingForm = false }

        do {
            let saved = try await store.save(date: formDate,
                                             streams: sanitizedStreams,
                                             documentID: entry(for: formDate)?.documentID,
                                             identity: identity)
            upsertEntry(saved)
            // Expense/profit screens read revenue through the cached provider.
            summaryProvider?.invalidateCache()
            isPresentingForm = false
        } catch {
            formErrorMessage = error.userFacingDescription
        }
    }

    // MARK: - Row display

    func formattedStreams(for entry: RevenueDayEntry) -> [String] {
        entry.streams.map { "\($0.name): \($0.amount.formattedCurrency())" }
    }

    func displayTitle(for entry: RevenueDayEntry) -> String {
        guard selectedPeriod == .year else { return ReportingDateFormatter.mediumDate(entry.date) }
        return ReportingDateFormatter.monthAndYear(entry.date)
    }

    /// Whether tapping a row can open the editor. Yearly rows are rollups of many days,
    /// so there is no single entry to edit.
    var rowsAreEditable: Bool {
        selectedPeriod != .year
    }

    // MARK: - Private helpers

    private static let linkPromptMessage = "Link Google Drive to start tracking revenue."

    private func observeDriveState() {
        driveConnector.$state
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                let linked = state == .linked
                guard linked != canRecordRevenue else { return }
                canRecordRevenue = linked

                if linked {
                    Task { await self.refresh() }
                } else {
                    applyEntries([])
                    errorMessage = Self.linkPromptMessage
                }
            }
            .store(in: &cancellables)
    }

    /// Normalises incoming entries to whole days, sorts them newest first, and refreshes
    /// everything derived from them.
    private func applyEntries(_ incoming: [RevenueDayEntry]) {
        entries = incoming
            .map { RevenueDayEntry(documentID: $0.documentID,
                                   date: calendar.startOfDay(for: $0.date),
                                   streams: $0.streams) }
            .sorted { $0.date > $1.date }
        knownStreams = Self.distinctStreams(from: entries)
        periodOptions = ReportingPeriodOptions(dates: entries.map(\.date), calendar: calendar)
        recomputeSelection()
    }

    private func recomputeSelection() {
        guard !entries.isEmpty, let range = selectedDateRange else {
            listEntries = []
            streamTotalsForSelection = []
            summaryTotal = .zero
            return
        }

        let inRange = entries.filter { calendar.isDay($0.date, in: range) }
        summaryTotal = inRange.reduce(.zero) { $0 + $1.total }
        streamTotalsForSelection = Self.streamTotals(in: inRange)
        listEntries = selectedPeriod == .year ? monthlyRollups(of: inRange) : inRange
    }

    private func entry(for date: Date) -> RevenueDayEntry? {
        entries.first { calendar.isDate($0.date, inSameDayAs: date) }
    }

    private var isViewingCurrentMonth: Bool {
        let today = calendar.dateComponents([.year, .month], from: Date())
        return today.month == selectedMonth && today.year == selectedYear
    }

    /// Pre-fills the form: the day's existing streams, else the known stream names.
    private func streamsForNewEntry(on date: Date) -> [EditableRevenueStream] {
        if let existing = entry(for: date) {
            return existing.streams.map {
                EditableRevenueStream(name: $0.name,
                                      amountText: $0.amount.formattedCurrency(omitSymbol: true))
            }
        }

        guard !knownStreams.isEmpty else {
            return [EditableRevenueStream(name: "", amountText: "")]
        }
        return knownStreams.map { EditableRevenueStream(name: $0, amountText: "") }
    }

    private func sanitizeFormStreams() -> [RevenueStreamValue] {
        formStreams.compactMap { stream in
            guard let name = stream.name.trimmed.nilIfEmpty,
                  let amount = Self.decimalValue(from: stream.amountText) else { return nil }
            return RevenueStreamValue(name: name, amount: amount)
        }
    }

    /// Parses using the user's locale first, then a fixed locale, so both "1,5" and
    /// "1.5" are accepted regardless of where the keyboard's decimal key came from.
    private static func decimalValue(from text: String) -> Decimal? {
        guard let trimmed = text.trimmed.nilIfEmpty else { return nil }
        return Decimal(string: trimmed, locale: .current)
            ?? Decimal(string: trimmed)
    }

    private func upsertEntry(_ entry: RevenueDayEntry) {
        let normalizedDate = calendar.startOfDay(for: entry.date)
        var updated = entries.filter { !calendar.isDate($0.date, inSameDayAs: normalizedDate) }
        updated.append(RevenueDayEntry(documentID: entry.documentID,
                                       date: normalizedDate,
                                       streams: entry.streams))
        applyEntries(updated)
    }

    /// Collapses daily entries into one row per month.
    private func monthlyRollups(of entries: [RevenueDayEntry]) -> [RevenueDayEntry] {
        Dictionary(grouping: entries) { calendar.component(.month, from: $0.date) }
            .compactMap { month, monthEntries -> RevenueDayEntry? in
                let year = calendar.component(.year, from: monthEntries[0].date)
                guard let displayDate = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
                    return nil
                }
                return RevenueDayEntry(documentID: "\(year)-\(month)",
                                       date: displayDate,
                                       streams: Self.streamTotals(in: monthEntries))
            }
            .sorted { $0.date > $1.date }
    }

    /// Totals each named stream across `entries`, largest first.
    private static func streamTotals(in entries: [RevenueDayEntry]) -> [RevenueStreamValue] {
        var totals: [String: Decimal] = [:]
        for entry in entries {
            for stream in entry.streams {
                totals[stream.name, default: .zero] += stream.amount
            }
        }
        return totals
            .map { RevenueStreamValue(name: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }
    }

    /// Stream names in first-seen order, de-duplicated.
    private static func distinctStreams(from entries: [RevenueDayEntry]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for entry in entries {
            for stream in entry.streams where seen.insert(stream.name).inserted {
                ordered.append(stream.name)
            }
        }
        return ordered
    }
}
