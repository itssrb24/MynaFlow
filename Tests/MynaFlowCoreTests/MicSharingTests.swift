import Testing

@testable import MynaFlowCore

@Suite("MicSharing — voice processing only when no one else needs the mic")
struct MicSharingTests {
  let me: Int32 = 100

  @Test("with nobody else on the mic, voice processing is safe")
  func aloneOnMic() {
    let processes = [
      AudioProcessSnapshot(pid: 200, bundleID: "com.spotify.client", isRunningInput: false, isRunningOutput: true)
    ]
    #expect(MicSharing.voiceProcessingIsSafe(processes, excludingPID: me))
  }

  @Test("a call app on the mic turns voice processing off, or the call would stop hearing you")
  func callAppOnMic() {
    let processes = [AudioProcessSnapshot(pid: 200, bundleID: "us.zoom.xos", isRunningInput: true)]
    #expect(!MicSharing.voiceProcessingIsSafe(processes, excludingPID: me))
  }

  @Test("any other app on the mic counts, not only known call apps")
  func unknownAppOnMic() {
    let processes = [AudioProcessSnapshot(pid: 300, bundleID: nil, isRunningInput: true)]
    #expect(!MicSharing.voiceProcessingIsSafe(processes, excludingPID: me))
  }

  @Test("Myna Flow's own use of the mic doesn't count")
  func selfIgnored() {
    let processes = [AudioProcessSnapshot(pid: 100, bundleID: "com.itssrb24.MynaFlow", isRunningInput: true)]
    #expect(MicSharing.voiceProcessingIsSafe(processes, excludingPID: me))
  }
}
