import SwiftUI

/// Compares category totals between the selected month and the previous month.
struct ExpenseComparisonView: View {
    let categoryTotals: [ExpenseAnalyticsViewModel.CategoryTotal]
    let previousTotals: [ExpenseAnalyticsViewModel.CategoryTotal]
    let metric: ExpenseAnalyticsViewModel.Metric
    let currentLabel: String
    let previousLabel: String

    private var maxValue: Decimal {
        let currentMax = categoryTotals.map { $0.total }.max() ?? 0
        let previousMax = previousTotals.map { $0.total }.max() ?? 0
        let maxValue = max(currentMax, previousMax)
        return maxValue == 0 ? 1 : maxValue
    }

    private var currentLookup: [String: Decimal] {
        Dictionary(uniqueKeysWithValues: categoryTotals.map { ($0.category, $0.total) })
    }

    private var previousLookup: [String: Decimal] {
        Dictionary(uniqueKeysWithValues: previousTotals.map { ($0.category, $0.total) })
    }

    private var categories: [String] {
        let allCategories = Set(categoryTotals.map { $0.category }).union(previousTotals.map { $0.category })
        return allCategories.sorted { lhs, rhs in
            let lhsValue = currentLookup[lhs] ?? previousLookup[lhs] ?? 0
            let rhsValue = currentLookup[rhs] ?? previousLookup[rhs] ?? 0
            if lhsValue == rhsValue {
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            return lhsValue > rhsValue
        }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Comparing \(metric.displayName.lowercased())")
                        .font(.headline)
                    Text("\(currentLabel) vs \(previousLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Categories") {
                if categoryTotals.isEmpty && previousTotals.isEmpty {
                    Text("No data available to compare for these periods.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(categories, id: \.self) { category in
                        CategoryComparisonBlock(category: category,
                                                currentValue: currentLookup[category] ?? 0,
                                                previousValue: previousLookup[category] ?? 0,
                                                maxValue: maxValue,
                                                metric: metric,
                                                currentLabel: currentLabel,
                                                previousLabel: previousLabel)
                    }
                }
            }
        }
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
    }
}

private struct CategoryComparisonBlock: View {
    let category: String
    let currentValue: Decimal
    let previousValue: Decimal
    let maxValue: Decimal
    let metric: ExpenseAnalyticsViewModel.Metric
    let currentLabel: String
    let previousLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category)
                .font(.subheadline)
                .foregroundStyle(.primary)

            ComparisonBarRow(label: currentLabel,
                             value: currentValue,
                             maxValue: maxValue,
                             gradient: gradient(for: .current),
                             annotationColor: .primary)

            ComparisonBarRow(label: previousLabel,
                             value: previousValue,
                             maxValue: maxValue,
                             gradient: gradient(for: .previous),
                             annotationColor: Color.secondary.opacity(0.65))
        }
        .padding(.vertical, 6)
    }

    private func gradient(for valueType: ValueType) -> LinearGradient {
        switch (metric, valueType) {
        case (.totalAmount, .current):
            return LinearGradient(colors: [Color.blue.opacity(0.7), Color.blue], startPoint: .leading, endPoint: .trailing)
        case (.totalAmount, .previous):
            return LinearGradient(colors: [Color.blue.opacity(0.25), Color.blue.opacity(0.4)], startPoint: .leading, endPoint: .trailing)
        case (.ourAmount, .current):
            return LinearGradient(colors: [Color.green.opacity(0.7), Color.green], startPoint: .leading, endPoint: .trailing)
        case (.ourAmount, .previous):
            return LinearGradient(colors: [Color.green.opacity(0.25), Color.green.opacity(0.4)], startPoint: .leading, endPoint: .trailing)
        }
    }

    private enum ValueType {
        case current
        case previous
    }
}

private struct ComparisonBarRow: View {
    let label: String
    let value: Decimal
    let maxValue: Decimal
    let gradient: LinearGradient
    let annotationColor: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)

            GeometryReader { geo in
                let width = width(for: value, in: geo.size.width)
                RoundedRectangle(cornerRadius: 8)
                    .fill(gradient)
                    .frame(width: width, height: 16)
            }
            .frame(height: 16)

            Text(formattedValue)
                .font(.footnote)
                .foregroundStyle(annotationColor)
                .frame(width: 90, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formattedValue: String {
        value.formattedCurrency()
    }

    private func width(for value: Decimal, in fullWidth: CGFloat) -> CGFloat {
        guard maxValue > 0 else { return 0 }
        let ratio = min((value as NSDecimalNumber).doubleValue / (maxValue as NSDecimalNumber).doubleValue, 1)
        return max(CGFloat(ratio) * fullWidth, value > 0 ? 4 : 0)
    }
}
