import Testing

@testable import MynaFlowCore

@Suite("Onboarding gate")
struct OnboardingGateTests {
  @Test("The microphone step waits for the microphone")
  func microphoneStep() {
    #expect(!OnboardingGate.canAdvance(from: .microphone, state: .init()))
    #expect(
      OnboardingGate.canAdvance(from: .microphone, state: .init(microphoneGranted: true)))
  }

  @Test("The accessibility step waits for accessibility")
  func accessibilityStep() {
    #expect(!OnboardingGate.canAdvance(from: .accessibility, state: .init()))
    #expect(
      OnboardingGate.canAdvance(from: .accessibility, state: .init(accessibilityGranted: true)))
  }

  @Test("A granted permission that is revoked closes the gate again")
  func revocationClosesTheGate() {
    // The gate reads current state rather than latching, so a permission pulled
    // away in System Settings is reflected the moment the state refreshes.
    var state = OnboardingGate.State(accessibilityGranted: true)
    #expect(OnboardingGate.canAdvance(from: .accessibility, state: state))
    state.accessibilityGranted = false
    #expect(!OnboardingGate.canAdvance(from: .accessibility, state: state))
  }

  @Test("Deferring accessibility opens the gate without granting anything")
  func deferralOpensTheGate() {
    // Nobody may be trapped in setup. AXIsProcessTrusted() is cached per
    // process, so a user who has genuinely granted the permission can still
    // read as untrusted until relaunch — without this they could never leave.
    let deferred = OnboardingGate.State(accessibilityGranted: false, accessibilityDeferred: true)
    #expect(OnboardingGate.canAdvance(from: .accessibility, state: deferred))
  }

  @Test("Deferral is offered only where someone could otherwise be stuck")
  func deferralOfferedOnlyWhenBlocked() {
    #expect(OnboardingGate.offersDeferral(at: .accessibility, state: .init()))
    // Once it is granted there is nothing to defer.
    #expect(
      !OnboardingGate.offersDeferral(at: .accessibility, state: .init(accessibilityGranted: true)))
    #expect(!OnboardingGate.offersDeferral(at: .microphone, state: .init()))
    #expect(!OnboardingGate.offersDeferral(at: .welcome, state: .init()))
  }

  @Test("Every other step advances freely")
  func otherStepsAdvance() {
    for step in OnboardingStep.allCases where step != .microphone && step != .accessibility {
      #expect(
        OnboardingGate.canAdvance(from: step, state: .init()),
        "\(step) should not gate")
    }
  }

  @Test("Finishing waits for a real dictation, but can be deferred")
  func finishing() {
    #expect(!OnboardingGate.canFinish(state: .init()))
    #expect(OnboardingGate.canFinish(state: .init(firstDictationSucceeded: true)))
    // A broken microphone must not make setup impossible to leave.
    #expect(OnboardingGate.canFinish(state: .init(dictationDeferred: true)))
  }

  @Test("The step order is the one the view renders")
  func stepOrder() {
    #expect(
      OnboardingStep.allCases.map(\.title) == [
        "Welcome", "Microphone", "Accessibility", "Input", "Typing speed", "Polish model",
        "Hotkeys", "First dictation",
      ])
  }
}
