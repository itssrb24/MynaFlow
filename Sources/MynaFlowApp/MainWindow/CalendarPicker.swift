import SwiftUI

/// Choose which calendars meeting prompts watch, grouped by account.
/// Collapsed by default; the summary line says how many are watched.
struct CalendarPicker: View {
  let detection: MeetingDetectionController
  @State private var isExpanded = false

  var body: some View {
    let calendars = detection.calendar.calendars
    let watched = calendars.filter { detection.calendar.selection.includes($0.id) }.count
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        ForEach(accounts(calendars), id: \.self) { account in
          Text(account.uppercased())
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.textTertiary)
            .padding(.top, Theme.Spacing.xs)
          ForEach(calendars.filter { $0.account == account }) { option in
            Toggle(isOn: binding(for: option)) {
              HStack(spacing: Theme.Spacing.sm) {
                Circle()
                  .fill(option.color.map { Color(cgColor: $0) } ?? Theme.Colors.textTertiary)
                  .frame(width: 8, height: 8)
                Text(option.title)
                  .font(Theme.Fonts.body)
                  .foregroundStyle(Theme.Colors.textPrimary)
              }
            }
            .toggleStyle(.checkbox)
          }
        }
      }
      .padding(.top, Theme.Spacing.xs)
    } label: {
      Text("Calendars · \(watched) of \(calendars.count) watched")
        .font(Theme.Fonts.bodyStrong)
        .foregroundStyle(Theme.Colors.textSecondary)
    }
    .tint(Theme.Colors.accent)
  }

  /// Account names in display order (the source list is already sorted).
  private func accounts(_ calendars: [CalendarOption]) -> [String] {
    calendars.reduce(into: [String]()) { names, option in
      if names.last != option.account { names.append(option.account) }
    }
  }

  private func binding(for option: CalendarOption) -> Binding<Bool> {
    Binding(
      get: { detection.calendar.selection.includes(option.id) },
      set: { detection.setCalendar(option.id, watched: $0) })
  }
}
