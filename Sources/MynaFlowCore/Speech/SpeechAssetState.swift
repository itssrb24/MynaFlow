import Foundation

/// Whether macOS has the speech model for our locale yet.
///
/// Myna Flow ships no speech weights: macOS downloads them once, through
/// Apple's asset channel. The very first run needs the network once, and the
/// user deserves to be told that plainly rather than watching dictation do
/// nothing.
public enum SpeechAssetState: Equatable, Sendable {
  case ready(localeIdentifier: String)
  case needsInstall(localeIdentifier: String)
  case failed(localeIdentifier: String, offline: Bool)
}

/// The sentences the user reads about speech readiness, kept in Core so the
/// wording is under test if it ever grows conditionals.
public enum SpeechReadinessCopy {
  public static func statusLine(_ state: SpeechAssetState) -> String {
    switch state {
    case .ready(let identifier):
      return "Ready · \(languageName(identifier))"
    case .needsInstall:
      return "macOS downloads the speech model the first time you dictate. Once only."
    case .failed(_, let offline):
      return offline ? "Speech setup needs the internet once." : "Speech setup did not finish."
    }
  }

  /// "en_US" reads as machinery; "English (US)" reads as an answer.
  static func languageName(_ identifier: String) -> String {
    let normalized = identifier.replacingOccurrences(of: "_", with: "-")
    return Locale.current.localizedString(forIdentifier: normalized) ?? normalized
  }
}
