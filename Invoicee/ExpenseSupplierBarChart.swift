import SwiftUI

struct ExpenseSupplierBarChart: View {
    let totals: [ExpenseAnalyticsViewModel.SupplierTotal]
    let metric: ExpenseAnalyticsViewModel.Metric

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

                    Text(total.total.formattedCurrency())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
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
}
