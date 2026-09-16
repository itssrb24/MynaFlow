import Foundation
import Testing

@testable import MynaFlowCore

@Suite("DictationStateMachine")
struct DictationStateMachineTests {
  @Test("Full happy path: idle → recording → processing → inserting → completed → idle")
  func happyPath() throws {
    var machine = DictationStateMachine()
    #expect(machine.state == .idle)

    try machine.apply(.start(targetApplication: "com.apple.TextEdit", mode: .hold))
    #expect(machine.state == .recording(targetApplication: "com.apple.TextEdit"))
    #expect(machine.session?.mode == .hold)
    #expect(machine.session?.targetApplication == "com.apple.TextEdit")

    try machine.apply(.updateAudioLevel(0.5))
    #expect(machine.session?.audioLevel == 0.5)

    try machine.apply(.stop)
    #expect(machine.state == .processing)
    #expect(machine.session?.endedAt != nil)
    #expect(machine.session?.audioLevel == 0)

    try machine.apply(.finish("Hello world."))
    #expect(machine.state == .inserting)
    #expect(machine.session?.finalTranscript == "Hello world.")

    try machine.apply(.inserted)
    #expect(machine.state == .completed)

    try machine.apply(.reset)
    #expect(machine.state == .idle)
    #expect(machine.session == nil)
  }

  @Test("Toggle mode is recorded on the session")
  func toggleMode() throws {
    var machine = DictationStateMachine()
    try machine.apply(.start(targetApplication: nil, mode: .toggle))
    #expect(machine.session?.mode == .toggle)
  }

  @Test("Audio level is clamped to 0...1")
  func audioLevelClamped() throws {
    var machine = DictationStateMachine()
    try machine.apply(.start(targetApplication: nil, mode: .hold))
    try machine.apply(.updateAudioLevel(3.5))
    #expect(machine.session?.audioLevel == 1)
    try machine.apply(.updateAudioLevel(-2))
    #expect(machine.session?.audioLevel == 0)
  }

  @Test("Cancel from recording and from processing marks session cancelled")
  func cancelPaths() throws {
    for stopFirst in [false, true] {
      var machine = DictationStateMachine()
      try machine.apply(.start(targetApplication: nil, mode: .hold))
      if stopFirst { try machine.apply(.stop) }
      try machine.apply(.cancel)
      #expect(machine.state == .cancelled)
      #expect(machine.session?.wasCancelled == true)
      #expect(machine.session?.finalTranscript == nil)
      try machine.apply(.reset)
      #expect(machine.state == .idle)
    }
  }

  @Test("Failure from recording, processing, and inserting carries the message")
  func failurePaths() throws {
    // recording → fail
    var a = DictationStateMachine()
    try a.apply(.start(targetApplication: nil, mode: .hold))
    try a.apply(.fail("mic disconnected"))
    #expect(a.state == .failed(message: "mic disconnected"))

    // processing → fail
    var b = DictationStateMachine()
    try b.apply(.start(targetApplication: nil, mode: .hold))
    try b.apply(.stop)
    try b.apply(.fail("engine error"))
    #expect(b.state == .failed(message: "engine error"))

    // inserting → fail (insertion itself failed; text is preserved on session)
    var c = DictationStateMachine()
    try c.apply(.start(targetApplication: nil, mode: .hold))
    try c.apply(.stop)
    try c.apply(.finish("kept text"))
    try c.apply(.fail("no focused field"))
    #expect(c.state == .failed(message: "no focused field"))
    #expect(c.session?.finalTranscript == "kept text")
  }

  @Test("Restart is allowed from completed, cancelled, and failed")
  func restartFromTerminalStates() throws {
    var machine = DictationStateMachine()
    // completed → start
    try machine.apply(.start(targetApplication: nil, mode: .hold))
    try machine.apply(.stop)
    try machine.apply(.finish("x"))
    try machine.apply(.inserted)
    try machine.apply(.start(targetApplication: "a", mode: .toggle))
    #expect(machine.state == .recording(targetApplication: "a"))
    // cancelled → start
    try machine.apply(.cancel)
    try machine.apply(.start(targetApplication: nil, mode: .hold))
    #expect(machine.state == .recording(targetApplication: nil))
    // failed → start
    try machine.apply(.fail("boom"))
    try machine.apply(.start(targetApplication: nil, mode: .hold))
    #expect(machine.state == .recording(targetApplication: nil))
  }

  @Test(
    "Invalid transitions throw",
    arguments: [
      // (events to reach the state, then the invalid event)
      ([DictationEvent](), DictationEvent.stop),
      ([], .finish("x")),
      ([], .cancel),
      ([], .inserted),
      ([], .reset),
      ([], .updateAudioLevel(0.5)),
      ([.start(targetApplication: nil, mode: .hold)], .start(targetApplication: nil, mode: .hold)),
      ([.start(targetApplication: nil, mode: .hold)], .finish("x")),
      ([.start(targetApplication: nil, mode: .hold)], .inserted),
      ([.start(targetApplication: nil, mode: .hold)], .reset),
      ([.start(targetApplication: nil, mode: .hold), .stop], .stop),
      ([.start(targetApplication: nil, mode: .hold), .stop], .inserted),
      ([.start(targetApplication: nil, mode: .hold), .stop], .updateAudioLevel(0.2)),
      ([.start(targetApplication: nil, mode: .hold), .stop, .finish("x")], .stop),
      ([.start(targetApplication: nil, mode: .hold), .stop, .finish("x")], .finish("y")),
      ([.start(targetApplication: nil, mode: .hold), .stop, .finish("x")], .cancel),
      ([.start(targetApplication: nil, mode: .hold), .stop, .finish("x"), .inserted], .stop),
      ([.start(targetApplication: nil, mode: .hold), .stop, .finish("x"), .inserted], .inserted),
    ])
  func invalidTransitions(setup: [DictationEvent], invalid: DictationEvent) throws {
    var machine = DictationStateMachine()
    for event in setup { try machine.apply(event) }
    #expect(throws: DictationTransitionError.self) {
      try machine.apply(invalid)
    }
  }
}
