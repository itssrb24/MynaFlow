import Foundation

/// The eight setup steps, in the order they are shown.
public enum OnboardingStep: Int, CaseIterable, Sendable {
  case welcome, microphone, accessibility, input, typingSpeed, polishModel, hotkeys,
    firstDictation

  public var title: String {
    switch self {
    case .welcome: "Welcome"
    case .microphone: "Microphone"
    case .accessibility: "Accessibility"
    case .input: "Input"
    case .typingSpeed: "Typing speed"
    case .polishModel: "Polish model"
    case .hotkeys: "Hotkeys"
    case .firstDictation: "First dictation"
    }
  }
}

/// Decides which setup steps may advance.
///
/// Pure, so the rule this exists to defend — *nobody is ever trapped in setup* —
/// is testable without a window, a permission, or AppKit.
///
/// That rule is not theoretical. `AXIsProcessTrusted()` is cached per process: an
/// app that launched untrusted keeps answering `false` even after the user turns
/// the permission on, until it is relaunched. A gate that only opens on a `true`
/// from that call can therefore never open, however many times the user grants
/// the permission. Hence `accessibilityDeferred`, and hence the relaunch the view
/// offers alongside it.
public enum OnboardingGate {
  public struct State: Equatable, Sendable {
    public var microphoneGranted: Bool
    public var accessibilityGranted: Bool
    /// The user chose to move on without Accessibility, knowing dictation will
    /// land in the scratchpad until it is granted.
    public var accessibilityDeferred: Bool
    public var firstDictationSucceeded: Bool
    /// The user chose to finish without a working dictation.
    public var dictationDeferred: Bool

    public init(
      microphoneGranted: Bool = false,
      accessibilityGranted: Bool = false,
      accessibilityDeferred: Bool = false,
      firstDictationSucceeded: Bool = false,
      dictationDeferred: Bool = false
    ) {
      self.microphoneGranted = microphoneGranted
      self.accessibilityGranted = accessibilityGranted
      self.accessibilityDeferred = accessibilityDeferred
      self.firstDictationSucceeded = firstDictationSucceeded
      self.dictationDeferred = dictationDeferred
    }
  }

  /// Whether Continue may move on from this step.
  public static func canAdvance(from step: OnboardingStep, state: State) -> Bool {
    switch step {
    case .microphone: state.microphoneGranted
    case .accessibility: state.accessibilityGranted || state.accessibilityDeferred
    default: true
    }
  }

  /// Whether to offer a way past this step without satisfying it. Only where
  /// someone could otherwise be stuck with no way forward and no way out.
  public static func offersDeferral(at step: OnboardingStep, state: State) -> Bool {
    step == .accessibility && !state.accessibilityGranted
  }

  /// Whether Finish may close setup.
  public static func canFinish(state: State) -> Bool {
    state.firstDictationSucceeded || state.dictationDeferred
  }
}
