import AppKit
import MynaFlowCore
import SwiftUI

struct HotkeyRecorder: View {
  let shortcut: HotkeyShortcut
  let onChange: (HotkeyShortcut) -> Void
  @State private var isCapturing = false

  var body: some View {
    Button {
      isCapturing.toggle()
    } label: {
      HStack(spacing: 7) {
        if isCapturing {
          Circle()
            .fill(.red)
            .frame(width: 7, height: 7)
          Text("Press shortcut…")
        } else {
          Text(shortcut.displayName)
        }
      }
      .font(.system(size: 13, weight: .semibold, design: .rounded))
      .frame(minWidth: 116)
    }
    .buttonStyle(.bordered)
    .background(
      HotkeyCaptureView(isCapturing: isCapturing) { captured in
        isCapturing = false
        onChange(captured)
      }
    )
    .accessibilityLabel(isCapturing ? "Press a new keyboard shortcut" : shortcut.displayName)
  }
}

private struct HotkeyCaptureView: NSViewRepresentable {
  let isCapturing: Bool
  let onCapture: (HotkeyShortcut) -> Void

  func makeNSView(context: Context) -> CaptureNSView {
    let view = CaptureNSView()
    view.onCapture = onCapture
    return view
  }

  func updateNSView(_ nsView: CaptureNSView, context: Context) {
    nsView.onCapture = onCapture
    guard isCapturing else {
      if nsView.window?.firstResponder === nsView {
        nsView.window?.makeFirstResponder(nil)
      }
      return
    }
    DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
  }

  final class CaptureNSView: NSView {
    var onCapture: ((HotkeyShortcut) -> Void)?
    /// Largest normalized modifier set observed during the current press.
    /// Committed as a modifier-only shortcut if all modifiers release without
    /// a character key arriving in between.
    private var pendingModifiers: UInt = 0

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
      // A real key arrived — this is a key shortcut, not a modifier-only hold.
      pendingModifiers = 0
      let modifiers = HotkeyShortcut.normalized(
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
      onCapture?(
        HotkeyShortcut(
          keyCode: event.keyCode,
          modifiers: modifiers,
          keyLabel: Self.label(for: event)
        ))
    }

    override func flagsChanged(with event: NSEvent) {
      let modifiers = HotkeyShortcut.normalized(
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
      if modifiers != 0 {
        // Track the deepest chord seen (⌃ → ⌃⌥ records ⌃⌥).
        pendingModifiers |= modifiers
      } else if pendingModifiers != 0 {
        // All modifiers released with no keyDown — commit as modifier-only.
        let captured = pendingModifiers
        pendingModifiers = 0
        onCapture?(HotkeyShortcut.modifierOnly(captured))
      }
    }

    private static func label(for event: NSEvent) -> String {
      switch event.keyCode {
      case 36: return "Return"
      case 48: return "Tab"
      case 49: return "Space"
      case 51: return "Delete"
      case 53: return "Esc"
      case 115: return "Home"
      case 116: return "Page Up"
      case 117: return "Forward Delete"
      case 119: return "End"
      case 121: return "Page Down"
      case 123: return "←"
      case 124: return "→"
      case 125: return "↓"
      case 126: return "↑"
      default:
        let value = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return value.isEmpty ? "Key \(event.keyCode)" : value
      }
    }
  }
}
