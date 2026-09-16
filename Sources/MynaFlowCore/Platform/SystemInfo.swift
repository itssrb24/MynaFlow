import Foundation

public enum SystemInfoReader {
  public static func hardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buffer, &size, nil, 0)
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }

  public static func memoryTotalBytes() -> UInt64 {
    ProcessInfo.processInfo.physicalMemory
  }

  /// Free + inactive pages — the "reclaimable now" figure that decides
  /// whether a model can actually load, which raw free alone understates.
  public static func memoryFreeBytes() -> UInt64 {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    let pageSize = UInt64(getpagesize())
    return (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageSize
  }

  public static func diskFreeBytes(for url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage ?? 0
  }
}
