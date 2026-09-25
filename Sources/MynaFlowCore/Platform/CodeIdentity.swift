import CryptoKit
import Foundation
import Security

/// What a copy of the app is signed as, read from its bundle on disk.
///
/// Exists because the single most confusing failure this app has is "System
/// Settings shows Accessibility on, the app says it is off". That is almost
/// always two differently-signed copies sharing one bundle id. Nothing in the
/// app could see its own signature until now, so nothing could say so.
public struct CodeIdentity: Equatable, Sendable, Codable {
  public enum SignatureKind: String, Codable, Sendable { case unsigned, adHoc, certificate }

  public var bundlePath: String
  public var bundleIdentifier: String?
  public var version: String?
  public var build: String?
  public var signature: SignatureKind
  /// Certificate subject summaries, leaf first. Empty when ad-hoc or unsigned.
  public var authority: [String]
  public var teamIdentifier: String?
  public var designatedRequirement: String?
  public var cdhash: String
  /// SHA-1 of the leaf certificate, or the cdhash when there is none. A stable
  /// short thing to put in a log line, where the full requirement is too long.
  public var fingerprint: String
  /// Set when running from an AppTranslocation path: a quarantined app opened
  /// somewhere other than /Applications, which Launch Services sees as a second
  /// location and TCC as a second app.
  public var isTranslocated: Bool
  /// Only set when a seal check was asked for; it hashes every sealed file.
  public var sealValid: Bool?

  public var isAdHoc: Bool { signature == .adHoc }
  public var shortFingerprint: String { String(fingerprint.prefix(8)) }
  public var parsedRequirement: DesignatedRequirement? {
    designatedRequirement.map(DesignatedRequirement.parse)
  }
  public var summary: String {
    switch signature {
    case .unsigned: "unsigned"
    case .adHoc: "ad-hoc"
    case .certificate: parsedRequirement?.summary ?? authority.first ?? "signed"
    }
  }

  public init(
    bundlePath: String, bundleIdentifier: String? = nil, version: String? = nil,
    build: String? = nil, signature: SignatureKind, authority: [String] = [],
    teamIdentifier: String? = nil, designatedRequirement: String? = nil,
    cdhash: String = "", fingerprint: String = "", isTranslocated: Bool = false,
    sealValid: Bool? = nil
  ) {
    self.bundlePath = bundlePath
    self.bundleIdentifier = bundleIdentifier
    self.version = version
    self.build = build
    self.signature = signature
    self.authority = authority
    self.teamIdentifier = teamIdentifier
    self.designatedRequirement = designatedRequirement
    self.cdhash = cdhash
    self.fingerprint = fingerprint.isEmpty ? cdhash : fingerprint
    self.isTranslocated = isTranslocated
    self.sealValid = sealValid
  }

  /// The running process, resolved to its on-disk bundle.
  public static func current(checkSeal: Bool = false) throws -> CodeIdentity {
    var dynamic: SecCode?
    try check(SecCodeCopySelf(SecCSFlags(), &dynamic))
    guard let dynamic else { throw CodeIdentityError.security(errSecInternalError, "no self code") }
    var code: SecStaticCode?
    try check(SecCodeCopyStaticCode(dynamic, SecCSFlags(), &code))
    guard let code else { throw CodeIdentityError.security(errSecInternalError, "no static code") }
    return try inspect(code, path: Bundle.main.bundleURL.path, checkSeal: checkSeal)
  }

  /// Any other copy on disk.
  public static func read(at bundleURL: URL, checkSeal: Bool = false) throws -> CodeIdentity {
    var code: SecStaticCode?
    try check(SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &code))
    guard let code else { throw CodeIdentityError.security(errSecInternalError, "no static code") }
    return try inspect(code, path: bundleURL.path, checkSeal: checkSeal)
  }

  /// A placeholder for a copy that exists but could not be inspected, so the
  /// report can still list it rather than silently drop it.
  public static func unreadable(at bundleURL: URL) -> CodeIdentity {
    CodeIdentity(bundlePath: bundleURL.path, signature: .unsigned)
  }

  private static func inspect(_ code: SecStaticCode, path: String, checkSeal: Bool) throws
    -> CodeIdentity
  {
    var infoRef: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
    let status = SecCodeCopySigningInformation(code, flags, &infoRef)
    if status == errSecCSUnsigned {
      return CodeIdentity(
        bundlePath: path, signature: .unsigned,
        isTranslocated: path.contains("/AppTranslocation/"))
    }
    try check(status)
    let info = (infoRef as? [String: Any]) ?? [:]

    let plist = info[kSecCodeInfoPList as String] as? [String: Any] ?? [:]
    let signatureFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
    let isAdHoc =
      SecCodeSignatureFlags(rawValue: signatureFlags).contains(.adhoc) || certificates.isEmpty
    let cdhash = (info[kSecCodeInfoUnique as String] as? Data).map(hex) ?? ""

    var requirement: String?
    if let raw = info[kSecCodeInfoDesignatedRequirement as String],
      CFGetTypeID(raw as CFTypeRef) == SecRequirementGetTypeID()
    {
      var text: CFString?
      if SecRequirementCopyString(raw as! SecRequirement, SecCSFlags(), &text) == errSecSuccess {
        requirement = text as String?
      }
    }

    let leafFingerprint = certificates.first.map {
      hex(Data(Insecure.SHA1.hash(data: SecCertificateCopyData($0) as Data)))
    }
    var sealValid: Bool?
    if checkSeal { sealValid = SecStaticCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess }

    return CodeIdentity(
      bundlePath: path,
      bundleIdentifier: info[kSecCodeInfoIdentifier as String] as? String,
      version: plist["CFBundleShortVersionString"] as? String,
      build: plist["CFBundleVersion"] as? String,
      signature: isAdHoc ? .adHoc : .certificate,
      authority: certificates.map { (SecCertificateCopySubjectSummary($0) as String?) ?? "?" },
      teamIdentifier: info[kSecCodeInfoTeamIdentifier as String] as? String,
      designatedRequirement: requirement,
      cdhash: cdhash,
      fingerprint: leafFingerprint ?? cdhash,
      isTranslocated: path.contains("/AppTranslocation/"),
      sealValid: sealValid)
  }

  private static func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else {
      let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
      throw CodeIdentityError.security(status, message)
    }
  }

  private static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }
}

public enum CodeIdentityError: Error, LocalizedError, Equatable {
  case security(OSStatus, String)
  public var errorDescription: String? {
    if case .security(let status, let message) = self { return "\(message) (\(status))" }
    return nil
  }
}
