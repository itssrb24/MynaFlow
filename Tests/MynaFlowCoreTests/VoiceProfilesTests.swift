import Foundation
import Testing

@testable import MynaFlowCore

/// Myna's seeded generator: the same numbers every run.
private struct Deterministic {
  var state: UInt64
  mutating func signed() -> Double {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z = z ^ (z >> 31)
    return Double(z >> 11) / Double(1 << 53) * 2 - 1
  }
}

private let dims = 192

private func voice(_ axis: Int) -> [Float] {
  var v = [Float](repeating: 0, count: dims)
  v[axis] = 1
  return v
}

/// `count` turns of one voice with random variation on every dimension —
/// how a single real speaker's embeddings scatter.
private func turns(_ axis: Int, count: Int, seed: UInt64 = 7) -> [SpeakerSample] {
  var rng = Deterministic(state: seed &+ UInt64(axis))
  return (0..<count).map { _ in
    var v = voice(axis)
    for d in 0..<dims { v[d] += Float(rng.signed() * 0.04) }
    return SpeakerSample(embedding: v, seconds: 2)
  }
}

@Suite("SpeakerProfiler — one voice profile per speaker, with a quality verdict")
struct SpeakerProfilerTests {
  @Test("a steady voice heard often is clean; the profile averages its samples")
  func clean() throws {
    let profiles = SpeakerProfiler.profiles(from: [1: turns(0, count: 25)])
    let profile = try #require(profiles.first)
    #expect(profile.speaker == 1)
    #expect(profile.seconds == 50)
    #expect(profile.quality == .clean)
    #expect(SpeakerMatch.cosine(profile.embedding, voice(0)) > 0.95)
  }

  @Test("two voices folded into one speaker are caught as mixed")
  func mixed() throws {
    let both = turns(0, count: 15) + turns(8, count: 15)
    let profile = try #require(SpeakerProfiler.profiles(from: [2: both]).first)
    #expect(profile.quality == .mixed)
  }
}

@Suite("Recognising voices in a meeting")
struct VoiceRecognitionTests {
  let maurice = UUID()
  let dan = UUID()

  func print(_ axis: Int) -> VoicePrint {
    VoicePrint(embedding: voice(axis), channel: .remote, sampleCount: 3, updatedAt: Date())
  }

  @Test("a clean speaker matching a known voice is named; a weaker match is a suggestion")
  func autoAndSuggest() {
    let profiles = SpeakerProfiler.profiles(from: [1: turns(0, count: 25), 2: turns(5, count: 25)])
    // Dan's print leans away from axis 5 (cosine ≈ 0.55): suggest, don't name.
    var danPrint = voice(5)
    danPrint[6] = 1.5
    let candidates = [
      SpeakerMatch.Candidate(personID: maurice, voiceprints: [print(0)], isInvited: true),
      SpeakerMatch.Candidate(
        personID: dan,
        voiceprints: [VoicePrint(embedding: danPrint, channel: .remote, sampleCount: 2, updatedAt: Date())],
        isInvited: false),
    ]
    let result = VoiceRecognition.recognise(profiles, candidates: candidates)
    #expect(result.named[1] == maurice)
    #expect(result.suggested[2] == dan)
    #expect(result.named[2] == nil)
  }

  @Test("a mixed speaker is never named automatically, however close")
  func mixedNotNamed() {
    let profiles = SpeakerProfiler.profiles(from: [1: turns(0, count: 15) + turns(8, count: 15)])
    let candidates = [SpeakerMatch.Candidate(personID: maurice, voiceprints: [print(0)], isInvited: true)]
    #expect(VoiceRecognition.recognise(profiles, candidates: candidates).named.isEmpty)
  }
}

private func databaseURL() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("voices-tests-\(UUID().uuidString)", isDirectory: true)
    .appendingPathComponent("flow.sqlite", isDirectory: false)
}

@Suite("Voice profiles in the store")
struct VoiceProfileStoreTests {
  func meetingWithProfile(quality: ClusterQuality.State = .clean) -> MeetingRecord {
    MeetingRecord(
      startedAt: Date(timeIntervalSince1970: 1_800_000_000), durationSeconds: 60,
      segments: [MeetingSegment(channel: .others, startSeconds: 0, text: "Hi.", speaker: 1)],
      summary: nil, summaryNote: nil,
      speakerProfiles: [SpeakerProfile(speaker: 1, embedding: voice(0), seconds: 40, quality: quality)])
  }

  @Test("confirming a clean speaker teaches that person's voice; reassigning moves it; clearing removes it")
  func enrolMoveClear() async throws {
    let store = try await FlowStore.open(at: databaseURL())
    let record = meetingWithProfile()
    try await store.insertMeeting(record)
    let maurice = try await store.person(named: "Maurice Lee")
    let dan = try await store.person(named: "Dan Smith")

    try await store.setSpeaker(1, to: maurice, meetingID: record.id, learnVoice: true)
    #expect(try await store.voicePrints(of: maurice.id).first?.sampleCount == 1)

    try await store.setSpeaker(1, to: dan, meetingID: record.id, learnVoice: true)
    #expect(try await store.voicePrints(of: maurice.id).isEmpty)
    #expect(try await store.voicePrints(of: dan.id).first?.sampleCount == 1)

    try await store.setSpeakerName("", speaker: 1, meetingID: record.id)
    #expect(try await store.voicePrints(of: dan.id).isEmpty)
    await store.close()
  }

  @Test("an unclean speaker teaches nothing; with voices off nothing is learned")
  func noLearning() async throws {
    let store = try await FlowStore.open(at: databaseURL())
    let mixed = meetingWithProfile(quality: .mixed)
    try await store.insertMeeting(mixed)
    let maurice = try await store.person(named: "Maurice Lee")
    try await store.setSpeaker(1, to: maurice, meetingID: mixed.id, learnVoice: true)
    #expect(try await store.voicePrints(of: maurice.id).isEmpty)

    let clean = meetingWithProfile()
    try await store.insertMeeting(clean)
    try await store.setSpeaker(1, to: maurice, meetingID: clean.id, learnVoice: false)
    #expect(try await store.voicePrints(of: maurice.id).isEmpty)
    await store.close()
  }

  @Test("forgetting voices removes every voice profile and every stored speaker sample")
  func forget() async throws {
    let store = try await FlowStore.open(at: databaseURL())
    let record = meetingWithProfile()
    try await store.insertMeeting(record)
    let maurice = try await store.person(named: "Maurice Lee")
    try await store.setSpeaker(1, to: maurice, meetingID: record.id, learnVoice: true)
    try await store.forgetAllVoices()
    #expect(try await store.voicePrints(of: maurice.id).isEmpty)
    #expect(try await store.meetings(limit: 1).first?.speakerProfiles.isEmpty == true)
    #expect(try await store.voiceCandidates(invited: []).isEmpty)
    await store.close()
  }
}
