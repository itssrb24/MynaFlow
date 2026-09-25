import Testing

@testable import MynaFlowCore

@Suite("Designated requirement")
struct DesignatedRequirementTests {
  // Captured from real bundles on the development Mac.
  static let apple =
    #"identifier "com.itssrb24.MynaFlow" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: someone@example.com (AULMDWGH97)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"#
  static let selfSigned =
    #"identifier "com.itssrb24.MynaFlow" and certificate root = H"187482b7d4a30d1111a1976b369c82235409d0cd""#
  static let adHoc = #"identifier "com.itssrb24.MynaFlow" and cdhash H"06f6f250450af9297595001820e8cf60f5f69da7""#

  @Test("Self-signed parses to its root hash")
  func selfSignedParses() {
    let dr = DesignatedRequirement.parse(Self.selfSigned)
    #expect(dr.identifier == "com.itssrb24.MynaFlow")
    #expect(dr.anchor == .certificateRoot(sha1: "187482b7d4a30d1111a1976b369c82235409d0cd"))
    #expect(dr.summary == "self-signed 187482b7")
  }

  @Test("Apple Development parses by common name, not by hash")
  func appleParses() {
    let dr = DesignatedRequirement.parse(Self.apple)
    #expect(
      dr.anchor
        == .appleGeneric(
          leafCommonName: "Apple Development: someone@example.com (AULMDWGH97)", teamIdentifier: nil))
    #expect(dr.summary.hasPrefix("Apple Development"))
  }

  @Test("Ad-hoc parses to its cdhash and says so")
  func adHocParses() {
    let dr = DesignatedRequirement.parse(Self.adHoc)
    #expect(dr.anchor == .cdhash("06f6f250450af9297595001820e8cf60f5f69da7"))
    #expect(dr.summary == "ad-hoc")
  }

  @Test("codesign's 'designated =>' prefix is accepted")
  func prefixIgnored() {
    #expect(
      DesignatedRequirement.parse("designated => " + Self.selfSigned)
        == DesignatedRequirement.parse(Self.selfSigned))
  }

  @Test("Different signing methods are different identities")
  func differentMethodsDiffer() {
    let a = DesignatedRequirement.parse(Self.apple)
    let s = DesignatedRequirement.parse(Self.selfSigned)
    let h = DesignatedRequirement.parse(Self.adHoc)
    #expect(!a.sameIdentity(as: s))
    #expect(!s.sameIdentity(as: h))
    #expect(!a.sameIdentity(as: h))
  }

  @Test("Two self-signed certificates with different roots are different apps to TCC")
  func twoSelfSignedRootsDiffer() {
    // install.sh mints its own certificate on every Mac. Same name in System
    // Settings; a different key, a different root, a different app.
    let mine = DesignatedRequirement.parse(Self.selfSigned)
    let theirs = DesignatedRequirement.parse(
      #"identifier "com.itssrb24.MynaFlow" and certificate root = H"0000000000000000000000000000000000000000""#)
    #expect(!mine.sameIdentity(as: theirs))
  }

  @Test("Hash case and surrounding whitespace do not matter")
  func normalised() {
    // codesign always lower-cases the keywords; only the hex can plausibly
    // differ in case between tools, so that is all that is normalised.
    let shouted = Self.selfSigned.replacingOccurrences(
      of: "187482b7d4a30d1111a1976b369c82235409d0cd",
      with: "187482B7D4A30D1111A1976B369C82235409D0CD")
    let upper = DesignatedRequirement.parse("  " + shouted + "\n")
    #expect(upper.sameIdentity(as: DesignatedRequirement.parse(Self.selfSigned)))
  }

  @Test("Unknown never matches, not even itself")
  func unknownNeverMatches() {
    let u = DesignatedRequirement.parse("gibberish")
    #expect(u.anchor == .unknown)
    #expect(!u.sameIdentity(as: u))
  }
}
