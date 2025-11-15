internal import SwiftUI

/// Horizontal bar chart breaking down totals by supplier.
struct ExpenseSupplierBarChart: View {
    let totals: [ExpenseAnalyticsViewModel.SupplierTotal]
    let metric: ExpenseAnalyticsViewModel.Metric
    let overallTotal: Decimal

    private var maxValue: Decimal {
        totals.map { $0.total }.max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(totals) { total in
                HStack(alignment: .center, spacing: 12) {
                    Text(total.supplier)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .frame(width: 140, alignment: .leading)
                        .lineLimit(1)

                    GeometryReader { geo in
                        let width = barWidth(for: total.total, in: geo.size.width)
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: gradientColors,
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: width, height: 16)
                    }
                    .frame(height: 16)

                    Text("\(total.total.formattedCurrency()) (\(percentageText(for: total.total)))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .trailing)
                }
            }
        }
    }

    private var gradientColors: [Color] {
        switch metric {
        case .totalAmount: return [Color.purple.opacity(0.7), Color.purple]
        case .ourAmount: return [Color.teal.opacity(0.7), Color.teal]
        }
    }

    private func barWidth(for value: Decimal, in fullWidth: CGFloat) -> CGFloat {
        guard maxValue > 0 else { return 0 }
        let ratio = min((value as NSDecimalNumber).doubleValue / (maxValue as NSDecimalNumber).doubleValue, 1)
        return max(CGFloat(ratio) * fullWidth, 4)
    }

    private func percentageText(for value: Decimal) -> String {
        guard overallTotal > 0 else { return "0%" }
        let ratio = max(min((value as NSDecimalNumber).doubleValue / (overallTotal as NSDecimalNumber).doubleValue, 1), 0)
        return ratio.formatted(.percent.precision(.fractionLength(0...1)))
    }
}
