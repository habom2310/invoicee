import Foundation
import Combine
internal import SwiftUI

/// Business logic for loading, summarising, and editing revenue entries.
@MainActor
final class RevenueViewModel: ObservableObject {
    enum SummaryFilter: String, CaseIterable, Identifiable {
        case week
        case thisMonth
        case selectedMonth
        case year

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .week: return "Week"
            case .thisMonth: return "This Month"
            case .selectedMonth: return "Selected Month"
            case .year: return "Year"
            }
        }
    }

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

    @Published var selectedFilter: SummaryFilter = .week
    @Published var selectedMonth: Int
    @Published var selectedYear: Int

    // Form state
    @Published var formDate: Date = Date()
    @Published var formStreams: [EditableRevenueStream] = []
    @Published var formErrorMessage: String?
    @Published var isPresentingForm = false
    @Published var isSavingForm = false

    private let store: RevenueStoring
    private let driveConnector: GoogleDriveConnector
    private let calendar: Calendar
    private var cancellables = Set<AnyCancellable>()

    init(store: RevenueStoring,
         driveConnector: GoogleDriveConnector,
         calendar: Calendar = .current) {
        self.store = store
        self.driveConnector = driveConnector
        self.calendar = calendar
        let today = calendar.startOfDay(for: Date())
        selectedMonth = calendar.component(.month, from: today)
        selectedYear = calendar.component(.year, from: today)
        formDate = today

        canRecordRevenue = driveConnector.authorizationState() == .linked
        observeDriveState()

        if canRecordRevenue {
            Task { await refresh() }
        }
    }

    var isEditingExistingForm: Bool {
        entry(for: formDate) != nil
    }

    // MARK: - Loading

    func refresh() async {
        guard let userID = driveConnector.currentAccountID else {
            entries = []
            knownStreams = []
            errorMessage = "Link Google Drive to start tracking revenue."
            return
        }

        if isLoading { return }

        isLoading = true
        errorMessage = nil

        do {
            let fetched = try await store.fetchEntries(for: userID)
            entries = fetched
                .map { entry in
                    RevenueDayEntry(documentID: entry.documentID,
                                    date: calendar.startOfDay(for: entry.date),
                                    streams: entry.streams)
                }
                .sorted { $0.date > $1.date }
            knownStreams = Self.distinctStreams(from: entries)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            entries = []
        }

        isLoading = false
    }

    // MARK: - Summary

    var summaryTotal: Decimal {
        switch selectedFilter {
        case .week:
            guard let bounds = weekBounds(containing: Date()) else { return .zero }
            return total(from: bounds.start, to: bounds.end)
        case .thisMonth:
            return total(forMonthContaining: Date())
        case .selectedMonth:
            guard let date = calendar.date(from: DateComponents(year: selectedYear, month: selectedMonth, day: 1)) else { return .zero }
            return total(forMonthContaining: date)
        case .year:
            return total(forYear: selectedYear)
        }
    }

    var summaryTitle: String {
        switch selectedFilter {
        case .week:
            return "This Week"
        case .thisMonth:
            return "This Month"
        case .selectedMonth:
            let monthName = monthName(for: selectedMonth)
            return "\(monthName) \(selectedYear)"
        case .year:
            return "\(selectedYear)"
        }
    }

    var summarySubtitle: String {
        switch selectedFilter {
        case .week:
            guard let bounds = weekBounds(containing: Date()) else { return "" }
            return "\(formatted(bounds.start)) – \(formatted(bounds.end))"
        case .thisMonth:
            return monthName(for: calendar.component(.month, from: Date()))
        case .selectedMonth:
            return "Custom Month"
        case .year:
            return "Calendar Year"
        }
    }

    var summaryTotalFormatted: String {
        summaryTotal.formattedCurrency()
    }

    var availableYears: [Int] {
        let years = Set(entries.map { calendar.component(.year, from: $0.date) }).union([selectedYear])
        return years.sorted()
    }

    // MARK: - Form Helpers

    func beginAddingRevenue(for date: Date? = nil) {
        let target = calendar.startOfDay(for: date ?? Date())
        formDate = target
        formStreams = streamsForNewEntry(on: target)
        formErrorMessage = nil
        isPresentingForm = true
    }

    func handleFormDateChange() {
        let normalized = calendar.startOfDay(for: formDate)
        formDate = normalized
        if let existing = entry(for: normalized) {
            formStreams = existing.streams.map { stream in
                EditableRevenueStream(name: stream.name, amountText: stream.amount.formattedCurrency(omitSymbol: true))
            }
        }
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
        guard let userID = driveConnector.currentAccountID else {
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

        do {
            let existingDocID = entry(for: formDate)?.documentID
            let saved = try await store.save(date: formDate,
                                             streams: sanitizedStreams,
                                             documentID: existingDocID,
                                             userID: userID)
            upsertEntry(saved)
            knownStreams = Self.distinctStreams(from: entries)
            isPresentingForm = false
        } catch {
            formErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        isSavingForm = false
    }

    func formattedStreams(for entry: RevenueDayEntry) -> [String] {
        entry.streams.map { "\($0.name): \($0.amount.formattedCurrency())" }
    }

    var hasEntries: Bool {
        !entries.isEmpty
    }

    // MARK: - Private helpers

    private func observeDriveState() {
        driveConnector.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                let linked = state == .linked
                canRecordRevenue = linked
                if !linked {
                    entries = []
                    knownStreams = []
                    errorMessage = "Link Google Drive to start tracking revenue."
                } else {
                    Task { await self.refresh() }
                }
            }
            .store(in: &cancellables)
    }

    private func entry(for date: Date) -> RevenueDayEntry? {
        entries.first { calendar.isDate($0.date, inSameDayAs: date) }
    }

    private func streamsForNewEntry(on date: Date) -> [EditableRevenueStream] {
        if let existing = entry(for: date) {
            return existing.streams.map { stream in
                EditableRevenueStream(name: stream.name,
                                      amountText: stream.amount.formattedCurrency(omitSymbol: true))
            }
        }

        if knownStreams.isEmpty {
            return [EditableRevenueStream(name: "", amountText: "")]
        }

        return knownStreams.map {
            EditableRevenueStream(name: $0, amountText: "")
        }
    }

    private func sanitizeFormStreams() -> [RevenueStreamValue] {
        var sanitized: [RevenueStreamValue] = []
        for stream in formStreams {
            let trimmedName = stream.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }
            guard let decimal = decimalValue(from: stream.amountText) else { continue }
            sanitized.append(RevenueStreamValue(name: trimmedName, amount: decimal))
        }
        return sanitized
    }

    private func decimalValue(from text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let decimal = Decimal(string: trimmed, locale: Locale.current) {
            return decimal
        }
        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func upsertEntry(_ entry: RevenueDayEntry) {
        let normalizedDate = calendar.startOfDay(for: entry.date)
        var updated = entries.filter { !calendar.isDate($0.date, inSameDayAs: normalizedDate) }
        let replacement = RevenueDayEntry(documentID: entry.documentID, date: normalizedDate, streams: entry.streams)
        updated.append(replacement)
        entries = updated.sorted { $0.date > $1.date }
    }

    private func total(forMonthContaining date: Date) -> Decimal {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let start = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: start),
              let end = calendar.date(byAdding: DateComponents(day: range.count - 1), to: start) else {
            return .zero
        }
        return total(from: start, to: end)
    }

    private func total(forYear year: Int) -> Decimal {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else {
            return .zero
        }
        return total(from: start, to: end)
    }

    private func total(from start: Date, to end: Date) -> Decimal {
        let normalizedStart = calendar.startOfDay(for: start)
        let normalizedEnd = calendar.startOfDay(for: end)
        return entries
            .filter { $0.date >= normalizedStart && $0.date <= normalizedEnd }
            .reduce(Decimal.zero) { $0 + $1.total }
    }

    private func weekBounds(containing date: Date) -> (start: Date, end: Date)? {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return nil }
        let start = calendar.startOfDay(for: interval.start)
        guard let end = calendar.date(byAdding: .day, value: 6, to: start) else { return nil }
        return (start, end)
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale.current
        return formatter.string(from: date)
    }

    private func monthName(for month: Int) -> String {
        guard month >= 1 && month <= calendar.monthSymbols.count else { return "Month" }
        return calendar.monthSymbols[month - 1]
    }

    private static func distinctStreams(from entries: [RevenueDayEntry]) -> [String] {
        var set = OrderedSet<String>()
        for entry in entries {
            for stream in entry.streams {
                set.insert(stream.name)
            }
        }
        return set.array
    }
}

/// Simple ordered set wrapper preserving insertion order.
private struct OrderedSet<Element: Hashable> {
    private var elements: [Element] = []
    private var set: Set<Element> = []

    mutating func insert(_ element: Element) {
        if set.insert(element).inserted {
            elements.append(element)
        }
    }

    func contains(_ element: Element) -> Bool {
        set.contains(element)
    }

    var array: [Element] { elements }
}
