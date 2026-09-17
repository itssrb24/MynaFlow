import Foundation

/// One learned preference. Suggested by the learner, approved by the user,
/// applied by the cleaner only when approved *and* learning is enabled.
public struct LearnedRule: Equatable, Codable, Sendable {
  public enum Kind: String, Codable, Sendable {
    /// A word the user keeps deleting after insertion.
    case filler
    /// A word the user keeps replacing with another (whole-word).
    case replacement
    /// A formatting habit, identified by a fixed pattern constant.
    case formatting
  }

  public static let noTerminalPeriod = "no-terminal-period"

  public let kind: Kind
  /// Word (lowercased) for filler/replacement; a constant for formatting.
  public let pattern: String
  public let replacement: String?
  /// How many corrections support the rule.
  public let evidence: Int

  public init(kind: Kind, pattern: String, replacement: String?, evidence: Int) {
    self.kind = kind
    self.pattern = pattern
    self.replacement = replacement
    self.evidence = evidence
  }

  public var summary: String {
    switch kind {
    case .filler: "Drop “\(pattern)”"
    case .replacement: "“\(pattern)” → “\(replacement ?? "")”"
    case .formatting:
      pattern == Self.noTerminalPeriod ? "No period at the end" : pattern
    }
  }
}

public enum LearnedRuleStatus: String, Codable, Sendable {
  case suggested
  case approved
  case rejected
}

public struct StoredLearnedRule: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let rule: LearnedRule
  public let status: LearnedRuleStatus
  public let updatedAt: Date
}

/// What the cleaner consults. `enabled` is the master switch: approved rules
/// stay inert until the user turns learning on.
public struct LearnedRules: Equatable, Sendable {
  public let approved: [LearnedRule]
  public let enabled: Bool

  public init(approved: [LearnedRule] = [], enabled: Bool = true) {
    self.approved = approved
    self.enabled = enabled
  }

  var isActive: Bool { enabled && !approved.isEmpty }

  var fillers: Set<String> {
    Set(approved.filter { $0.kind == .filler }.map { $0.pattern.lowercased() })
  }

  var replacements: [String: String] {
    var map: [String: String] = [:]
    for rule in approved where rule.kind == .replacement {
      if let replacement = rule.replacement { map[rule.pattern.lowercased()] = replacement }
    }
    return map
  }

  var stripsTerminalPeriod: Bool {
    approved.contains { $0.kind == .formatting && $0.pattern == LearnedRule.noTerminalPeriod }
  }
}
