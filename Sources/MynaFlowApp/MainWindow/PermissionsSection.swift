import AppKit
import MynaFlowCore
import SwiftUI

/// What macOS actually granted this copy, and what else is installed under the
/// same name. The screenshot that replaces a debugging session.
struct PermissionsSection: View {
  let coordinator: AppCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      SectionLabel(text: "Permissions")
      row("Microphone", granted: coordinator.microphoneGranted) { coordinator.openMicrophoneSettings() }
      row("Accessibility", granted: coordinator.accessibilityGranted) { coordinator.openAccessibilitySettings() }
      row("Input Monitoring", granted: coordinator.inputMonitoringGranted) { coordinator.openInputMonitoringSettings() }

      if !coordinator.accessibilityGranted {
        HStack(spacing: Theme.Spacing.sm) {
          Text("Accessibility shows what this running copy sees. If System Settings disagrees, quit and reopen Myna Flow.")
            .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
          Button("Relaunch") { coordinator.relaunch() }.buttonStyle(NeuButtonStyle())
        }
      }

      if let me = coordinator.selfIdentity {
        Text("\(me.bundlePath) · \(me.version ?? "?") (\(me.build ?? "?")) · \(me.authority.first ?? me.summary) · \(me.shortFingerprint)")
          .font(Theme.Fonts.mono).foregroundStyle(Theme.Colors.textTertiary)
          .textSelection(.enabled)
      }

      if !coordinator.otherCopies.isEmpty {
        SectionLabel(text: "Other copies")
        ForEach(coordinator.otherCopies, id: \.bundlePath) { copy in
          let differs = !(coordinator.selfIdentity?.parsedRequirement.map { mine in
            copy.parsedRequirement.map { mine.sameIdentity(as: $0) } ?? false
          } ?? false)
          HStack(spacing: Theme.Spacing.sm) {
            Text("\(copy.bundlePath) · \(copy.summary)")
              .font(Theme.Fonts.mono)
              .foregroundStyle(differs ? Theme.Colors.warning : Theme.Colors.textTertiary)
              .textSelection(.enabled)
            Spacer()
            Button("Reveal") {
              NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: copy.bundlePath)])
            }
            .buttonStyle(NeuButtonStyle())
          }
        }
      }

      ForEach(coordinator.currentPermissionSnapshot().findings, id: \.text) { finding in
        Text(finding.text)
          .font(Theme.Fonts.caption)
          .foregroundStyle(finding.severity == .warning ? Theme.Colors.warning : Theme.Colors.textTertiary)
      }

      HStack(spacing: Theme.Spacing.sm) {
        Button("Copy report") { coordinator.copyPermissionReport() }.buttonStyle(NeuButtonStyle())
        Button("Refresh") {
          coordinator.refreshPermissions()
          coordinator.refreshInstalledCopies()
        }
        .buttonStyle(NeuButtonStyle())
      }
    }
    .raised()
    .task { coordinator.refreshInstalledCopies() }
  }

  private func row(_ name: String, granted: Bool, open: @escaping () -> Void) -> some View {
    HStack(spacing: Theme.Spacing.sm) {
      Image(systemName: "circle.fill")
        .font(.system(size: 8))
        .foregroundStyle(granted ? Theme.Colors.success : Theme.Colors.danger)
      Text(name).font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.textPrimary)
      Text(granted ? "granted" : "off").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
      Spacer()
      Button("Open settings…", action: open).buttonStyle(NeuButtonStyle())
    }
  }
}
