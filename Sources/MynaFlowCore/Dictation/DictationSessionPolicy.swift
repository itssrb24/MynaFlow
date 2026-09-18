import Foundation

/// The app-side dictation lifecycle as a pure state table: which hotkey and
/// system events do what, given what is already in flight. The app layer
/// executes the returned effects (capture, timers, indicator); nothing here
/// touches AppKit, so every edge case is a unit test.
public struct DictationSessionPolicy: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case idle
    /// `startDictation` is in flight on the controller.
    case starting(DictationMode)
    case recording(DictationMode)
    /// The user let go before the start resolved; cancel once it does.
    case abandoned
    /// Capture is stopping; frames will be handed to the controller.
    case finishing
  }

  public enum Input: Equatable, Sendable {
    case holdDown, holdUp
    case togglePressed
    /// Menu bar "Start Dictation" — always toggle semantics so it can stop.
    case menuStart
    case cancel
    case startSucceeded, startFailed
    case captureFinished
    case autoStop
    case deviceLost
  }

  public enum Effect: Equatable, Sendable {
    case beginStart(DictationMode)
    case startCapture
    case stopCapture
    case cancelController
    case armAutoStop
    case disarmAutoStop
    case hideIndicator
    /// The controller refused (e.g. still processing the previous one): the
    /// app decides whether to keep the current indicator or hide it.
    case startFailedIndicator
    case notifyDeviceLost
  }

  public private(set) var phase: Phase = .idle

  public init() {}

  public var isIdle: Bool { phase == .idle }

  public mutating func handle(_ input: Input) -> [Effect] {
    switch (phase, input) {
    // Starting
    case (.idle, .holdDown):
      phase = .starting(.hold)
      return [.beginStart(.hold)]
    case (.idle, .togglePressed), (.idle, .menuStart):
      phase = .starting(.toggle)
      return [.beginStart(.toggle)]
    case (.starting(let mode), .startSucceeded):
      phase = .recording(mode)
      // Hold is armed too. Its key-up can simply never arrive — secure input
      // engaging mid-hold, a Command-Tab eating the edge, the display sleeping
      // — and without a cap the microphone stays open until the app is quit.
      return [.startCapture, .armAutoStop]
    case (.starting, .startFailed):
      phase = .idle
      return [.startFailedIndicator]
    case (.starting(.hold), .holdUp), (.starting(.toggle), .togglePressed),
      (.starting(.toggle), .menuStart):
      phase = .abandoned
      return []
    case (.abandoned, .startSucceeded):
      phase = .idle
      return [.cancelController, .hideIndicator]
    case (.abandoned, .startFailed):
      phase = .idle
      return [.hideIndicator]

    // Recording
    case (.recording(.hold), .holdUp):
      phase = .finishing
      return [.disarmAutoStop, .stopCapture]
    case (.recording(.toggle), .togglePressed), (.recording(.toggle), .menuStart):
      phase = .finishing
      return [.disarmAutoStop, .stopCapture]
    case (.recording, .autoStop):
      phase = .finishing
      return [.stopCapture]
    case (.recording, .deviceLost):
      phase = .finishing
      return [.stopCapture, .notifyDeviceLost]

    // Cancel
    case (.idle, .cancel), (.finishing, .cancel):
      return []
    // The controller is still inside startDictation here, suspended on an
    // Accessibility call into another app. Cancelling it now would find it
    // still idle and do nothing, and it would then come up recording with
    // nobody listening — dictation dead until relaunch. Wait for the start to
    // land, which is exactly what `.abandoned` already does.
    case (.starting, .cancel):
      phase = .abandoned
      return [.hideIndicator]
    case (.abandoned, .cancel):
      return [.hideIndicator]
    case (.recording, .cancel):
      phase = .idle
      return [.disarmAutoStop, .stopCapture, .cancelController, .hideIndicator]

    // Finishing
    case (.finishing, .captureFinished):
      phase = .idle
      return []

    default:
      return []
    }
  }
}
