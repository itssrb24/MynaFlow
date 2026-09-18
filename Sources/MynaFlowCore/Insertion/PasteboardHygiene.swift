import AppKit
import Foundation

/// The one door to `NSPasteboard.general` for dictated text. Every write
/// schedules a restore: if the pasteboard still holds exactly what we put
/// there when the window ends, the previous contents come back (or it is
/// cleared), so a dictation never lingers where any app can read it.
@MainActor
public enum PasteboardHygiene {
  public static let defaultWindow: Duration = .seconds(30)

  /// Clipboard managers — Maccy, Raycast, Alfred, Paste — snapshot the
  /// pasteboard on every change, so without these markers every dictation
  /// would be archived permanently in a third-party history and the whole
  /// restore-afterwards design would be pointless. Both are the community
  /// conventions those apps honour.
  private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
  private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

  /// Writes dictated text marked so clipboard histories skip it.
  @discardableResult
  public static func writeConcealed(_ text: String, to pasteboard: NSPasteboard) -> Bool {
    let item = NSPasteboardItem()
    guard item.setString(text, forType: .string) else { return false }
    item.setString("", forType: concealed)
    item.setString("", forType: transient)
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
  }
  private static var pending: Task<Void, Never>?

  @discardableResult
  public static func write(_ text: String, restoreAfter window: Duration = defaultWindow) -> Bool {
    pending?.cancel()
    let pasteboard = NSPasteboard.general
    let previous = pasteboard.string(forType: .string)
    guard writeConcealed(text, to: pasteboard) else { return false }
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
