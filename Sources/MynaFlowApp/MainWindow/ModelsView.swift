import MynaFlowCore
import SwiftUI

struct ModelsView: View {
  let coordinator: AppCoordinator

  private var hardware: HardwareProfile { coordinator.hardware }

  var body: some View {
    Page(title: "Models", subtitle: "Dictation needs nothing downloaded. Everything here is optional and explicit.") {
      HStack(spacing: Theme.Spacing.lg) {
        stat("Memory", ByteCountFormatter.string(fromByteCount: hardware.memoryBytes, countStyle: .memory))
        stat("Free disk", ByteCountFormatter.string(fromByteCount: hardware.freeDiskBytes, countStyle: .file))
        stat("Chip", SystemInfoReader.hardwareModel())
      }

      VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        SectionLabel(text: "Speech engines")
        engineRow(
          name: "Apple Speech", detail: "Built into macOS. Fast, no download. Always the fallback.",
          trailing: {
            Text(coordinator.engineChoice == .apple ? "In use" : "Fallback")
              .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textSecondary)
          })
        engineRow(
          name: "Parakeet",
          detail: "FluidAudio's Parakeet on the Neural Engine. Better on names and jargon. ~600 MB.",
          trailing: { parakeetControls })
        if coordinator.parakeetInstalled {
          engineRow(
            name: "Vocabulary boosting for Parakeet",
            detail: "Lets Parakeet honor your Vocabulary terms (Apple Speech already does). Separate ~\(ParakeetEngine.approximateBoostingMegabytes) MB download.",
            trailing: { boostingControls })
        }
      }
      .raised()

      VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        SectionLabel(text: "Polish language model")
        Text("Only polish needs this. Recommended: \(SetupAdvisor.largestRunnableLanguageModel(on: hardware)?.displayName ?? "none fits this Mac"). Loads on first polish, unloads after 5 idle minutes.")
          .font(Theme.Fonts.caption)
          .foregroundStyle(Theme.Colors.textTertiary)
        ForEach(DefaultModelCatalog.language) { descriptor in
          modelRow(descriptor)
        }
      }
      .raised()
    }
    .task { await coordinator.refreshModelStates() }
  }

  private func stat(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      SectionLabel(text: label)
      Text(value).font(Theme.Fonts.title).foregroundStyle(Theme.Colors.textPrimary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .raised(padding: Theme.Spacing.md)
  }

  private func engineRow<Trailing: View>(
    name: String, detail: String, @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    HStack(alignment: .center, spacing: Theme.Spacing.md) {
      VStack(alignment: .leading, spacing: 2) {
        Text(name).font(Theme.Fonts.bodyStrong).foregroundStyle(Theme.Colors.textPrimary)
        Text(detail).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.textTertiary)
      }
      Spacer()
      trailing()
    }
  }

  @ViewBuilder
  private var parakeetControls: some View {
    if let fraction = coordinator.parakeetDownloadFraction {
      ProgressView(value: fraction).frame(width: 120)
    } else if coordinator.parakeetInstalled {
      HStack(spacing: Theme.Spacing.sm) {
        Button(coordinator.engineChoice == .parakeet ? "In use" : "Use") {
          Task { await coordinator.setEngine(.parakeet) }
        }
        .buttonStyle(NeuButtonStyle(prominent: coordinator.engineChoice != .parakeet))
        .disabled(coordinator.engineChoice == .parakeet)
        if coordinator.engineChoice == .parakeet {
          Button("Use Apple") { Task { await coordinator.setEngine(.apple) } }
            .buttonStyle(NeuButtonStyle())
        }
        Button("Remove") { coordinator.removeParakeet() }
          .buttonStyle(NeuButtonStyle(destructive: true))
      }
    } else {
      Button("Install") { coordinator.installParakeet() }
        .buttonStyle(NeuButtonStyle(prominent: true))
    }
  }

  @ViewBuilder
  private var boostingControls: some View {
    if coordinator.boostingInstalling {
      ProgressView().controlSize(.small)
    } else if coordinator.boostingInstalled {
      HStack(spacing: Theme.Spacing.sm) {
        Text("Installed").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.success)
        Button("Remove") { coordinator.removeBoosting() }
          .buttonStyle(NeuButtonStyle(destructive: true))
      }
    } else {
      Button("Install") { coordinator.installBoosting() }
        .buttonStyle(NeuButtonStyle(prominent: true))
    }
  }

  private func modelRow(_ descriptor: ModelDescriptor) -> some View {
    let state = coordinator.modelStates[descriptor.id] ?? .notInstalled
    let availability = SetupAdvisor.availability(of: descriptor, on: hardware)
    let selected = coordinator.polishModel?.id == descriptor.id
    return HStack(alignment: .center, spacing: Theme.Spacing.md) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: Theme.Spacing.sm) {
          Text(descriptor.displayName).font(Theme.Fonts.bodyStrong)
            .foregroundStyle(Theme.Colors.textPrimary)
          Text(descriptor.tier).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.accent)
        }
        Text("\(descriptor.sizeLabel) download · \(availabilityText(availability))")
          .font(Theme.Fonts.caption)
          .foregroundStyle(Theme.Colors.textTertiary)
      }
      Spacer()
      switch state {
      case .downloading(let received, let total):
        VStack(alignment: .trailing, spacing: 2) {
          ProgressView(value: Double(received), total: Double(max(total, 1))).frame(width: 140)
          Button("Cancel") { coordinator.cancelModelInstall() }
            .buttonStyle(.plain).font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.textTertiary)
        }
      case .checkingDisk, .verifying, .paused:
        ProgressView().controlSize(.small)
      case .installed:
        HStack(spacing: Theme.Spacing.sm) {
          Button(selected ? "In use" : "Use") { Task { await coordinator.selectPolishModel(descriptor) } }
            .buttonStyle(NeuButtonStyle(prominent: !selected))
            .disabled(selected)
          Button("Remove") { Task { await coordinator.removeModel(descriptor) } }
            .buttonStyle(NeuButtonStyle(destructive: true))
        }
      case .notInstalled, .failed:
        VStack(alignment: .trailing, spacing: 2) {
          Button("Install") { coordinator.installModel(descriptor) }
            .buttonStyle(NeuButtonStyle(prominent: availability == .recommended))
            .disabled(availability != .recommended)
          if case .failed(let message) = state {
            Text(message).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.danger)
              .lineLimit(2).frame(maxWidth: 240)
          }
        }
      }
    }
  }

  private func availabilityText(_ availability: ModelAvailability) -> String {
    switch availability {
    case .recommended: "fits this Mac"
    case .insufficientMemory(let needs):
      "needs \(ByteCountFormatter.string(fromByteCount: needs, countStyle: .memory)) RAM"
    case .insufficientDisk(let needs):
      "needs \(ByteCountFormatter.string(fromByteCount: needs, countStyle: .file)) free"
    }
  }
}
