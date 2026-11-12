import EventKit
import MynaFlowCore
import SwiftUI

/// The Meetings page's detection settings: ask when a call starts, ask at
/// calendar meeting start, and the meetings coming up so the calendar
/// connection is visible.
struct MeetingDetectionCard: View {
  let detection: MeetingDetectionController

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      SectionLabel(text: "Detection")
      Toggle(isOn: Binding(get: { detection.callsEnabled }, set: { detection.setCallsEnabled($0) })) {
        label(
          "Ask when I join a call",
          "When Zoom, Teams, FaceTime, Webex, Slack, Discord or a browser starts using the mic.")
      }
      .toggleStyle(.switch)
      Toggle(
        isOn: Binding(
          get: { detection.calendarEnabled },
          set: { enabled in Task { await detection.setCalendarEnabled(enabled) } })
      ) {
        label(
          "Ask when a calendar meeting starts",
          "Events with a video link or other invitees. Read from this Mac's calendars; nothing leaves your Mac.")
      }
      .toggleStyle(.switch)
      .help("Google, Outlook and iCloud accounts added in System Settings → Internet Accounts show up here.")
      calendarState
      Text("Myna Flow only asks. Notes start when you click Start Notes.")
        .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
    }
    // System switches render "on" in the accent colour, so state is visible
    // on the dark surface.
    .tint(Theme.Colors.accent)
    .raised()
  }

  /// Denied access shows only the fix; no calendars says so; otherwise the
  /// picker and what's coming up.
  @ViewBuilder
  private var calendarState: some View {
    let access = detection.calendar.authorization
    if access == .denied || access == .restricted {
      HStack(spacing: Theme.Spacing.sm) {
        Label("Calendar access is off for Myna Flow.", systemImage: "exclamationmark.triangle")
          .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.warning)
        Button("Open Settings…") { detection.calendar.openSettings() }
          .buttonStyle(NeuButtonStyle())
      }
    } else if detection.calendarEnabled {
      if detection.calendar.calendars.isEmpty {
        Text("No calendars on this Mac. Add an account in System Settings → Internet Accounts.")
          .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
      } else {
        CalendarPicker(detection: detection)
        upcoming
      }
    }
  }

  private var upcoming: some View {
    let next = detection.calendar.meetings.filter { $0.end > Date() }.prefix(3)
    return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
      if next.isEmpty {
        Text("No meetings with a video link or invitees in the next 12 hours.")
          .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
      }
      ForEach(Array(next)) { meeting in
        HStack(spacing: Theme.Spacing.sm) {
          Text(meeting.start.formatted(date: .omitted, time: .shortened))
            .font(Theme.Fonts.mono).foregroundStyle(Theme.Colors.textSecondary)
          Text(meeting.title).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.textPrimary)
            .lineLimit(1)
          if meeting.link != nil {
            Image(systemName: "video").font(.system(size: 10)).foregroundStyle(Theme.Colors.accent)
              .accessibilityLabel("Has a video link")
          }
        }
      }
    }
    .inset()
  }

  private func label(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.textPrimary)
      Text(detail).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
    }
  }
}
