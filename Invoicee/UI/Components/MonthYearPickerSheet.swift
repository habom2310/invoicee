internal import SwiftUI

/// Wheel pickers for choosing a reporting month and year, shared by every tab.
struct MonthYearPickerSheet: View {
    @Binding var month: Int
    @Binding var year: Int
    var months: [Int] = Array(1...12)
    var years: [Int]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                Text("Select Month")
                    .font(.headline)
                    .padding(.top)

                HStack(spacing: 0) {
                    Picker("Month", selection: $month) {
                        ForEach(months, id: \.self) { month in
                            Text(ReportingDateFormatter.name(for: month)).tag(month)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipped()

                    Picker("Year", selection: $year) {
                        ForEach(years, id: \.self) { year in
                            Text(verbatim: String(year)).tag(year)
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
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(320), .medium])
    }
}
