import AppKit
import Foundation

/// The one door to `NSPasteboard.general` for dictated text. Every write
/// schedules a restore: if the pasteboard still holds exactly what we put
/// there when the window ends, the previous contents come back (or it is
/// cleared), so a dictation never lingers where any app can read it.
@MainActor
public enum PasteboardHygiene {
  public static let defaultWindow: Duration = .seconds(30)
  private static var pending: Task<Void, Never>?

  @discardableResult
  public static func write(_ text: String, restoreAfter window: Duration = defaultWindow) -> Bool {
    pending?.cancel()
    let pasteboard = NSPasteboard.general
    let previous = pasteboard.string(forType: .string)
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else { return false }
    let changeCount = pasteboard.changeCount
    pending = Task {
      try? await Task.sleep(for: window)
      guard !Task.isCancelled else { return }
      let stillOurs = ClipboardCleanupPolicy.shouldRestore(
        current: pasteboard.string(forType: .string), expectedPayload: text,
        currentChangeCount: pasteboard.changeCount, expectedChangeCount: changeCount)
      guard stillOurs else { return }
      pasteboard.clearContents()
      if let previous { pasteboard.setString(previous, forType: .string) }
    }
    return true
  }
}
