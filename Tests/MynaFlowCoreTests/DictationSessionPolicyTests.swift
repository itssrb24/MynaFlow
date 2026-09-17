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
    #expect(policy.handle(.startSucceeded) == [.startCapture])
    #expect(policy.phase == .recording(.hold))
    #expect(policy.handle(.holdUp) == [.stopCapture])
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

    var starting = DictationSessionPolicy()
    _ = starting.handle(.holdDown)
    #expect(starting.handle(.cancel) == [.cancelController, .hideIndicator])
    #expect(starting.phase == .idle)
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
