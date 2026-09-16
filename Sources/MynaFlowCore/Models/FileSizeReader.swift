import Foundation

/// Bytes a model actually occupies on disk.
///
/// `attributesOfItem[.size]` on a directory returns the directory inode's own
/// size, about 128 bytes on APFS. Several models install as directories of
/// CoreML bundles, so the diagnostics export reported the 13.7 MB speaker
/// separation model as 128 bytes for as long as it existed, which looked
/// exactly like a corrupt download.
public enum FileSizeReader {

  /// Total size at `url`, walking directories. Symlinks are skipped so a link
  /// into the same tree cannot double-count.
  public static func totalBytes(at url: URL, fileManager: FileManager = .default) -> Int64 {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
    guard isDirectory.boolValue else { return regularFileBytes(at: url) }

    guard
      let enumerator = fileManager.enumerator(
        at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles])
    else { return 0 }

    var total: Int64 = 0
    for case let child as URL in enumerator {
      total += regularFileBytes(at: child)
    }
    return total
  }

  /// Zero for anything that is not a regular file, so directories and
  /// symlinks contribute nothing of their own.
  private static func regularFileBytes(at url: URL) -> Int64 {
    guard
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true, let size = values.fileSize
    else { return 0 }
    return Int64(size)
  }
}
