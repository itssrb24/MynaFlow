import MynaFlowCore
import SwiftUI

/// Quit hook: SwiftUI has no scene-level terminate callback, so the
/// delegate stops the model server and closes the database.
final class AppDelegate: NSObject, NSApplicationDelegate {
  var coordinator: AppCoordinator?

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let coordinator else { return .terminateNow }
    Task { @MainActor in
      await coordinator.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

@main
struct MynaFlowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var coordinator = AppCoordinator()
  @State private var booted = false

  var body: some Scene {
    MenuBarExtra {
      MenuBarMenu(coordinator: coordinator)
    } label: {
      // The label is rendered as soon as the status item appears, so it is
      // the reliable boot hook; the menu content only exists when opened.
      BootLabel(symbol: menuBarSymbol) {
        guard !booted else { return false }
        booted = true
        appDelegate.coordinator = coordinator
        await coordinator.start()
        return coordinator.needsOnboarding
      }
    }
    .menuBarExtraStyle(.menu)

    Window("Myna Flow", id: "main") {
      MainWindowView(coordinator: coordinator)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .defaultSize(width: 980, height: 660)

    Window("Welcome to Myna Flow", id: "onboarding") {
      OnboardingView(coordinator: coordinator)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)
  }

  private var menuBarSymbol: String {
    switch coordinator.menuBarState {
    case .idle: "mic"
    case .recording: "mic.fill"
    case .processing: "waveform"
    }
  }
}

/// Menu bar icon that also boots the app and opens onboarding on first run.
private struct BootLabel: View {
  let symbol: String
  let boot: () async -> Bool
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Image(systemName: symbol)
      .task {
        if await boot() {
          openWindow(id: "onboarding")
          NSApp.activate(ignoringOtherApps: true)
        }
      }
  }
}

struct MenuBarMenu: View {
  let coordinator: AppCoordinator
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    if let recovered = coordinator.recoveredDatabaseURL {
      Button("History database was reset — reveal the old file (\(recovered.lastPathComponent))") {
        coordinator.revealRecoveredDatabase()
      }
      Divider()
    }
    Text(coordinator.speechStatusLine)
    Text(coordinator.modelsStatusLine)
    Divider()
    Button(coordinator.menuBarState == .recording
      ? "Stop Dictation"
      : "Start Dictation (or hold \(coordinator.hotkeyConfiguration[.dictationHold]?.keycapLabel ?? "unbound"))") {
      coordinator.toggleDictationFromMenu()
    }
    if coordinator.menuBarState != .idle {
      Button("Cancel Dictation") { coordinator.cancelDictation() }
    }
    Button("Re-insert Last Dictation") { coordinator.reinsertLast() }
      .disabled(coordinator.recentDictations.isEmpty)
    Button("Undo Last Dictation") { coordinator.undoLastDictation() }
    Divider()
    if coordinator.recentDictations.isEmpty {
      Text("No dictations yet")
    } else {
      Menu("Recent") {
        ForEach(coordinator.recentDictations) { record in
          Button(menuTitle(for: record)) {
            coordinator.copyToClipboard(record.finalText)
          }
        }
      }
    }
    Divider()
    if coordinator.parakeetInstalled {
      Menu("Engine: \(coordinator.engineChoice == .parakeet ? "Parakeet" : "Apple Speech")") {
        Button("Apple Speech") {
          Task { await coordinator.setEngine(.apple) }
        }
        Button("Parakeet (higher accuracy)") {
          Task { await coordinator.setEngine(.parakeet) }
        }
      }
    } else if let fraction = coordinator.parakeetDownloadFraction {
      Text("Downloading Parakeet… \(Int(fraction * 100))%")
    } else {
      Button("Install Parakeet Engine (~600 MB)") {
        coordinator.installParakeet()
      }
    }
    if coordinator.polishModelInstalled {
      Menu("Polish Selection") {
        ForEach(coordinator.styles) { style in
          Button(style.name) { coordinator.polishSelection(style: style) }
            .keyboardShortcutLabel(
              style.hotkeySlot.flatMap { HotkeyAction.forSlot($0) }
                .flatMap { coordinator.hotkeyConfiguration[$0]?.keycapLabel })
        }
      }
    } else if let fraction = coordinator.polishDownloadFraction {
      Text("Downloading polish model… \(Int(fraction * 100))%")
    } else if let model = coordinator.polishModel {
      Button("Install Polish Model (\(model.displayName), \(model.sizeLabel))") {
        coordinator.installPolishModel()
      }
    }
    Divider()
    Button("Open Myna Flow…") {
      coordinator.showMainWindow { id in openWindow(id: id) }
    }
    .keyboardShortcut(",")
    Button("Quit Myna Flow") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
    Color.clear.frame(width: 0, height: 0)
      .task { await coordinator.refreshInstalledFlags() }
  }

  private func menuTitle(for record: DictationRecord) -> String {
    let text = record.finalText
    return text.count > 48 ? String(text.prefix(48)) + "…" : text
  }
}

extension View {
  /// Menus render a key hint after the title; a trailing label is the
  /// closest stable rendering for chords the system does not own.
  @ViewBuilder
  func keyboardShortcutLabel(_ label: String?) -> some View {
    if let label { self.help(label) } else { self }
  }
}
