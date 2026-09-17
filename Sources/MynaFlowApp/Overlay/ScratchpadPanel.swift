import AppKit
import MynaFlowCore
import SwiftUI

/// The "dictated at the wrong moment" recovery, turned into a place to work:
/// a small floating note holding the text, with paste / copy / polish.
@MainActor
@Observable
final class ScratchpadModel {
  var text = ""
  /// Display name of the app the text will be pasted into, when known.
  var targetName: String?
  var styles: [Style] = []
  var polishAvailable = false
  var busyStyle: String?
  var onPaste: () -> Void = {}
  var onCopy: () -> Void = {}
  var onPolish: (Style) -> Void = { _ in }
  var onClose: () -> Void = {}
}

/// A non-activating panel that can still take keyboard focus, so the note is
/// editable without bringing Myna Flow forward and stealing the user's app.
private final class KeyablePanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

@MainActor
final class ScratchpadPanelController {
  private let panel: NSPanel

  init(model: ScratchpadModel) {
    panel = KeyablePanel(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
      styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false)
    panel.title = "Scratchpad"
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.backgroundColor = NSColor(Theme.Colors.base)
    panel.setFrameAutosaveName("MynaFlowScratchpad")
    panel.contentView = NSHostingView(rootView: ScratchpadView(model: model))
    panel.minSize = NSSize(width: 320, height: 200)
    if !panel.setFrameUsingName("MynaFlowScratchpad") {
      panel.center()
    }
  }

  var isVisible: Bool { panel.isVisible }

  func show() {
    panel.makeKeyAndOrderFront(nil)
  }

  func hide() {
    panel.orderOut(nil)
  }
}

struct ScratchpadView: View {
  @Bindable var model: ScratchpadModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack {
        Text("Scratchpad").font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.textPrimary)
        if let name = model.targetName {
          Text("from \(name)").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
        }
        Spacer()
        if let busy = model.busyStyle {
          ProgressView().controlSize(.mini)
          Text("Polishing — \(busy)").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
        }
      }
      TextEditor(text: $model.text)
        .font(Theme.Fonts.body)
        .foregroundStyle(Theme.Colors.textPrimary)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
        .inset(padding: Theme.Spacing.sm)
        .disabled(model.busyStyle != nil)
      HStack(spacing: Theme.Spacing.sm) {
        Button(model.targetName.map { "Paste into \($0)" } ?? "Paste at cursor") { model.onPaste() }
          .buttonStyle(NeuButtonStyle(prominent: true))
          .disabled(model.text.isEmpty || model.busyStyle != nil)
        Button("Copy") { model.onCopy() }
          .buttonStyle(NeuButtonStyle())
          .disabled(model.text.isEmpty)
        Menu("Polish") {
          ForEach(model.styles) { style in
            Button(style.name) { model.onPolish(style) }
          }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(Theme.Colors.textSecondary)
        .disabled(!model.polishAvailable || model.text.isEmpty || model.busyStyle != nil)
        Spacer()
        Button("Close") { model.onClose() }
          .buttonStyle(NeuButtonStyle())
          .keyboardShortcut(.cancelAction)
      }
      .font(Theme.Fonts.caption)
    }
    .padding(Theme.Spacing.md)
    .padding(.top, Theme.Spacing.sm)
    .background(Theme.Colors.base)
    .preferredColorScheme(.dark)
  }
}
