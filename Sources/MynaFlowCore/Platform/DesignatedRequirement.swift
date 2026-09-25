import Foundation

/// The part of a code-signing designated requirement that TCC keys a grant to.
///
/// macOS remembers "Myna Flow may use Accessibility" against this requirement,
/// not against the app's name or path. Two copies of the app whose requirements
/// differ are two different apps to TCC, however identical they look in System
/// Settings — which shows one row, switched on, for whichever copy was granted.
/// Comparing requirements structurally, rather than as strings, is what lets the
/// app say "that other copy is signed differently" with confidence.
public struct DesignatedRequirement: Equatable, Sendable {
  public enum Anchor: Equatable, Sendable {
    /// `anchor apple generic and certificate leaf[subject.CN] = "…"`: an Apple
    /// Development or Developer ID certificate. Renewed certificates keep their
    /// common name, so this is matched by name and team, not by hash.
    case appleGeneric(leafCommonName: String?, teamIdentifier: String?)
    /// `certificate root = H"<sha1>"`: a self-signed certificate.
    case certificateRoot(sha1: String)
    /// `certificate leaf = H"<sha1>"`: pinned to one exact certificate.
    case certificateLeaf(sha1: String)
    /// `cdhash H"…"`: ad-hoc. Pinned to these exact bytes, so any rebuild is a
    /// different app.
    case cdhash(String)
    case unknown
  }

  public var identifier: String?
  public var anchor: Anchor

  public init(identifier: String?, anchor: Anchor) {
    self.identifier = identifier
    self.anchor = anchor
  }

  /// Accepts both `SecRequirementCopyString` output and `codesign -d -r-`
  /// output, which prefixes `designated => `.
  public static func parse(_ text: String) -> DesignatedRequirement {
    var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let range = body.range(of: "designated => ") { body = String(body[range.upperBound...]) }

    func capture(_ regex: Regex<(Substring, Substring)>) -> String? {
      body.firstMatch(of: regex).map { String($0.1) }
    }
    let identifier = capture(/identifier "([^"]+)"/)

    let anchor: Anchor
    if let hash = capture(/cdhash H"([0-9a-fA-F]+)"/) {
      anchor = .cdhash(hash.lowercased())
    } else if body.contains("anchor apple") {
      anchor = .appleGeneric(
        leafCommonName: capture(/certificate leaf\[subject\.CN\] = "([^"]+)"/),
        teamIdentifier: capture(/certificate leaf\[subject\.OU\] = "([^"]+)"/))
    } else if let hash = capture(/certificate root = H"([0-9a-fA-F]+)"/) {
      anchor = .certificateRoot(sha1: hash.lowercased())
    } else if let hash = capture(/certificate leaf = H"([0-9a-fA-F]+)"/) {
      anchor = .certificateLeaf(sha1: hash.lowercased())
    } else {
      anchor = .unknown
    }
    return DesignatedRequirement(identifier: identifier, anchor: anchor)
  }

  /// Whether a grant recorded against `other` would apply to this code.
  /// Unknown never matches, not even itself: "we could not tell" must never
  /// read as "these are the same".
  public func sameIdentity(as other: DesignatedRequirement) -> Bool {
    guard anchor != .unknown, other.anchor != .unknown else { return false }
    return identifier == other.identifier && anchor == other.anchor
  }

  /// Short human label for a report line.
  public var summary: String {
    switch anchor {
    case .appleGeneric(let name, _): name ?? "Apple-issued certificate"
    case .certificateRoot(let sha1): "self-signed \(sha1.prefix(8))"
    case .certificateLeaf(let sha1): "certificate \(sha1.prefix(8))"
    case .cdhash: "ad-hoc"
    case .unknown: "unknown signature"
    }
  }
}
