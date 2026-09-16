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

    Window("Myna Flow", id: "main") {
      MainWindowView(coordinator: coordinator)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .defaultSize(width: 980, height: 660)
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
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Start Dictation (hold \(coordinator.hotkeyConfiguration[.dictationHold]?.keycapLabel ?? "unbound"))") {
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
      Menu("Polish styles") {
        ForEach(coordinator.styles) { style in
          if let slot = style.hotkeySlot {
            Text("\(style.name)  ·  slot \(slot)")
          } else {
            Text(style.name)
          }
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
  }

  private func menuTitle(for record: DictationRecord) -> String {
    let text = record.finalText
    return text.count > 48 ? String(text.prefix(48)) + "…" : text
  }
}
