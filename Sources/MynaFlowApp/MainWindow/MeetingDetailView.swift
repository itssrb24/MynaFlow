import MynaFlowCore
import SwiftUI

/// One meeting on its own page: a fixed header (back, title, actions, tabs)
/// over a scrolling reading column, so a long transcript reads like a
/// document instead of a box inside a list.
struct MeetingDetailView: View {
  enum Tab: Hashable { case summary, transcript }

  let meeting: MeetingRecord
  let back: () -> Void
  let export: () -> Void
  let copy: () -> Void
  let delete: () -> Void
  /// Names (or with "", un-names) an "Others" speaker in this meeting.
  let rename: (Int, String) -> Void
  /// Calendar events near this meeting's start, for linking one after the fact.
  let linkCandidates: () -> [CalendarMeeting]
  let link: (CalendarMeeting) -> Void

  @State private var tab: Tab
  @State private var find: TranscriptFind
  @State private var copied = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let readingWidth: CGFloat = 680

  /// Opened from a search, the transcript comes up with that search found.
  init(
    meeting: MeetingRecord, initialQuery: String, back: @escaping () -> Void,
    export: @escaping () -> Void, copy: @escaping () -> Void, delete: @escaping () -> Void,
    rename: @escaping (Int, String) -> Void,
    linkCandidates: @escaping () -> [CalendarMeeting] = { [] },
    link: @escaping (CalendarMeeting) -> Void = { _ in }
  ) {
    self.rename = rename
    self.linkCandidates = linkCandidates
    self.link = link
    self.meeting = meeting
    self.back = back
    self.export = export
    self.copy = copy
    self.delete = delete
    let query = initialQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    _tab = State(initialValue: meeting.summary == nil || !query.isEmpty ? .transcript : .summary)
    _find = State(initialValue: TranscriptFind(query: query))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Rectangle().fill(Theme.Colors.hairline).frame(height: 1)
      ScrollViewReader { proxy in
        ScrollView {
          content(proxy: proxy)
            .frame(maxWidth: Self.readingWidth, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .background(keyboardShortcuts)
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      Button(action: back) {
        Label("Meetings", systemImage: "chevron.left")
          .font(Theme.Fonts.bodyStrong)
          .foregroundStyle(Theme.Colors.accent)
      }
      .buttonStyle(.plain)
      .keyboardShortcut("[", modifiers: .command)
      .help("Back to all meetings (Esc)")

      HStack(alignment: .top, spacing: Theme.Spacing.md) {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
          Text(meeting.displayTitle)
            .font(Theme.Fonts.display)
            .foregroundStyle(Theme.Colors.textPrimary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
          Text(meeting.metaLine)
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.Colors.textSecondary)
          if let people = meeting.context?.others, !people.isEmpty {
            AttendeeChips(attendees: people)
              .padding(.top, 2)
          }
        }
        Spacer(minLength: Theme.Spacing.md)
        actions
      }

      HStack(spacing: Theme.Spacing.md) {
        PillSegments(
          selection: $tab.animation(reduceMotion ? nil : Theme.Motion.ease),
          options: [
            .init(value: .summary, title: "Summary", symbol: "sparkles"),
            .init(value: .transcript, title: "Transcript", symbol: "text.alignleft"),
          ])
        Spacer()
      }
      if tab == .transcript, !meeting.segments.isEmpty {
        TranscriptToolbar(find: $find, speakers: speakerNumbers, meeting: meeting)
          .transition(.opacity)
      }
    }
    .padding(.horizontal, Theme.Spacing.xl)
    .padding(.top, Theme.Spacing.lg)
    .padding(.bottom, Theme.Spacing.md)
  }

  private var actions: some View {
    HStack(spacing: Theme.Spacing.sm) {
      if meeting.context?.eventID == nil {
        LinkEventMenu(candidates: linkCandidates, link: link)
      }
      IconAction(
        title: copied ? "Copied" : "Copy as Markdown",
        symbol: copied ? "checkmark" : "doc.on.doc", tint: copied ? Theme.Colors.success : nil
      ) {
        copy()
        withAnimation(.easeOut(duration: Theme.Motion.fast)) { copied = true }
        Task {
          try? await Task.sleep(for: .seconds(1.4))
          withAnimation(.easeOut(duration: Theme.Motion.fast)) { copied = false }
        }
      }
      IconAction(title: "Export as Markdown…", symbol: "square.and.arrow.up", action: export)
      IconAction(title: "Delete…", symbol: "trash", tint: Theme.Colors.danger, action: delete)
    }
  }

  /// The "Others" speakers told apart in this meeting, in number order.
  private var speakerNumbers: [Int] {
    Set(meeting.segments.compactMap(\.speaker)).sorted()
  }

  // MARK: - Body

  @ViewBuilder
  private func content(proxy: ScrollViewProxy) -> some View {
    switch tab {
    case .summary:
      MeetingSummaryPane(meeting: meeting) {
        withAnimation(reduceMotion ? nil : Theme.Motion.ease) { tab = .transcript }
      }
      .transition(.opacity)
    case .transcript:
      TranscriptBody(meeting: meeting, find: $find, proxy: proxy, rename: rename)
        .transition(.opacity)
    }
  }

  /// Esc clears an active find first, then goes back; ⌘F finds; ⌘G / ⇧⌘G
  /// step through matches.
  private var keyboardShortcuts: some View {
    Group {
      Button("Back") {
        if !find.query.isEmpty { find.query = "" } else { back() }
      }
      .keyboardShortcut(.cancelAction)
      Button("Find") {
        withAnimation(reduceMotion ? nil : Theme.Motion.ease) { tab = .transcript }
        find.focusRequest += 1
      }
      .keyboardShortcut("f", modifiers: .command)
      Button("Next match") { find.step(1) }.keyboardShortcut("g", modifiers: .command)
      Button("Previous match") { find.step(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }
}

/// A round icon button with its name as tooltip and VoiceOver label.
struct IconAction: View {
  let title: String
  let symbol: String
  var tint: Color?
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(hovering ? (tint ?? Theme.Colors.accent) : (tint ?? Theme.Colors.textSecondary))
        .frame(width: 32, height: 32)
        .background(
          Circle()
            .fill(Theme.Colors.surface)
            .shadow(color: Theme.Colors.shade, radius: hovering ? 6 : 4, x: 2, y: 2)
            .shadow(color: Theme.Colors.highlight, radius: 4, x: -1, y: -1))
        .overlay(Circle().strokeBorder(Theme.Colors.hairline))
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: Theme.Motion.fast), value: hovering)
    .help(title)
    .accessibilityLabel(title)
  }
}

/// A row of options in a well, the chosen one raised on a pill that slides.
struct PillSegments<Value: Hashable>: View {
  struct Option {
    let value: Value
    let title: String
    var symbol: String?
  }

  @Binding var selection: Value
  let options: [Option]
  var compact = false
  @Namespace private var pill

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options, id: \.value) { option in
        let selected = option.value == selection
        Button {
          selection = option.value
        } label: {
          HStack(spacing: 5) {
            if let symbol = option.symbol {
              Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            }
            Text(option.title)
          }
          .font(compact ? Theme.Fonts.caption : Theme.Fonts.bodyStrong)
          .foregroundStyle(selected ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
          .padding(.horizontal, compact ? Theme.Spacing.sm + 2 : Theme.Spacing.md)
          .padding(.vertical, compact ? 4 : 6)
          .background {
            if selected {
              RoundedRectangle(cornerRadius: Theme.Radius.control - 2, style: .continuous)
                .fill(Theme.Colors.surface)
                .shadow(color: Theme.Colors.shade, radius: 5, x: 2, y: 2)
                .shadow(color: Theme.Colors.highlight, radius: 3, x: -1, y: -1)
                .matchedGeometryEffect(id: "pill", in: pill)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(3)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        .fill(Theme.Colors.well))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        .strokeBorder(Theme.Colors.hairline))
    .fixedSize()
  }
}

/// Who was on the invite: a row of quiet name chips, the first few then
/// "+N".
struct AttendeeChips: View {
  let attendees: [MeetingAttendee]
  private static let shown = 6

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "person.2")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.Colors.textTertiary)
        .accessibilityHidden(true)
      ForEach(attendees.prefix(Self.shown), id: \.self) { person in
        Text(person.displayName)
          .font(Theme.Fonts.caption)
          .foregroundStyle(Theme.Colors.textSecondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(Capsule().fill(Theme.Colors.surface))
          .overlay(Capsule().strokeBorder(Theme.Colors.hairline))
          .help(person.email ?? person.displayName)
      }
      if attendees.count > Self.shown {
        Text("+\(attendees.count - Self.shown)")
          .font(Theme.Fonts.caption)
          .foregroundStyle(Theme.Colors.textTertiary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Invited: " + attendees.map(\.displayName).joined(separator: ", "))
  }
}

/// "Link to calendar event…" for a meeting recorded without one: events
/// within three hours of its start, listed when the menu opens.
struct LinkEventMenu: View {
  let candidates: () -> [CalendarMeeting]
  let link: (CalendarMeeting) -> Void

  var body: some View {
    Menu {
      let events = candidates()
      if events.isEmpty {
        Text("No calendar events near this meeting")
      }
      ForEach(events) { event in
        Button("\(event.start.formatted(date: .omitted, time: .shortened))  \(event.title)") {
          link(event)
        }
      }
    } label: {
      Image(systemName: "calendar.badge.plus")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Theme.Colors.textSecondary)
        .frame(width: 32, height: 32)
        .background(Circle().fill(Theme.Colors.surface))
        .overlay(Circle().strokeBorder(Theme.Colors.hairline))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Link to calendar event…")
    .accessibilityLabel("Link to calendar event")
  }
}
