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

  @State private var tab: Tab
  @State private var find: TranscriptFind
  @State private var copied = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let readingWidth: CGFloat = 680

  /// Opened from a search, the transcript comes up with that search found.
  init(
    meeting: MeetingRecord, initialQuery: String, back: @escaping () -> Void,
    export: @escaping () -> Void, copy: @escaping () -> Void, delete: @escaping () -> Void
  ) {
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
        TranscriptToolbar(find: $find)
          .transition(.opacity)
      }
    }
    .padding(.horizontal, Theme.Spacing.xl)
    .padding(.top, Theme.Spacing.lg)
    .padding(.bottom, Theme.Spacing.md)
  }

  private var actions: some View {
    HStack(spacing: Theme.Spacing.sm) {
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
      TranscriptBody(segments: meeting.segments, find: $find, proxy: proxy)
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
