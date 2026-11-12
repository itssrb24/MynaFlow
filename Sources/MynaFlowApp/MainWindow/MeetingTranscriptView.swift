import MynaFlowCore
import SwiftUI

/// Find-in-transcript state shared by the toolbar (above the scroll) and the
/// body (inside it).
struct TranscriptFind: Equatable {
  enum Speaker: Hashable { case all, you, others }

  var query = ""
  var speaker: Speaker = .all
  /// Which match is current; wraps, so ⌘G past the last goes to the first.
  var current = 0
  /// Set by the body, which owns the text the matches come from.
  var hitCount = 0
  /// Bumped by ⌘F to focus the field.
  var focusRequest = 0

  mutating func step(_ delta: Int) {
    guard hitCount > 0 else { return }
    current = ((current + delta) % hitCount + hitCount) % hitCount
  }

  func includes(_ channel: MeetingChannel) -> Bool {
    switch speaker {
    case .all: true
    case .you: channel == .you
    case .others: channel == .others
    }
  }
}

/// Find field with a match counter and stepping, plus a speaker filter.
struct TranscriptToolbar: View {
  @Binding var find: TranscriptFind
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: Theme.Spacing.md) {
      HStack(spacing: Theme.Spacing.sm) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(Theme.Colors.textTertiary)
          .accessibilityHidden(true)
        TextField("Find in transcript", text: $find.query)
          .textFieldStyle(.plain)
          .font(Theme.Fonts.body)
          .foregroundStyle(Theme.Colors.textPrimary)
          .focused($focused)
          .onSubmit { find.step(1) }
        if !find.query.isEmpty {
          Text(counter)
            .font(Theme.Fonts.caption)
            .monospacedDigit()
            .foregroundStyle(find.hitCount == 0 ? Theme.Colors.warning : Theme.Colors.textSecondary)
            .fixedSize()
          stepButton("chevron.up", "Previous match") { find.step(-1) }
          stepButton("chevron.down", "Next match") { find.step(1) }
          Button {
            find.query = ""
          } label: {
            Label("Clear find", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
          }
          .buttonStyle(.plain)
          .foregroundStyle(Theme.Colors.textTertiary)
        }
      }
      .inset(padding: Theme.Spacing.sm)
      .frame(maxWidth: 340)

      PillSegments(
        selection: $find.speaker,
        options: [
          .init(value: .all, title: "All"),
          .init(value: .you, title: "You"),
          .init(value: .others, title: "Others"),
        ], compact: true)
      .accessibilityLabel("Show lines from")
      Spacer(minLength: 0)
    }
    .onChange(of: find.query) { find.current = 0 }
    .onChange(of: find.speaker) { find.current = 0 }
    .onChange(of: find.focusRequest) { focused = true }
  }

  private var counter: String {
    find.hitCount == 0 ? "No matches" : "\(find.current + 1) of \(find.hitCount)"
  }

  private func stepButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: symbol).labelStyle(.iconOnly)
        .font(.system(size: 11, weight: .semibold))
    }
    .buttonStyle(.plain)
    .foregroundStyle(find.hitCount > 1 ? Theme.Colors.textSecondary : Theme.Colors.textTertiary)
    .disabled(find.hitCount < 2)
    .help(title)
  }
}

/// The transcript as speaker turns — one paragraph per uninterrupted
/// stretch — with "You" marked by an accent rule, matches highlighted, and
/// the current match scrolled into view.
struct TranscriptBody: View {
  let segments: [MeetingSegment]
  @Binding var find: TranscriptFind
  let proxy: ScrollViewProxy
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private struct Hit {
    let turn: Int
    let range: Range<String.Index>
  }

  var body: some View {
    let turns = MeetingTranscript.turns(segments).filter { find.includes($0.channel) }
    let hits = turns.enumerated().flatMap { index, turn in
      MeetingSearch.matches(of: find.query, in: turn.text).map { Hit(turn: index, range: $0) }
    }
    let current = hits.isEmpty ? nil : hits[min(find.current, hits.count - 1)]

    Group {
      if segments.isEmpty {
        placeholder("Nothing was transcribed.")
      } else if turns.isEmpty {
        placeholder(find.speaker == .you ? "Nothing from You in this meeting." : "Nothing from Others in this meeting.")
      } else {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
          ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
            row(
              turn,
              ranges: hits.filter { $0.turn == index }.map(\.range),
              current: current?.turn == index ? current?.range : nil)
            .id(index)
          }
        }
        .textSelection(.enabled)
      }
    }
    .onChange(of: hits.count, initial: true) { find.hitCount = hits.count }
    .onChange(of: find.current) { scroll(to: current) }
    .onChange(of: find.query) { scroll(to: current) }
  }

  private func scroll(to hit: Hit?) {
    guard let hit else { return }
    withAnimation(reduceMotion ? nil : Theme.Motion.ease) {
      proxy.scrollTo(hit.turn, anchor: .center)
    }
  }

  private func row(
    _ turn: MeetingTurn, ranges: [Range<String.Index>], current: Range<String.Index>?
  ) -> some View {
    let isYou = turn.channel == .you
    return HStack(alignment: .top, spacing: Theme.Spacing.md) {
      RoundedRectangle(cornerRadius: 1)
        .fill(isYou ? Theme.Colors.accent : Theme.Colors.hairline)
        .frame(width: 2)
      VStack(alignment: .leading, spacing: Theme.Spacing.xs + 2) {
        HStack(spacing: Theme.Spacing.sm) {
          SpeakerChip(channel: turn.channel)
          Text(MeetingTranscript.timestamp(turn.startSeconds))
            .font(Theme.Fonts.mono)
            .monospacedDigit()
            .foregroundStyle(Theme.Colors.textTertiary)
        }
        Text(Self.highlighted(turn.text, ranges: ranges, current: current))
          .font(Theme.Fonts.reading)
          .lineSpacing(Theme.Fonts.readingLineSpacing)
          .foregroundStyle(Theme.Colors.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// The turn's text with every match tinted, and the current one solid.
  static func highlighted(
    _ text: String, ranges: [Range<String.Index>], current: Range<String.Index>?
  ) -> AttributedString {
    var result = AttributedString()
    var cursor = text.startIndex
    for range in ranges {
      result += AttributedString(String(text[cursor..<range.lowerBound]))
      var hit = AttributedString(String(text[range]))
      if range == current {
        hit.backgroundColor = Theme.Colors.accent
        hit.foregroundColor = Theme.Colors.base
      } else {
        hit.backgroundColor = Theme.Colors.accentMuted
      }
      result += hit
      cursor = range.upperBound
    }
    result += AttributedString(String(text[cursor...]))
    return result
  }

  private func placeholder(_ text: String) -> some View {
    Text(text)
      .font(Theme.Fonts.body)
      .foregroundStyle(Theme.Colors.textSecondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .inset()
  }
}

/// "You" in the accent, "Others" neutral — the two voices of a call.
struct SpeakerChip: View {
  let channel: MeetingChannel

  var body: some View {
    let isYou = channel == .you
    Text(channel.label)
      .font(Theme.Fonts.caption)
      .foregroundStyle(isYou ? Theme.Colors.accent : Theme.Colors.textSecondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(
        Capsule().fill(isYou ? Theme.Colors.accentMuted : Theme.Colors.surface))
      .overlay(Capsule().strokeBorder(Theme.Colors.hairline))
  }
}
