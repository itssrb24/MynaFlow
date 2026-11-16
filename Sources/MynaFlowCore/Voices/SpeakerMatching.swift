import Foundation

// MARK: - Speaker matching (pure)
// Given diarization clusters (each a voice with an embedding + how much it came
// from the mic vs the remote channel) and the people we know, decide who each
// cluster is. Everything here is pure and deterministic so the identity logic
// is fully testable without CoreML. The FluidAudio-driven diarization that
// produces the clusters lives in the app layer.

/// One diarized voice across a meeting, ready for identity matching.
public struct SpeakerCluster: Equatable, Sendable {
  public let id: Int
  public let embedding: [Float]
  /// Total speaking time — larger clusters are more reliable to match/enroll.
  public let seconds: Double
  /// Fraction of this cluster's speech that came from the mic (0 = all remote,
  /// 1 = all mic), from the pre-mix channel energy track.
  public let micDominance: Double

  public init(id: Int, embedding: [Float], seconds: Double, micDominance: Double) {
    self.id = id
    self.embedding = embedding
    self.seconds = seconds
    self.micDominance = micDominance
  }

  public var channel: VoiceChannel { micDominance >= 0.5 ? .mic : .remote }
}

public enum SpeakerMatch {
  /// Tuning constants — deliberately conservative so auto-assignment errs
  /// toward "ask" rather than "guess wrong". Refine from real meetings.
  /// Highest confidence an automatic match may record.
  ///
  /// `1.0` is reserved for a cluster the user confirmed — `confirmCluster`
  /// writes exactly that, and `PersonaGate` has always documented it as the
  /// confirmed marker. Cosine similarity plus the invited and mic priors can
  /// exceed 1, and clamping that to `1.0` made the *best* automatic match
  /// indistinguishable in storage from a human answer: it was offered a Remove
  /// control it should never have had, and rendered as settled rather than
  /// matched. Staying strictly below keeps the value meaning one thing.
  public static let automaticCeiling = 0.99

  public struct Thresholds: Sendable {
    public var auto: Double  // ≥ → auto-assign
    public var suggest: Double  // [suggest, auto) → one-tap suggestion
    public var micSelf: Double  // mic dominance to treat a cluster as "me"
    public var minSeconds: Double  // ignore blips too short to trust

    public init(
      auto: Double = 0.62, suggest: Double = 0.45, micSelf: Double = 0.65,
      minSeconds: Double = 1.5
    ) {
      self.auto = auto
      self.suggest = suggest
      self.micSelf = micSelf
      self.minSeconds = minSeconds
    }

    public static let `default` = Thresholds()
  }

  public enum Kind: String, Equatable, Sendable {
    case auto  // confident — assign silently, may enroll + feed memory
    case suggestion  // plausible — show a one-tap confirm chip
    case unnamed  // no confident match — offer the attendee list
  }

  public struct Decision: Equatable, Sendable {
    public let clusterID: Int
    public let personID: UUID?
    public let confidence: Double
    public let kind: Kind
    public let channel: VoiceChannel

    public init(
      clusterID: Int, personID: UUID?, confidence: Double, kind: Kind, channel: VoiceChannel
    ) {
      self.clusterID = clusterID
      self.personID = personID
      self.confidence = confidence
      self.kind = kind
      self.channel = channel
    }
  }

  public struct Candidate: Equatable, Sendable {
    public let personID: UUID
    public let voiceprints: [VoicePrint]
    public let isInvited: Bool  // attendee of THIS meeting — a strong prior

    public init(personID: UUID, voiceprints: [VoicePrint], isInvited: Bool) {
      self.personID = personID
      self.voiceprints = voiceprints
      self.isInvited = isInvited
    }
  }

  // MARK: Similarity

  public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot = 0.0
    var na = 0.0
    var nb = 0.0
    for index in a.indices {
      let x = Double(a[index])
      let y = Double(b[index])
      dot += x * y
      na += x * x
      nb += y * y
    }
    guard na > 0, nb > 0 else { return 0 }
    return dot / (na.squareRoot() * nb.squareRoot())
  }

  // MARK: Identify

  /// Decides an identity for each cluster. Everyone — self included — is
  /// matched by voiceprint; mic dominance and the invite list act only as
  /// priors. A self with no enrolled voiceprint gets at most a "(You?)"
  /// suggestion on the mic-dominant cluster: the app never decides who the
  /// user is until they have said so once, after which their enrolled voice
  /// carries the recognition. Greedy one-to-one so two clusters never claim
  /// one person.
  public static func identify(
    clusters: [SpeakerCluster],
    candidates: [Candidate],
    selfPersonID: UUID?,
    quality: [Int: ClusterQuality.State] = [:],
    thresholds: Thresholds = .default
  ) -> [Decision] {
    var decisions: [Decision] = []
    var claimed = Set<UUID>()  // one person per cluster

    // 1. Voiceprint pass: cosine against same-channel prints. Self competes
    //    here like anyone else; their mic-dominant clusters get a small prior
    //    (mirroring the invitee nudge) because the mic channel is real
    //    evidence — just no longer a verdict.
    struct Pair {
      let cluster: SpeakerCluster
      let personID: UUID
      let score: Double
    }
    var pairs: [Pair] = []
    for cluster in clusters {
      guard cluster.seconds >= thresholds.minSeconds else { continue }
      for candidate in candidates {
        let sameChannel = candidate.voiceprints.filter { $0.channel == cluster.channel }
        guard !sameChannel.isEmpty else { continue }
        let best = sameChannel.map { cosine($0.embedding, cluster.embedding) }.max() ?? 0
        // Small prior nudges — never enough to override a clearly-better
        // match, just to break near-ties.
        let invitedPrior = candidate.isInvited ? 0.03 : 0
        let micPrior =
          (candidate.personID == selfPersonID && cluster.micDominance >= thresholds.micSelf)
          ? 0.03 : 0
        pairs.append(
          Pair(
            cluster: cluster, personID: candidate.personID,
            score: best + invitedPrior + micPrior))
      }
    }
    pairs.sort { $0.score > $1.score }

    var assignedClusters = Set<Int>()
    for pair in pairs {
      guard !assignedClusters.contains(pair.cluster.id), !claimed.contains(pair.personID)
      else { continue }
      guard pair.score >= thresholds.suggest else { continue }
      // A cluster absent from the map was never measured, which is
      // `uncertain` — not clean. Only a cluster proven to hold one voice may
      // reach `.auto`, because `.auto` is the single predicate
      // `SpeakerDiarizer` enrolls on: demoting here closes the automatic
      // learning path without touching the enrollment code.
      let state = quality[pair.cluster.id] ?? .uncertain
      let confident = pair.score >= thresholds.auto && state.allowsAutoAssign
      let kind: Kind = confident ? .auto : .suggestion
      // A demotion must show up in the NUMBER too, not only in `kind`.
      // `kind` is consumed once, here in the pipeline; the confidence is what
      // gets written onto every segment, and `VoiceReview.matchKind` — which
      // the transcript's "~" marker, `isRemovable` and the legacy withdrawal
      // fallback all read — classifies from that number alone. Storing the raw
      // 0.80 of a match the gate had just refused made the stored row say
      // `.automatic` while the decision said `.suggestion`. The ceiling sits
      // just below `auto` so the two readings of one decision agree.
      let ceiling =
        confident ? automaticCeiling : min(automaticCeiling, thresholds.auto - 0.001)
      decisions.append(
        Decision(
          clusterID: pair.cluster.id, personID: pair.personID,
          confidence: min(ceiling, pair.score), kind: kind,
          channel: pair.cluster.channel))
      assignedClusters.insert(pair.cluster.id)
      claimed.insert(pair.personID)
    }

    // 2. Self bootstrap: a designated self whose voice was not recognized
    //    above (typically: no voiceprint enrolled yet) gets a suggestion on
    //    the largest mic-dominant cluster — "(You?)", one tap to confirm and
    //    enroll. Suggestion ONLY: mic dominance never auto-assigns.
    if let selfPersonID, !claimed.contains(selfPersonID) {
      let micClusters = clusters
        .filter {
          !assignedClusters.contains($0.id) && $0.micDominance >= thresholds.micSelf
            && $0.seconds >= thresholds.minSeconds
        }
        .sorted { $0.seconds > $1.seconds }
      if let primary = micClusters.first {
        decisions.append(
          Decision(
            clusterID: primary.id, personID: selfPersonID,
            confidence: min(0.5, primary.micDominance / 2),
            kind: .suggestion, channel: .mic))
        claimed.insert(selfPersonID)
        assignedClusters.insert(primary.id)
      }
    }

    // 3. Anything left with no confident match is an unnamed cluster.
    for cluster in clusters where !assignedClusters.contains(cluster.id) {
      decisions.append(
        Decision(
          clusterID: cluster.id, personID: nil, confidence: 0, kind: .unnamed,
          channel: cluster.channel))
    }
    return decisions.sorted { $0.clusterID < $1.clusterID }
  }

  // MARK: Enrollment

  /// Removes one previously enrolled sample from a person's voiceprint.
  ///
  /// `enroll` is a sample-count-weighted running mean, so it has an exact
  /// inverse: multiply back up by the old count, subtract the sample, divide
  /// by one fewer. Without this the learning loop had no brake — a cluster
  /// that auto-matched at the 0.62 threshold was folded in immediately, and
  /// correcting the assignment afterwards changed only the segment rows. The
  /// stored voice kept drifting toward whoever it had been confused with,
  /// which makes the next confusion likelier, and the only escape was
  /// discarding every sample the person had.
  ///
  /// Inert when there is nothing to remove: an absent channel, or a stored
  /// print from a different model revision (dimension mismatch), is returned
  /// untouched rather than being reshaped into noise.
  public static func unenroll(
    embedding: [Float], channel: VoiceChannel, from voiceprints: [VoicePrint], at date: Date
  ) -> [VoicePrint] {
    guard let index = voiceprints.firstIndex(where: { $0.channel == channel }) else {
      return voiceprints
    }
    let existing = voiceprints[index]
    guard existing.embedding.count == embedding.count else { return voiceprints }

    var result = voiceprints
    // The last sample leaves no mean to keep. A zero vector would still be
    // compared against every cluster and would match arbitrarily, so the
    // voiceprint goes away entirely.
    guard existing.sampleCount > 1 else {
      result.remove(at: index)
      return result
    }
    let n = Double(existing.sampleCount)
    let reduced = zip(existing.embedding, embedding).map { mean, sample -> Float in
      Float((Double(mean) * n - Double(sample)) / (n - 1))
    }
    result[index] = VoicePrint(
      embedding: reduced, channel: channel, sampleCount: existing.sampleCount - 1,
      updatedAt: date)
    return result
  }

  /// Pools two learned voiceprints for the same channel into one.
  ///
  /// `enroll` folds one new sample into a mean of n; this folds a mean of m
  /// into a mean of n, which is the same arithmetic with the weight generalized.
  /// Combining is what makes merging two records of one human an improvement
  /// rather than a loss: keeping only the survivor's print would throw away
  /// real enrollment and make the next auto-match worse.
  ///
  /// A dimension mismatch means one print predates a model revision. There is
  /// no meaningful average between them, so the newer one survives whole —
  /// the same refusal `unenroll` makes rather than reshaping into noise.
  public static func combine(_ a: VoicePrint, _ b: VoicePrint) -> VoicePrint {
    guard a.embedding.count == b.embedding.count else {
      return a.updatedAt >= b.updatedAt ? a : b
    }
    let weightA = Double(max(a.sampleCount, 0))
    let weightB = Double(max(b.sampleCount, 0))
    let total = weightA + weightB
    guard total > 0 else { return a.updatedAt >= b.updatedAt ? a : b }
    let pooled = zip(a.embedding, b.embedding).map { left, right -> Float in
      Float((Double(left) * weightA + Double(right) * weightB) / total)
    }
    return VoicePrint(
      embedding: pooled, channel: a.channel, sampleCount: a.sampleCount + b.sampleCount,
      updatedAt: max(a.updatedAt, b.updatedAt))
  }

  /// Folds a confirmed cluster's embedding into a person's channel voiceprint
  /// with a sample-count-weighted running mean (older enrollments stay stable
  /// as more samples arrive). Creates the channel voiceprint if absent.
  public static func enroll(
    embedding: [Float], channel: VoiceChannel, into voiceprints: [VoicePrint], at date: Date
  ) -> [VoicePrint] {
    var result = voiceprints
    if let index = result.firstIndex(where: { $0.channel == channel }) {
      let existing = result[index]
      guard existing.embedding.count == embedding.count else {
        result[index] = VoicePrint(
          embedding: embedding, channel: channel, sampleCount: 1, updatedAt: date)
        return result
      }
      let n = Double(existing.sampleCount)
      let merged = zip(existing.embedding, embedding).map { old, new -> Float in
        Float((Double(old) * n + Double(new)) / (n + 1))
      }
      result[index] = VoicePrint(
        embedding: merged, channel: channel, sampleCount: existing.sampleCount + 1,
        updatedAt: date)
    } else {
      result.append(
        VoicePrint(embedding: embedding, channel: channel, sampleCount: 1, updatedAt: date))
    }
    return result
  }
}
