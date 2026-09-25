import Foundation
import Testing

@testable import MynaFlowCore

@Suite("Permission snapshot")
struct PermissionSnapshotTests {
  private func identity(
    path: String, signature: CodeIdentity.SignatureKind = .certificate,
    requirement: String? = DesignatedRequirementTests.selfSigned, translocated: Bool = false
  ) -> CodeIdentity {
    CodeIdentity(
      bundlePath: path, bundleIdentifier: "com.itssrb24.MynaFlow", version: "1.1.3", build: "113",
      signature: signature, authority: signature == .certificate ? ["Myna Flow"] : [],
      designatedRequirement: requirement, cdhash: "abcdef0123456789",
      isTranslocated: translocated)
  }

  private func snapshot(
    app: CodeIdentity, others: [CodeIdentity] = [], accessibility: Bool = true
  ) -> PermissionSnapshot {
    PermissionSnapshot(
      capturedAt: Date(timeIntervalSince1970: 1_790_000_000), macOSVersion: "26.6",
      microphone: .granted, accessibility: accessibility, inputMonitoring: .granted,
      app: app, otherCopies: others)
  }

  @Test("A single, properly signed, fully granted copy has nothing to say")
  func clean() {
    #expect(snapshot(app: identity(path: "/Applications/Myna Flow.app")).findings.isEmpty)
  }

  @Test("A differently signed copy is a warning that names the path")
  func differentlySignedCopy() {
    let s = snapshot(
      app: identity(path: "/Applications/Myna Flow.app"),
      others: [identity(path: "/Users/x/MynaFlow/dist/Myna Flow.app", requirement: DesignatedRequirementTests.apple)])
    #expect(s.mismatchWarnings.count == 1)
    #expect(s.mismatchWarnings[0].contains("/Users/x/MynaFlow/dist/Myna Flow.app"))
    #expect(s.mismatchWarnings[0].contains("per signature"))
  }

  @Test("An identical duplicate is information, not a warning")
  func identicalDuplicate() {
    let s = snapshot(
      app: identity(path: "/Applications/Myna Flow.app"),
      others: [identity(path: "/Users/x/MynaFlow/dist/Myna Flow.app")])
    #expect(s.mismatchWarnings.isEmpty)
    #expect(s.findings.count == 1)
    #expect(s.findings[0].severity == .info)
  }

  @Test("Ad-hoc is warned about even when it is the only copy")
  func adHoc() {
    let s = snapshot(app: identity(path: "/Applications/Myna Flow.app", signature: .adHoc, requirement: DesignatedRequirementTests.adHoc))
    #expect(s.mismatchWarnings.contains { $0.contains("ad-hoc") })
  }

  @Test("Translocation is called out")
  func translocated() {
    let s = snapshot(app: identity(path: "/private/var/folders/x/AppTranslocation/y/d/Myna Flow.app", translocated: true))
    #expect(s.mismatchWarnings.contains { $0.contains("translocated") })
  }

  @Test("Accessibility off with nothing else wrong points at relaunch, then a profile")
  func accessibilityOffHint() {
    let off = snapshot(app: identity(path: "/Applications/Myna Flow.app"), accessibility: false)
    #expect(off.mismatchWarnings.count == 1)
    #expect(off.mismatchWarnings[0].contains("quit and reopen"))
    #expect(off.mismatchWarnings[0].contains("profile"))
    let on = snapshot(app: identity(path: "/Applications/Myna Flow.app"), accessibility: true)
    #expect(on.findings.isEmpty)
  }

  @Test("The report carries every fact a reader needs")
  func report() {
    let s = snapshot(
      app: identity(path: "/Applications/Myna Flow.app"),
      others: [identity(path: "/Users/x/dist/Myna Flow.app", requirement: DesignatedRequirementTests.apple)],
      accessibility: false)
    let r = s.report
    for needle in [
      "v1.1.3 (113)", "/Applications/Myna Flow.app", "/Users/x/dist/Myna Flow.app",
      "Microphone:        granted", "Accessibility:     off", "Input Monitoring:  granted",
      "macOS 26.6", "[warning]",
    ] {
      #expect(r.contains(needle), "missing: \(needle)")
    }
  }

  @Test("JSON is stable and round-trips")
  func json() throws {
    let s = snapshot(app: identity(path: "/Applications/Myna Flow.app"))
    let data = try s.json()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let back = try decoder.decode(PermissionSnapshot.self, from: data)
    #expect(try back.json() == data)
    #expect(String(decoding: data, as: UTF8.self).contains("\"accessibility\" : true"))
  }

  @Test("Smoke: the running test process can read its own identity")
  func selfIdentitySmoke() throws {
    // The test binary is ad-hoc signed by SwiftPM; the point is only that the
    // Security calls succeed and return something shaped like an identity.
    let me = try CodeIdentity.current()
    #expect(!me.cdhash.isEmpty)
    #expect(me.signature == .adHoc || me.signature == .certificate)
    #expect(!me.fingerprint.isEmpty)
  }
}
