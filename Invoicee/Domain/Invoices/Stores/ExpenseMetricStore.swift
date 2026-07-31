import Foundation
import Combine

/// Shares the selected expense metric across reporting views.
@MainActor
final class ExpenseMetricStore: ObservableObject {
    @Published private(set) var selectedMetric: ExpenseMetric

    init(initialMetric: ExpenseMetric = .totalAmount) {
        selectedMetric = initialMetric
    }

    func set(metric: ExpenseMetric) {
        guard selectedMetric != metric else { return }
        selectedMetric = metric
    }
}
