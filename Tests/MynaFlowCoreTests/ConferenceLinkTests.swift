import Foundation
import Testing

@testable import MynaFlowCore

@Suite("Conference links and meeting apps")
struct ConferenceLinkTests {
  @Test(
    "finds a video-call link in event text",
    arguments: [
      "https://meet.google.com/abc-defg-hij",
      "https://us02web.zoom.us/j/123456789?pwd=x",
      "https://zoomgov.com/j/42",
      "https://teams.microsoft.com/l/meetup-join/19%3a",
      "https://teams.live.com/meet/9",
      "https://acme.webex.com/meet/pat",
      "https://whereby.com/standup",
      "https://chime.aws/1234567890",
      "https://facetime.apple.com/join#v=1",
    ])
  func findsLink(_ link: String) {
    let found = ConferenceLink.find(in: ["Join here: \(link) — see you", nil])
    #expect(found?.absoluteString == link)
  }

  @Test("returns nil when no field has a video-call link")
  func noLink() {
    #expect(ConferenceLink.find(in: ["Room 4B", "https://example.com/agenda", nil]) == nil)
  }

  @Test("a look-alike host is not a conference link")
  func lookAlikeHost() {
    #expect(ConferenceLink.find(in: ["https://notzoom.us.evil.com/j/1"]) == nil)
  }

  @Test("the first field with a link wins")
  func firstFieldWins() {
    let found = ConferenceLink.find(in: ["https://zoom.us/j/1", "https://meet.google.com/x"])
    #expect(found?.host == "zoom.us")
  }

  @Test("meeting apps and browsers resolve by bundle ID, helpers to their parent")
  func resolvesHolders() {
    #expect(MeetingApps.holder(forBundleID: "us.zoom.xos")?.name == "Zoom")
    #expect(MeetingApps.holder(forBundleID: "us.zoom.xos")?.kind == .meetingApp)
    let chrome = MeetingApps.holder(forBundleID: "com.google.Chrome.helper")
    #expect(chrome?.bundleID == "com.google.Chrome")
    #expect(chrome?.kind == .browser)
    #expect(MeetingApps.holder(forBundleID: "com.apple.Music") == nil)
    #expect(MeetingApps.holder(forBundleID: "com.google.ChromeRemoteDesktop") == nil)
  }

  @Test("mic holders are the catalog apps using input, never our own process")
  func micHoldersFromProcesses() {
    let processes = [
      AudioProcessSnapshot(pid: 10, bundleID: "us.zoom.xos", isRunningInput: true),
      AudioProcessSnapshot(pid: 11, bundleID: "com.google.Chrome.helper", isRunningInput: false),
      AudioProcessSnapshot(pid: 12, bundleID: "com.apple.Music", isRunningInput: true),
      AudioProcessSnapshot(pid: 13, bundleID: nil, isRunningInput: true),
      // Myna Flow's own dictation or meeting capture never counts.
      AudioProcessSnapshot(pid: 99, bundleID: "com.apple.FaceTime", isRunningInput: true),
    ]
    let holders = MeetingApps.micHolders(in: processes, excludingPID: 99)
    #expect(holders.map(\.name) == ["Zoom"])
  }

  @Test("apps still playing audio are found the same way, never our own process")
  func audioHoldersFromProcesses() {
    let processes = [
      AudioProcessSnapshot(pid: 10, bundleID: "us.zoom.xos", isRunningInput: false, isRunningOutput: true),
      AudioProcessSnapshot(pid: 11, bundleID: "com.apple.Music", isRunningInput: false, isRunningOutput: true),
      AudioProcessSnapshot(pid: 99, bundleID: "com.apple.FaceTime", isRunningInput: false, isRunningOutput: true),
    ]
    #expect(MeetingApps.audioHolders(in: processes, excludingPID: 99).map(\.name) == ["Zoom"])
    #expect(MeetingApps.micHolders(in: processes, excludingPID: 99).isEmpty)
  }
}
