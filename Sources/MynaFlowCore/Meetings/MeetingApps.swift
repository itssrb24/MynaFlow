import Foundation

/// One Core Audio process object, as read by the app's mic monitor.
public struct AudioProcessSnapshot: Sendable {
  public let pid: Int32
  public let bundleID: String?
  public let isRunningInput: Bool
  public let isRunningOutput: Bool

  public init(pid: Int32, bundleID: String?, isRunningInput: Bool, isRunningOutput: Bool = false) {
    self.pid = pid
    self.bundleID = bundleID
    self.isRunningInput = isRunningInput
    self.isRunningOutput = isRunningOutput
  }
}

/// Apps whose use of the microphone suggests a call.
public enum MeetingApps {
  public static let meetingApps: [String: String] = [
    "us.zoom.xos": "Zoom",
    "com.microsoft.teams2": "Microsoft Teams",
    "com.microsoft.teams": "Microsoft Teams",
    "com.apple.FaceTime": "FaceTime",
    "com.cisco.webexmeetingsapp": "Webex",
    "com.tinyspeck.slackmacgap": "Slack",
    "com.hnc.Discord": "Discord",
  ]

  public static let browsers: [String: String] = [
    "com.apple.Safari": "Safari",
    // Safari pages capture the mic from WebKit's GPU process.
    "com.apple.WebKit.GPU": "Safari",
    "com.google.Chrome": "Chrome",
    "company.thebrowser.Browser": "Arc",
    "com.brave.Browser": "Brave",
    "com.microsoft.edgemac": "Microsoft Edge",
    "org.mozilla.firefox": "Firefox",
    "org.mozilla.plugincontainer": "Firefox",
  ]

  /// The catalog apps currently using the mic, excluding `excludingPID`
  /// (Myna Flow itself, whose dictation and meeting capture use the mic too).
  public static func micHolders(
    in processes: [AudioProcessSnapshot], excludingPID: Int32
  ) -> Set<MicHolder> {
    Set(
      processes
        .filter { $0.isRunningInput && $0.pid != excludingPID }
        .compactMap { $0.bundleID.flatMap(holder(forBundleID:)) })
  }

  /// The catalog apps currently playing audio, excluding `excludingPID`.
  public static func audioHolders(
    in processes: [AudioProcessSnapshot], excludingPID: Int32
  ) -> Set<MicHolder> {
    Set(
      processes
        .filter { $0.isRunningOutput && $0.pid != excludingPID }
        .compactMap { $0.bundleID.flatMap(holder(forBundleID:)) })
  }

  /// The catalog entry for a process's bundle ID. Helper processes such as
  /// `com.google.Chrome.helper` resolve to their app; a different app that
  /// merely shares a prefix (`com.google.ChromeRemoteDesktop`) does not.
  public static func holder(forBundleID bundleID: String) -> MicHolder? {
    for (catalog, kind) in [(meetingApps, MicHolder.Kind.meetingApp), (browsers, .browser)] {
      if let match = catalog.first(where: { bundleID == $0.key || bundleID.hasPrefix($0.key + ".") }) {
        return MicHolder(bundleID: match.key, name: match.value, kind: kind)
      }
    }
    return nil
  }
}

/// Finds a video-call link in a calendar event's URL, location or notes.
public enum ConferenceLink {
  public static let hosts = [
    "meet.google.com", "zoom.us", "zoomgov.com", "teams.microsoft.com", "teams.live.com",
    "webex.com", "whereby.com", "chime.aws", "facetime.apple.com",
  ]

  private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

  /// The first conference link across `fields`, in field order.
  public static func find(in fields: [String?]) -> URL? {
    guard let detector else { return nil }
    for case let text? in fields {
      let range = NSRange(text.startIndex..., in: text)
      for match in detector.matches(in: text, range: range) {
        if let url = match.url, isConference(url) { return url }
      }
    }
    return nil
  }

  static func isConference(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
  }
}

/// Whether Myna Flow may turn on Apple's voice processing for the mic.
///
/// Voice processing is system-wide on macOS: while any process has it on,
/// every other app reading the microphone gets near-silence. So it is only
/// safe when no other app is using the mic — a call would otherwise stop
/// hearing the user. Any app counts, not just known call apps.
public enum MicSharing {
  public static func voiceProcessingIsSafe(
    _ processes: [AudioProcessSnapshot], excludingPID: Int32
  ) -> Bool {
    !processes.contains { $0.isRunningInput && $0.pid != excludingPID }
  }
}
