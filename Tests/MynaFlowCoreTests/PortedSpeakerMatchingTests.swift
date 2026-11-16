import XCTest

@testable import MynaFlowCore

final class SpeakerMatchingTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_784_600_000)

  private func emb(_ v: Float, _ dim: Int = 8) -> [Float] { [Float](repeating: v, count: dim) }
  // Two clearly-distinct unit-ish embeddings.
  private let diego: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
  private let priya: [Float] = [0, 1, 0, 0, 0, 0, 0, 0]

  func testCosine() {
    XCTAssertEqual(SpeakerMatch.cosine([1, 0], [1, 0]), 1.0, accuracy: 0.001)
    XCTAssertEqual(SpeakerMatch.cosine([1, 0], [0, 1]), 0.0, accuracy: 0.001)
    XCTAssertEqual(SpeakerMatch.cosine([1, 1], [-1, -1]), -1.0, accuracy: 0.001)
    XCTAssertEqual(SpeakerMatch.cosine([], []), 0)  // no crash
  }

  // MARK: Self — suggest until a voiceprint exists, then recognize by voice.
  // The mic channel may hint "(You?)" but never assigns silently; only a
  // user-confirmed voiceprint earns auto-assignment, same as everyone else.

  func testMicDominantClusterIsOnlyASuggestionWithoutAVoiceprint() {
    let me = UUID()
    let clusters = [
      SpeakerCluster(id: 0, embedding: emb(0.9), seconds: 30, micDominance: 0.95),  // mic voice
      SpeakerCluster(id: 1, embedding: diego, seconds: 20, micDominance: 0.05),  // remote
    ]
    // Self is designated but has never confirmed a voice — no auto, ever.
    let decisions = SpeakerMatch.identify(
      clusters: clusters, candidates: [], selfPersonID: me)
    let selfDecision = decisions.first { $0.clusterID == 0 }!
    XCTAssertEqual(selfDecision.personID, me)
    XCTAssertEqual(selfDecision.kind, .suggestion, "mic dominance may hint, never assign")
    XCTAssertEqual(selfDecision.channel, .mic)
    XCTAssertEqual(decisions.first { $0.clusterID == 1 }!.kind, .unnamed)
  }

  func testSelfWithVoiceprintAutoAssignsByVoice() {
    let me = UUID()
    let myVoice = emb(0.9)
    let candidates = [
      SpeakerMatch.Candidate(
        personID: me,
        voiceprints: [VoicePrint(embedding: myVoice, channel: .mic, sampleCount: 2, updatedAt: now)],
        isInvited: false)
    ]
    let clusters = [SpeakerCluster(id: 0, embedding: myVoice, seconds: 30, micDominance: 0.95)]
    let decisions = SpeakerMatch.identify(
      clusters: clusters, candidates: candidates, selfPersonID: me, quality: [0: .clean])
    let selfDecision = decisions.first { $0.clusterID == 0 }!
    XCTAssertEqual(selfDecision.personID, me)
    XCTAssertEqual(selfDecision.kind, .auto, "an enrolled voice is recognized like anyone's")
    XCTAssertGreaterThanOrEqual(selfDecision.confidence, 0.62)
  }

  /// The mic prior exists to break ties toward self, not to overcome a bad
  /// voice match: a borderline cosine score on a mic-dominant cluster tips
  /// over the auto threshold.
  func testMicDominancePriorTipsABorderlineSelfMatch() {
    let me = UUID()
    // Print at [1,0…]; cluster tilted so cosine lands just under 0.62.
    let print: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
    let tilted: [Float] = [0.60, 0.80, 0, 0, 0, 0, 0, 0]  // cosine = 0.60
    let candidates = [
      SpeakerMatch.Candidate(
        personID: me,
        voiceprints: [VoicePrint(embedding: print, channel: .mic, sampleCount: 1, updatedAt: now)],
        isInvited: false)
    ]
    let clusters = [SpeakerCluster(id: 0, embedding: tilted, seconds: 30, micDominance: 0.95)]
    let decisions = SpeakerMatch.identify(
      clusters: clusters, candidates: candidates, selfPersonID: me, quality: [0: .clean])
    XCTAssertEqual(decisions.first { $0.clusterID == 0 }!.kind, .auto)

    // The same score without mic dominance stays a suggestion.
    let remoteClusters = [SpeakerCluster(id: 0, embedding: tilted, seconds: 30, micDominance: 0.1)]
    let remoteCandidates = [
      SpeakerMatch.Candidate(
        personID: me,
        voiceprints: [
          VoicePrint(embedding: print, channel: .remote, sampleCount: 1, updatedAt: now)
        ],
        isInvited: false)
    ]
    // `.clean` on BOTH arms, so the only difference between them is the prior.
    // Without it this arm reads `.uncertain`, which forces `.suggestion` on its
    // own — and this was the one test in the suite pinning that a score below
    // `thresholds.auto` does not auto-assign. Deleting the score check passed
    // the whole suite until the quality argument was added here.
    let remoteDecisions = SpeakerMatch.identify(
      clusters: remoteClusters, candidates: remoteCandidates, selfPersonID: me,
      quality: [0: .clean])
    XCTAssertEqual(remoteDecisions.first { $0.clusterID == 0 }!.kind, .suggestion)
  }


  func testNoDesignatedSelfMeansNoSelfDecision() {
    let clusters = [
      SpeakerCluster(id: 0, embedding: emb(0.9), seconds: 30, micDominance: 0.95)
    ]
    let decisions = SpeakerMatch.identify(
      clusters: clusters, candidates: [], selfPersonID: nil)
    XCTAssertEqual(decisions.first!.kind, .unnamed)
    XCTAssertNil(decisions.first!.personID)
  }

  func testTwoMicVoicesSuggestOnlyTheLargest() {
    let me = UUID()
    let clusters = [
      SpeakerCluster(id: 0, embedding: emb(0.9), seconds: 30, micDominance: 0.9),
      SpeakerCluster(id: 1, embedding: emb(0.4), seconds: 25, micDominance: 0.85),  // 2nd in-room
    ]
    let decisions = SpeakerMatch.identify(clusters: clusters, candidates: [], selfPersonID: me)
    let selfDecision = decisions.first { $0.clusterID == 0 }!
    XCTAssertEqual(selfDecision.personID, me)
    XCTAssertEqual(selfDecision.kind, .suggestion)
    // The other in-room voice must not also be pinned on self.
    XCTAssertEqual(decisions.first { $0.clusterID == 1 }!.kind, .unnamed)
  }

  /// A voiceprint beats the heuristic: when self's voice matches cluster 1 but
  /// the mic-dominant cluster 0 is someone else in the room, self must follow
  /// the voice, and the mic cluster must not steal the suggestion.
  func testVoiceprintOutranksMicDominanceForSelf() {
    let me = UUID()
    let myVoice: [Float] = [0, 1, 0, 0, 0, 0, 0, 0]
    let candidates = [
      SpeakerMatch.Candidate(
        personID: me,
        voiceprints: [VoicePrint(embedding: myVoice, channel: .mic, sampleCount: 3, updatedAt: now)],
        isInvited: false)
    ]
    let clusters = [
      SpeakerCluster(id: 0, embedding: diego, seconds: 40, micDominance: 0.9),  // colleague in room
      SpeakerCluster(id: 1, embedding: myVoice, seconds: 20, micDominance: 0.8),  // me
    ]
    let decisions = SpeakerMatch.identify(
      clusters: clusters, candidates: candidates, selfPersonID: me, quality: [1: .clean])
    let mine = decisions.first { $0.personID == me }
    XCTAssertEqual(mine?.clusterID, 1, "voice match wins over louder mic cluster")
    XCTAssertEqual(mine?.kind, .auto)
  }

  func testRemoteVoiceprintMatchAutoAssignsAboveThreshold() {
    let diegoID = UUID()
    let candidates = [
      SpeakerMatch.Candidate(
        personID: diegoID,
        voiceprints: [VoicePrint(embedding: diego, channel: .remote, sampleCount: 3, updatedAt: now)],
        isInvited: true)
    ]
    let clusters = [SpeakerCluster(id: 5, embedding: diego, seconds: 40, micDominance: 0.1)]
    let decisions = SpeakerMatch.identify(
      clusters: clusters, candidates: candidates, selfPersonID: nil, quality: [5: .clean])
    let d = decisions.first { $0.clusterID == 5 }!
    XCTAssertEqual(d.personID, diegoID)
    XCTAssertEqual(d.kind, .auto)  // cosine 1.0 + invited prior
  }

  func testGreedyOneToOnePreventsDoubleClaim() {
    let diegoID = UUID()
    let candidates = [
      SpeakerMatch.Candidate(
        personID: diegoID,
        voiceprints: [VoicePrint(embedding: diego, channel: .remote, sampleCount: 1, updatedAt: now)],
        isInvited: true)
    ]
    // Two remote clusters, one matches Diego perfectly, the other only weakly.
    let clusters = [
      SpeakerCluster(id: 0, embedding: diego, seconds: 30, micDominance: 0.1),
      SpeakerCluster(id: 1, embedding: [0.9, 0.1, 0, 0, 0, 0, 0, 0], seconds: 20, micDominance: 0.1),
    ]
    let decisions = SpeakerMatch.identify(
      clusters: clusters, candidates: candidates, selfPersonID: nil)
    // Diego claimed by exactly one cluster; the other cannot also be Diego.
    let claimedByDiego = decisions.filter { $0.personID == diegoID }
    XCTAssertEqual(claimedByDiego.count, 1)
    XCTAssertEqual(claimedByDiego.first?.clusterID, 0)  // the perfect match
  }

  func testNoneOfTheAboveStaysUnnamed() {
    let strangerCandidate = [
      SpeakerMatch.Candidate(
        personID: UUID(),
        voiceprints: [VoicePrint(embedding: priya, channel: .remote, sampleCount: 1, updatedAt: now)],
        isInvited: false)
    ]
    // Cluster orthogonal to the only known voiceprint → below threshold.
    let clusters = [SpeakerCluster(id: 0, embedding: diego, seconds: 30, micDominance: 0.1)]
    let decisions = SpeakerMatch.identify(
      clusters: clusters, candidates: strangerCandidate, selfPersonID: nil)
    XCTAssertEqual(decisions.first!.kind, .unnamed)
    XCTAssertNil(decisions.first!.personID)
  }

  func testChannelMismatchDoesNotMatch() {
    // Diego enrolled only on the mic channel; a remote cluster must not match.
    let diegoID = UUID()
    let candidates = [
      SpeakerMatch.Candidate(
        personID: diegoID,
        voiceprints: [VoicePrint(embedding: diego, channel: .mic, sampleCount: 1, updatedAt: now)],
        isInvited: true)
    ]
    let clusters = [SpeakerCluster(id: 0, embedding: diego, seconds: 30, micDominance: 0.05)]
    let decisions = SpeakerMatch.identify(
      clusters: clusters, candidates: candidates, selfPersonID: nil)
    XCTAssertEqual(decisions.first!.kind, .unnamed)  // no same-channel print
  }

  func testEnrollmentEMA() {
    var prints: [VoicePrint] = []
    prints = SpeakerMatch.enroll(embedding: [1, 0], channel: .remote, into: prints, at: now)
    XCTAssertEqual(prints.count, 1)
    XCTAssertEqual(prints[0].sampleCount, 1)
    // Merge a second sample — running mean toward [0, 1].
    prints = SpeakerMatch.enroll(embedding: [0, 1], channel: .remote, into: prints, at: now)
    XCTAssertEqual(prints[0].sampleCount, 2)
    XCTAssertEqual(prints[0].embedding[0], 0.5, accuracy: 0.001)
    XCTAssertEqual(prints[0].embedding[1], 0.5, accuracy: 0.001)
    // A different channel is a separate print.
    prints = SpeakerMatch.enroll(embedding: [1, 1], channel: .mic, into: prints, at: now)
    XCTAssertEqual(prints.count, 2)
  }
}

final class DiarizationAlignmentTests: XCTestCase {






}

final class PersonaGateTests: XCTestCase {
}
