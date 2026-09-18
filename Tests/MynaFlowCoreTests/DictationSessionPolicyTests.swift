import Foundation
import Testing

@testable import MynaFlowCore

@Suite("DictationSessionPolicy")
struct DictationSessionPolicyTests {
  @Test("Hold: down starts, success captures, up finishes, capture end idles")
  func holdHappyPath() {
    var policy = DictationSessionPolicy()
    #expect(policy.handle(.holdDown) == [.beginStart(.hold)])
    #expect(policy.phase == .starting(.hold))
    #expect(policy.handle(.startSucceeded) == [.startCapture, .armAutoStop])
    #expect(policy.phase == .recording(.hold))
    #expect(policy.handle(.holdUp) == [.disarmAutoStop, .stopCapture])
    #expect(policy.phase == .finishing)
    #expect(policy.handle(.captureFinished) == [])
    #expect(policy.phase == .idle)
  }

  @Test("Toggle: press starts and arms auto-stop; second press finishes")
  func toggleHappyPath() {
    var policy = DictationSessionPolicy()
    #expect(policy.handle(.togglePressed) == [.beginStart(.toggle)])
    #expect(policy.handle(.startSucceeded) == [.startCapture, .armAutoStop])
    #expect(policy.handle(.togglePressed) == [.disarmAutoStop, .stopCapture])
    #expect(policy.phase == .finishing)
  }

  @Test("Menu start is toggle semantics: it can always be stopped")
  func menuStartIsToggle() {
    var policy = DictationSessionPolicy()
    #expect(policy.handle(.menuStart) == [.beginStart(.toggle)])
    _ = policy.handle(.startSucceeded)
    #expect(policy.handle(.menuStart) == [.disarmAutoStop, .stopCapture])
  }

  @Test("Auto-stop finishes a toggle session")
  func autoStop() {
    var policy = DictationSessionPolicy()
    _ = policy.handle(.togglePressed)
    _ = policy.handle(.startSucceeded)
    #expect(policy.handle(.autoStop) == [.stopCapture])
    #expect(policy.phase == .finishing)
  }

  @Test("Key-up before the start resolves abandons cleanly — no open mic")
  func earlyRelease() {
    var policy = DictationSessionPolicy()
    _ = policy.handle(.holdDown)
    #expect(policy.handle(.holdUp) == [])
    #expect(policy.phase == .abandoned)
    #expect(policy.handle(.startSucceeded) == [.cancelController, .hideIndicator])
    #expect(policy.phase == .idle)
  }

  @Test("A failed start never latches: toggle works again immediately")
  func failedStartDoesNotLatch() {
    var policy = DictationSessionPolicy()
    _ = policy.handle(.togglePressed)
    #expect(policy.handle(.startFailed) == [.startFailedIndicator])
    #expect(policy.phase == .idle)
    #expect(policy.handle(.togglePressed) == [.beginStart(.toggle)])
  }

  @Test("Cancel while idle is a no-op (bare Esc must not touch capture)")
  func cancelWhileIdle() {
    var policy = DictationSessionPolicy()
    #expect(policy.handle(.cancel) == [])
    #expect(policy.phase == .idle)
  }

  @Test("Cancel while recording or starting tears everything down")
  func cancelLive() {
    var recording = DictationSessionPolicy()
    _ = recording.handle(.togglePressed)
    _ = recording.handle(.startSucceeded)
    #expect(recording.handle(.cancel) == [.disarmAutoStop, .stopCapture, .cancelController, .hideIndicator])
    #expect(recording.phase == .idle)

    // Cancelling mid-start must NOT cancel the controller yet: it is still
    // inside startDictation and would see itself idle, then come up recording
    // with the session already idle — dictation dead until relaunch.
    var starting = DictationSessionPolicy()
    _ = starting.handle(.holdDown)
    #expect(starting.handle(.cancel) == [.hideIndicator])
    #expect(starting.phase == .abandoned)
    // The teardown happens when the start finally lands.
    #expect(starting.handle(.startSucceeded) == [.cancelController, .hideIndicator])
    #expect(starting.phase == .idle)
  }

  @Test("A start that fails after being cancelled just hides the indicator")
  func cancelThenStartFails() {
    var policy = DictationSessionPolicy()
    _ = policy.handle(.togglePressed)
    _ = policy.handle(.cancel)
    #expect(policy.phase == .abandoned)
    #expect(policy.handle(.startFailed) == [.hideIndicator])
    #expect(policy.phase == .idle)
  }

  @Test("Cancelling twice while starting stays abandoned rather than stranding")
  func doubleCancelWhileStarting() {
    var policy = DictationSessionPolicy()
    _ = policy.handle(.holdDown)
    _ = policy.handle(.cancel)
    #expect(policy.handle(.cancel) == [.hideIndicator])
    #expect(policy.phase == .abandoned)
    #expect(policy.handle(.startSucceeded) == [.cancelController, .hideIndicator])
  }

  @Test("Hold has a safety valve: a key-up that never arrives still stops")
  func holdAutoStops() {
    // Secure input, a Command-Tab, or a sleeping display can swallow the
    // key-up. Without the cap the microphone would stay open indefinitely.
    var policy = DictationSessionPolicy()
    _ = policy.handle(.holdDown)
    #expect(policy.handle(.startSucceeded).contains(.armAutoStop))
    #expect(policy.handle(.autoStop) == [.stopCapture])
    #expect(policy.phase == .finishing)
  }

  @Test("Hold pressed during a toggle session is ignored — indicator stays live")
  func holdDuringToggle() {
    var policy = DictationSessionPolicy()
    _ = policy.handle(.togglePressed)
    _ = policy.handle(.startSucceeded)
    #expect(policy.handle(.holdDown) == [])
    #expect(policy.handle(.holdUp) == [])
    #expect(policy.phase == .recording(.toggle))
  }

  @Test("Device lost mid-recording finishes with what was captured and says so")
  func deviceLost() {
    var policy = DictationSessionPolicy()
    _ = policy.handle(.holdDown)
    _ = policy.handle(.startSucceeded)
    #expect(policy.handle(.deviceLost) == [.stopCapture, .notifyDeviceLost])
    #expect(policy.phase == .finishing)
  }

  @Test("Inputs while finishing are ignored until capture ends")
  func finishingIgnores() {
    var policy = DictationSessionPolicy()
    _ = policy.handle(.holdDown)
    _ = policy.handle(.startSucceeded)
    _ = policy.handle(.holdUp)
    #expect(policy.handle(.holdDown) == [])
    #expect(policy.handle(.togglePressed) == [])
    #expect(policy.phase == .finishing)
    _ = policy.handle(.captureFinished)
    #expect(policy.handle(.holdDown) == [.beginStart(.hold)])
  }

  @Test("isIdle is the only time a controller swap is allowed")
  func idleness() {
    var policy = DictationSessionPolicy()
    #expect(policy.isIdle)
    _ = policy.handle(.holdDown)
    #expect(!policy.isIdle)
  }
}
