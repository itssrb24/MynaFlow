import MynaFlowCore
import SwiftUI

@main
struct MynaFlowApp: App {
  @State private var coordinator = AppCoordinator()
  @State private var booted = false

  var body: some Scene {
    MenuBarExtra {
      MenuBarMenu(coordinator: coordinator)
    } label: {
      // The label is rendered as soon as the status item appears, so it is
      // the reliable boot hook; the menu content only exists when opened.
      Image(systemName: menuBarSymbol)
        .task {
          guard !booted else { return }
          booted = true
          await coordinator.start()
        }
    }
    .menuBarExtraStyle(.menu)
  }

  private var menuBarSymbol: String {
    switch coordinator.menuBarState {
    case .idle: "mic"
    case .recording: "mic.fill"
    case .processing: "waveform"
    }
  }
}

struct MenuBarMenu: View {
  let coordinator: AppCoordinator

  var body: some View {
    Button("Start Dictation (hold ⌘⇧Space)") {
      coordinator.beginDictation(mode: .hold)
    }
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
    Button("Quit Myna Flow") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }

  private func menuTitle(for record: DictationRecord) -> String {
    let text = record.finalText
    return text.count > 48 ? String(text.prefix(48)) + "…" : text
  }
}
