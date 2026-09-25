import Foundation

/// Everything a permission problem report needs, in one value.
///
/// Pure: built from injected state, so the rules that turn state into
/// findings are testable without a signed bundle or a TCC database. The live
/// version lives in the app target, which is the only place that can look
/// up other installed copies through Launch Services.
public struct PermissionSnapshot: Equatable, Sendable, Codable {
  public enum Grant: String, Codable, Sendable { case granted, denied, notDetermined, restricted }

  public struct Finding: Equatable, Sendable, Codable {
    public enum Severity: String, Codable, Sendable { case warning, info }
    public var severity: Severity
    public var text: String
    public init(_ severity: Severity, _ text: String) {
      self.severity = severity
      self.text = text
    }
  }

  public var capturedAt: Date
  public var macOSVersion: String
  public var microphone: Grant
  /// `AXIsProcessTrusted()` as this process sees it. Cached per process, so a
  /// false here can lag a grant made after launch.
  public var accessibility: Bool
  public var inputMonitoring: Grant
  public var app: CodeIdentity
  public var otherCopies: [CodeIdentity]

  public init(
    capturedAt: Date = Date(), macOSVersion: String, microphone: Grant,
    accessibility: Bool, inputMonitoring: Grant, app: CodeIdentity,
    otherCopies: [CodeIdentity] = []
  ) {
    self.capturedAt = capturedAt
    self.macOSVersion = macOSVersion
    self.microphone = microphone
    self.accessibility = accessibility
    self.inputMonitoring = inputMonitoring
    self.app = app
    self.otherCopies = otherCopies
  }

  /// In a fixed order, so the report reads the same way every time.
  public var findings: [Finding] {
    var out: [Finding] = []
    let mine = app.parsedRequirement
    for other in otherCopies {
      let same = mine.flatMap { m in other.parsedRequirement.map { m.sameIdentity(as: $0) } }
      if same == true {
        // A translocated process is a read-only mirror of its original, so
        // the original is not a second copy.
        if app.isTranslocated { continue }
        out.append(
          .init(
            .info,
            "A second identical copy is installed at \(other.bundlePath). Permissions apply to both, but macOS may open either one."
          ))
      } else {
        out.append(
          .init(
            .warning,
            "Another copy at \(other.bundlePath) is signed differently (\(other.summary) vs \(app.summary)). macOS keeps Accessibility and Input Monitoring per signature, so a grant made for one copy does not apply to the other. Keep one copy and remove the rest."
          ))
      }
    }
    if app.isAdHoc {
      out.append(
        .init(
          .warning,
          "This copy is ad-hoc signed: its permission grant is tied to these exact bytes and stops applying after any rebuild."
        ))
    }
    if app.signature == .unsigned {
      out.append(.init(.warning, "This copy is unsigned; macOS will not remember permissions for it."))
    }
    if app.isTranslocated {
      out.append(
        .init(
          .warning,
          "Running from a translocated path (\(app.bundlePath)). macOS does this to a downloaded app that was opened in place or copied without Finder. Drag it into Applications with Finder and reopen it."
        ))
    }
    if !accessibility && otherCopies.isEmpty && !app.isAdHoc && app.signature != .unsigned {
      out.append(
        .init(
          .warning,
          "Accessibility reads as off for this process. If System Settings shows it on: quit and reopen Myna Flow — the value is cached per process. If it still reads off after that, the list may be managed by a profile."
        ))
    }
    return out
  }

  public var mismatchWarnings: [String] { findings.filter { $0.severity == .warning }.map(\.text) }

  /// Plain text, one fact per line, meant to be pasted into an issue.
  public var report: String {
    let stamp = ISO8601DateFormatter().string(from: capturedAt)
    var lines: [String] = []
    lines.append("Myna Flow permission report — \(stamp), macOS \(macOSVersion)")
    lines.append("App:        \(app.bundlePath)  v\(app.version ?? "?") (\(app.build ?? "?"))")
    lines.append("Signature:  \(app.authority.first ?? app.summary)  [\(app.signature.rawValue), fingerprint \(app.shortFingerprint)]")
    if let requirement = app.designatedRequirement { lines.append("DR:         \(requirement)") }
    if let seal = app.sealValid { lines.append("Seal:       \(seal ? "valid" : "BROKEN")") }
    lines.append("Microphone:        \(microphone.rawValue)")
    lines.append("Accessibility:     \(accessibility ? "granted" : "off (as seen by this process)")")
    lines.append("Input Monitoring:  \(inputMonitoring.rawValue)")
    lines.append("Other copies (\(otherCopies.count)):")
    for other in otherCopies {
      lines.append("  \(other.bundlePath)  v\(other.version ?? "?") (\(other.build ?? "?"))  \(other.summary)")
    }
    let found = findings
    if !found.isEmpty {
      lines.append("Findings:")
      for f in found { lines.append("  - [\(f.severity.rawValue)] \(f.text)") }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private enum CodingKeys: String, CodingKey {
    case capturedAt, macOSVersion, microphone, accessibility, inputMonitoring, app, otherCopies
    case findings
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    capturedAt = try c.decode(Date.self, forKey: .capturedAt)
    macOSVersion = try c.decode(String.self, forKey: .macOSVersion)
    microphone = try c.decode(Grant.self, forKey: .microphone)
    accessibility = try c.decode(Bool.self, forKey: .accessibility)
    inputMonitoring = try c.decode(Grant.self, forKey: .inputMonitoring)
    app = try c.decode(CodeIdentity.self, forKey: .app)
    otherCopies = try c.decode([CodeIdentity].self, forKey: .otherCopies)
    // `findings` is derived; whatever was written is recomputed on read.
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(capturedAt, forKey: .capturedAt)
    try c.encode(macOSVersion, forKey: .macOSVersion)
    try c.encode(microphone, forKey: .microphone)
    try c.encode(accessibility, forKey: .accessibility)
    try c.encode(inputMonitoring, forKey: .inputMonitoring)
    try c.encode(app, forKey: .app)
    try c.encode(otherCopies, forKey: .otherCopies)
    try c.encode(findings, forKey: .findings)
  }

  public func json() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
  }
}
