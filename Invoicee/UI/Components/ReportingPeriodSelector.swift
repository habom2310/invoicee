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
                TimeframeSheet(period: Binding(get: { selection.period },
                                               set: { selection = selection.selecting($0) }))
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
    @Binding var period: ReportingPeriod
    @Environment(\.dismiss) private var dismiss

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
                ForEach(ReportingPeriod.allCases) { option in
                    Button {
                        period = option
                        dismiss()
                    } label: {
                        HStack {
                            Text(option.timeframeName)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: period == option ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(period == option ? Color.accentColor : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(period == option ? [.isButton, .isSelected] : .isButton)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .presentationDetents([.medium])
    }
}
