import MynaFlowCore
import SwiftUI

/// Find-in-transcript state shared by the toolbar (above the scroll) and the
/// body (inside it).
struct TranscriptFind: Equatable {
  enum Speaker: Hashable {
    case all, you, others
    /// One "Others" speaker, by number.
    case person(Int)
  }

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

  func includes(_ channel: MeetingChannel, speaker number: Int? = nil) -> Bool {
    switch speaker {
    case .all: true
    case .you: channel == .you
    case .others: channel == .others
    case .person(let wanted): channel == .others && number == wanted
    }
  }
}

/// Find field with a match counter and stepping, plus a speaker filter.
struct TranscriptToolbar: View {
  @Binding var find: TranscriptFind
  /// "Others" speakers told apart in this meeting; each gets a filter.
  var speakers: [Int] = []
  let meeting: MeetingRecord
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

      PillSegments(selection: $find.speaker, options: filterOptions, compact: true)
      .accessibilityLabel("Show lines from")
      Spacer(minLength: 0)
    }
    .onChange(of: find.query) { find.current = 0 }
    .onChange(of: find.speaker) { find.current = 0 }
    .onChange(of: find.focusRequest) { focused = true }
  }

  /// All / You / Others, then each speaker by name — up to five, beyond
  /// which "Others" still covers them all.
  private var filterOptions: [PillSegments<TranscriptFind.Speaker>.Option] {
    var options: [PillSegments<TranscriptFind.Speaker>.Option] = [
      .init(value: .all, title: "All"), .init(value: .you, title: "You"),
      .init(value: .others, title: "Others"),
    ]
    for number in speakers.prefix(5) {
      options.append(
        .init(value: .person(number), title: meeting.label(channel: .others, speaker: number)))
    }
    return options
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
  let meeting: MeetingRecord
  @Binding var find: TranscriptFind
  let proxy: ScrollViewProxy
  let naming: SpeakerNaming

  private var segments: [MeetingSegment] { meeting.segments }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private struct Hit {
    let turn: Int
    let range: Range<String.Index>
  }

  var body: some View {
    let turns = MeetingTranscript.turns(segments).filter { find.includes($0.channel, speaker: $0.speaker) }
    let hits = turns.enumerated().flatMap { index, turn in
      MeetingSearch.matches(of: find.query, in: turn.text).map { Hit(turn: index, range: $0) }
    }
    let current = hits.isEmpty ? nil : hits[min(find.current, hits.count - 1)]

    Group {
      if segments.isEmpty {
        placeholder("Nothing was transcribed.")
      } else if turns.isEmpty {
        placeholder("Nothing from \(filterName) in this meeting.")
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

  private var filterName: String {
    switch find.speaker {
    case .all, .others: "Others"
    case .you: "You"
    case .person(let number): meeting.label(channel: .others, speaker: number)
    }
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
    let tone = SpeakerTone(channel: turn.channel, speaker: turn.speaker)
    return HStack(alignment: .top, spacing: Theme.Spacing.md) {
      RoundedRectangle(cornerRadius: 1)
        .fill(tone.rule)
        .frame(width: 2)
      VStack(alignment: .leading, spacing: Theme.Spacing.xs + 2) {
        HStack(spacing: Theme.Spacing.sm) {
          SpeakerChip(
            label: meeting.label(channel: turn.channel, speaker: turn.speaker), tone: tone,
            speaker: turn.speaker, meeting: meeting, naming: naming)
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

/// The colours one voice uses: "You" in the accent, each "Others" speaker
/// in its own muted hue so a back-and-forth reads at a glance, and plain
/// "Others" (not told apart) neutral.
struct SpeakerTone {
  let text: Color
  let fill: Color
  let rule: Color

  private static let palette: [Color] = [
    Color(red: 0.55, green: 0.72, blue: 0.86),  // blue
    Color(red: 0.62, green: 0.80, blue: 0.62),  // green
    Color(red: 0.84, green: 0.62, blue: 0.78),  // rose
    Color(red: 0.70, green: 0.66, blue: 0.90),  // violet
    Color(red: 0.86, green: 0.70, blue: 0.52),  // sand
    Color(red: 0.55, green: 0.80, blue: 0.78),  // teal
  ]

  init(channel: MeetingChannel, speaker: Int?) {
    if channel == .you {
      (text, fill, rule) = (Theme.Colors.accent, Theme.Colors.accentMuted, Theme.Colors.accent)
    } else if let speaker {
      let hue = Self.palette[(speaker - 1) % Self.palette.count]
      (text, fill, rule) = (hue, hue.opacity(0.16), hue.opacity(0.7))
    } else {
      (text, fill, rule) = (Theme.Colors.textSecondary, Theme.Colors.surface, Theme.Colors.hairline)
    }
  }
}

/// What naming a speaker can offer: likely names, people met before, and
/// the actions. Built by the Meetings page for one meeting.
struct SpeakerNaming {
  /// Invitees not yet given to a speaker, then last time's names.
  var suggestions: [String] = []
  /// Everyone met in meetings, searched as you type.
  var people: [Person] = []
  /// Names a speaker ("" clears the name).
  var name: (Int, String) -> Void = { _, _ in }
  /// "Same person": the first speaker's lines become the second's.
  var merge: (Int, Int) -> Void = { _, _ in }
  /// Whose voice a speaker resembles, when not sure enough to name them.
  var soundsLike: (Int) -> String? = { _ in nil }
}

/// Who spoke. An "Others" speaker's chip opens naming: one click on a
/// likely name, a search over people met before, a new name, or "same
/// person as" another speaker.
struct SpeakerChip: View {
  let label: String
  let tone: SpeakerTone
  /// Set for a told-apart "Others" speaker; nil for You or plain Others.
  var speaker: Int?
  var meeting: MeetingRecord?
  var naming = SpeakerNaming()
  @State private var editing = false
  @State private var draft = ""

  var body: some View {
    let chip = Text(label)
      .font(Theme.Fonts.caption)
      .foregroundStyle(tone.text)
      .lineLimit(1)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(Capsule().fill(tone.fill))
      .overlay(Capsule().strokeBorder(Theme.Colors.hairline))
    if let speaker, let meeting {
      Button {
        draft = ""
        editing = true
      } label: {
        chip
      }
      .buttonStyle(.plain)
      .help("Name this speaker")
      .accessibilityHint("Names this speaker for this meeting")
      .popover(isPresented: $editing, arrowEdge: .bottom) {
        popover(speaker: speaker, meeting: meeting)
      }
    } else {
      chip
    }
  }

  private func popover(speaker: Int, meeting: MeetingRecord) -> some View {
    let current = meeting.speakerNames[speaker]
    let matches = matchingPeople(excluding: current)
    let others = Set(meeting.segments.compactMap(\.speaker)).subtracting([speaker]).sorted()
    return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      Text("Who is \(label)?").font(Theme.Fonts.bodyStrong)
      if let likely = naming.soundsLike(speaker), current == nil, draft.isEmpty {
        SectionLabel(text: "Sounds like")
        choice(likely, systemImage: "waveform") { pick(likely, speaker: speaker) }
      }
      if !naming.suggestions.isEmpty && draft.isEmpty {
        SectionLabel(text: "In this meeting")
        ForEach(naming.suggestions.prefix(6), id: \.self) { name in
          choice(name, systemImage: "person.crop.circle") { pick(name, speaker: speaker) }
        }
      }
      TextField("Name", text: $draft)
        .textFieldStyle(.roundedBorder)
        .frame(width: 220)
        .onSubmit { pick(draft, speaker: speaker) }
      ForEach(matches, id: \.id) { person in
        choice(person.name, systemImage: "person") { pick(person.name, speaker: speaker) }
      }
      HStack {
        if !others.isEmpty {
          Menu("Same person as…") {
            ForEach(others, id: \.self) { other in
              Button(meeting.label(channel: .others, speaker: other)) {
                naming.merge(speaker, other)
                editing = false
              }
            }
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .help("The speaker was split in two; give these lines to the other speaker")
        }
        Spacer()
        if current != nil {
          Button("Clear") { pick("", speaker: speaker) }
        }
        Button("Save") { pick(draft, speaker: speaker) }
          .keyboardShortcut(.defaultAction)
          .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(Theme.Spacing.md)
    .frame(minWidth: 260)
  }

  /// People whose name contains what's typed; nothing until something is.
  private func matchingPeople(excluding current: String?) -> [Person] {
    let query = draft.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return [] }
    return naming.people
      .filter { $0.name.localizedCaseInsensitiveContains(query) && $0.name != current }
      .prefix(5).map { $0 }
  }

  private func choice(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.vertical, 2)
  }

  private func pick(_ name: String, speaker: Int) {
    naming.name(speaker, name)
    editing = false
  }
}
