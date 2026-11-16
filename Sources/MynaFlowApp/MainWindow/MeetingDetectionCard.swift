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

/// Speaker separation for "Others": an explicit ~14 MB install, then a
/// switch. Says plainly that audio is still never kept.
struct SpeakerSeparationCard: View {
  let speakers: SpeakerSeparation
  @State private var confirmForget = false

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      separationRow
      if speakers.state == .installed && speakers.isEnabled { voicesRow }
    }
    .tint(Theme.Colors.accent)
    .raised()
    .confirmationDialog(
      "Forget all voices?", isPresented: $confirmForget, titleVisibility: .visible
    ) {
      Button("Forget all voices", role: .destructive) { Task { await speakers.forgetAllVoices() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Every voice profile and stored speaker sample is deleted from this Mac, and recognising voices turns off. Names you gave speakers stay.")
    }
  }

  /// Opt-in: remember the voices of people you name.
  private var voicesRow: some View {
    HStack(alignment: .center, spacing: Theme.Spacing.md) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Recognise voices across meetings")
          .font(Theme.Fonts.bodyStrong)
          .foregroundStyle(Theme.Colors.textPrimary)
        Text("Stores a voice profile — numbers, not audio — for people you name, and names them next time when it's sure. Never leaves this Mac.")
          .font(Theme.Fonts.caption)
          .foregroundStyle(Theme.Colors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: Theme.Spacing.md)
      Button("Forget all…") { confirmForget = true }
        .buttonStyle(.plain)
        .font(Theme.Fonts.caption)
        .foregroundStyle(Theme.Colors.danger)
        .help("Delete every voice profile")
      Toggle(
        "Recognise voices across meetings",
        isOn: Binding(get: { speakers.recognisesVoices }, set: { speakers.setRecognisesVoices($0) })
      )
      .labelsHidden()
      .toggleStyle(.switch)
    }
  }

  private var separationRow: some View {
    HStack(alignment: .center, spacing: Theme.Spacing.md) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Separate speakers")
          .font(Theme.Fonts.bodyStrong)
          .foregroundStyle(Theme.Colors.textPrimary)
        Text(note)
          .font(Theme.Fonts.caption)
          .foregroundStyle(isFailed ? Theme.Colors.danger : Theme.Colors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: Theme.Spacing.md)
      control
    }
  }

  @ViewBuilder
  private var control: some View {
    switch speakers.state {
    case .installed:
      Toggle(
        "Separate speakers",
        isOn: Binding(get: { speakers.isEnabled }, set: { speakers.setEnabled($0) })
      )
      .labelsHidden()
      .toggleStyle(.switch)
    case .installing(let fraction):
      ProgressView(value: fraction).frame(width: 90)
    case .notInstalled, .failed:
      Button("Install · 14 MB") { speakers.install() }
        .buttonStyle(NeuButtonStyle(prominent: true))
        .help("Downloads the on-device speaker models once, from huggingface.co")
    }
  }

  private var isFailed: Bool {
    if case .failed = speakers.state { return true }
    return false
  }

  private var note: String {
    switch speakers.state {
    case .failed(let message): message
    case .installing: "Downloading the speaker models…"
    case .installed where speakers.isEnabled:
      "Others is split into Speaker 1, 2, … — click a speaker to name them. Runs on this Mac; audio is still deleted as it's transcribed."
    case .installed: "Off: everyone on the call is labelled Others."
    case .notInstalled:
      "Tell the people on a call apart as Speaker 1, 2, … Runs on this Mac; audio is still deleted as it's transcribed."
    }
  }
}
