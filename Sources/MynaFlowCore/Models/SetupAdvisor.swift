import Foundation

/// What this Mac can actually run. Passed in rather than read globally so the
/// recommendation logic stays pure and testable across hardware it will never
/// see on the developer's desk.
public struct HardwareProfile: Equatable, Sendable {
  public let memoryBytes: Int64
  public let freeDiskBytes: Int64
  public let macOSMajorVersion: Int

  public init(memoryBytes: Int64, freeDiskBytes: Int64, macOSMajorVersion: Int) {
    self.memoryBytes = memoryBytes
    self.freeDiskBytes = freeDiskBytes
    self.macOSMajorVersion = macOSMajorVersion
  }

  public static func current(
    processInfo: ProcessInfo = .processInfo, fileManager: FileManager = .default
  ) -> HardwareProfile {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let capacity =
      (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage ?? 0
    return HardwareProfile(
      memoryBytes: Int64(processInfo.physicalMemory),
      freeDiskBytes: capacity,
      macOSMajorVersion: processInfo.operatingSystemVersion.majorVersion)
  }
}

/// Why a model is or is not offered. Unavailable models are shown with their
/// reason rather than hidden: "needs 32 GB, this Mac has 16 GB" teaches, while
/// a missing row just looks broken.
public enum ModelAvailability: Equatable, Sendable {
  case recommended
  case insufficientMemory(needs: Int64)
  case insufficientDisk(needs: Int64)
}

public enum SetupAdvisor {
  /// Headroom left for macOS, Myna, and whatever else the user is running.
  private static let systemReserveBytes: Int64 = 3 * 1_073_741_824

  /// Matches `LocalModelManager.install`, which refuses without this much slack.
  private static let installDiskHeadroomBytes: Int64 = 1_000_000_000

  /// Memory a model needs while running.
  ///
  /// Measured on an M4 Pro: `llama-server` with a 6.3 GB GGUF at ctx 8192 holds
  /// 7.89 GB resident — about 1.25x the file, the extra being the KV cache and
  /// runtime. (Its `phys_footprint` reads far lower because llama.cpp mmaps the
  /// weights as file-backed pages, but those must stay resident for the model
  /// to run at speed, so RSS is the honest figure.)
  public static func requiredMemory(for descriptor: ModelDescriptor) -> Int64 {
    descriptor.expectedBytes * 5 / 4 + systemReserveBytes
  }

  public static func availability(
    of descriptor: ModelDescriptor, on hardware: HardwareProfile
  ) -> ModelAvailability {
    // Disk first: promising a model the installer would refuse to download is
    // worse than saying up front that it won't fit.
    let disk = descriptor.expectedBytes + installDiskHeadroomBytes
    guard hardware.freeDiskBytes >= disk else { return .insufficientDisk(needs: disk) }

    let memory = requiredMemory(for: descriptor)
    guard hardware.memoryBytes >= memory else {
      return .insufficientMemory(needs: memory)
    }
    return .recommended
  }

  /// Whether the model leaves real headroom while resident: its RSS
  /// (≈1.25× the file) must fit in a third of the machine's RAM. This is
  /// Flow's recommendation bar — stricter than "can run at all" — because
  /// polish is a background nicety, not the machine's main job. On 16 GB
  /// this recommends E4B (5.3 GB resident), not the 12B that would
  /// technically run while starving everything else.
  public static func fitsComfortably(
    _ descriptor: ModelDescriptor, on hardware: HardwareProfile
  ) -> Bool {
    descriptor.expectedBytes * 5 / 4 <= hardware.memoryBytes / 3
  }

  /// The best language model this Mac can run *comfortably*; falls back to
  /// the largest merely-runnable one only when nothing fits comfortably, so
  /// a user whose pick is too large is offered the next one down instead of
  /// a dead end.
  public static func largestRunnableLanguageModel(
    on hardware: HardwareProfile
  ) -> ModelDescriptor? {
    let bySize = DefaultModelCatalog.language.sorted { $0.expectedBytes > $1.expectedBytes }
    let runnable = bySize.filter { availability(of: $0, on: hardware) == .recommended }
    return runnable.first { fitsComfortably($0, on: hardware) } ?? runnable.first
  }
}
