internal import SwiftUI

/// The control every reporting tab navigates periods with: step one period back or
/// forward, or tap the middle to change timeframe.
///
/// Renders as its own `Section`, so a screen adds it by placing it at the top of its
/// `List`.
struct ReportingPeriodSelector: View {
    @Binding var selection: ReportingPeriodSelection
    @State private var isShowingTimeframe = false

    var body: some View {
        Section {
            HStack(spacing: 0) {
                stepButton(systemImage: "chevron.left", delta: -1, enabled: true, label: "Previous period")

                Button {
                    isShowingTimeframe = true
                } label: {
                    Text(selection.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Timeframe, \(selection.title)")
                .accessibilityHint("Opens the timeframe picker")

                stepButton(systemImage: "chevron.right",
                           delta: 1,
                           enabled: selection.canStepForward(),
                           label: "Next period")
            }
            // The section's own card is the control, so the chevrons can sit out at its
            // edges instead of inside a second rounded box.
            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            .sheet(isPresented: $isShowingTimeframe) {
                TimeframeSheet(selection: $selection)
            }
        }
    }

    private func stepButton(systemImage: String, delta: Int, enabled: Bool, label: String) -> some View {
        Button {
            selection = selection.stepped(by: delta)
        } label: {
            Image(systemName: systemImage)
                .font(.footnote.weight(.bold))
                // A wide hit area: the arrows sit at the very edges of the control.
                .frame(width: 44, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

/// Picks how wide a span a report covers, and jumps to the one in progress.
private struct TimeframeSheet: View {
    @Binding var selection: ReportingPeriodSelection
    @Environment(\.dismiss) private var dismiss
    @State private var isEditingCustomRange = false

    var body: some View {
        VStack(spacing: 0) {
            // A plain header rather than a navigation bar, so the title and Done share a
            // line the way a half-height sheet has room for.
            HStack(alignment: .firstTextBaseline) {
                Text("Timeframe")
                    .font(.largeTitle.weight(.bold))
                Spacer()
                Button("Done") { dismiss() }
                    .font(.headline)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)

            List {
                ForEach(ReportingPeriod.presetCases) { option in
                    row(for: option) {
                        selection = selection.selecting(option)
                        dismiss()
                    } label: {
                        Text(option.timeframeName)
                            .foregroundStyle(.primary)
                    }
                }

                row(for: .custom) {
                    isEditingCustomRange = true
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ReportingPeriod.custom.timeframeName)
                            .foregroundStyle(.primary)
                        // Only meaningful once the editor has produced dates.
                        if selection.period.isCustom {
                            Text(selection.range.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .presentationDetents([.medium])
        .sheet(isPresented: $isEditingCustomRange) {
            CustomRangeSheet(range: selection.range) { picked in
                selection = selection.selectingCustom(picked)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func row(for option: ReportingPeriod,
                     action: @escaping () -> Void,
                     @ViewBuilder label: () -> some View) -> some View {
        let isSelected = selection.period == option
        Button(action: action) {
            HStack {
                label()
                Spacer()
                if option.isCustom, isSelected {
                    Text("Edit")
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                }
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Picks the span a custom selection covers, on one calendar.
private struct CustomRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var range: ReportingDateRange
    private let apply: (ReportingDateRange) -> Void

    init(range: ReportingDateRange, apply: @escaping (ReportingDateRange) -> Void) {
        // A span running past today would compare against days that cannot hold figures.
        let today = Calendar.current.startOfDay(for: Date())
        _range = State(initialValue: ReportingDateRange(start: min(range.start, today),
                                                        end: min(range.end, today)))
        self.apply = apply
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    CalendarRangePicker(range: $range)

                    // The one thing a custom span does differently is what it measures
                    // against, so it is spelled out before the dates are committed.
                    VStack(spacing: 0) {
                        summaryRow("Length", lengthDescription)
                        Divider()
                        summaryRow("Compares with", comparisonDescription)
                    }
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .navigationTitle("Custom date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        apply(range)
                        dismiss()
                    }
                }
            }
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var dayCount: Int {
        (Calendar.current.dateComponents([.day], from: range.start, to: range.end).day ?? 0) + 1
    }

    private var lengthDescription: String {
        dayCount == 1 ? "1 day" : "\(dayCount) days"
    }

    private var comparisonDescription: String {
        guard let preceding = Calendar.current.precedingSpan(matching: range) else { return "—" }
        return preceding.description
    }
}
