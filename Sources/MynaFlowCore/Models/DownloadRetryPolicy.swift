import Foundation

/// When a model download may be retried, how often, and what counts as a
/// stall. Pure, because the observed failure was invisible: Gemma 12B sat at
/// 2% behind a live progress bar for as long as anyone cared to watch —
/// URLSession's waitsForConnectivity parked the task after a network path
/// change and nothing in the app was looking. Every decision here is a
/// one-line test; the downloader just executes them.
public enum DownloadRetryPolicy {
  /// Retries after the first attempt, each resuming from the `.part` file —
  /// a retry continues, it never starts over. Generous because a resumed
  /// retry costs only the backoff, and hotspots drop mid-transfer often.
  public static let maxRetries = 12

  /// Seconds of silence (no bytes written) before the watchdog calls a live
  /// task dead. Below this is a slow network, which is not our business.
  public static let stallSeconds: TimeInterval = 60

  public static func isStalled(idleSeconds: TimeInterval) -> Bool {
    idleSeconds >= stallSeconds
  }

  /// 2, 4, 8, 16, then capped at 30 s — enough to ride out a Wi-Fi or
  /// hotspot transition, short enough that the bar visibly recovers.
  public static func delay(beforeRetry attempt: Int) -> TimeInterval {
    min(30, TimeInterval(1 << max(1, attempt)))
  }

  /// Transient transport failures are ours to retry. Content and intent
  /// failures are not: a checksum mismatch re-downloads the same wrong
  /// bytes, and a user cancel must never be retried against them.
  public static func isRetryable(_ error: Error) -> Bool {
    if let modelError = error as? ModelManagerError {
      switch modelError {
      case .downloadStalled: return true
      case .checksumMismatch, .invalidDescriptor, .insufficientDiskSpace, .modelNotInstalled:
        return false
      }
    }
    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain else { return false }
    switch nsError.code {
    case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
      NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost,
      NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
      return true
    default:
      return false
    }
  }
}
