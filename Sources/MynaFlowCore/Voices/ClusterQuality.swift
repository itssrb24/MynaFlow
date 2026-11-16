import Foundation

// MARK: - Cluster quality (pure)
// Ported from the Myna app; thresholds are its measured ones, unchanged.
// Decides whether a diarization cluster may be treated as one person's voice.
// Policy only: the geometry it reads is computed by `ClusterSplit`.

public enum ClusterQuality {
  /// How much a cluster may be trusted to be one person.
  ///
  /// `uncertain` is the state for evidence that is suggestive but not proof —
  /// including "never measured", which is every cluster recorded before
  /// quality was persisted. It withholds machine action without forbidding a
  /// human answer, because hard-blocking every pre-existing meeting would
  /// strand a whole back catalogue to prevent a hypothesis.
  public enum State: String, Codable, Equatable, Sendable {
    case clean
    case uncertain
    case mixed

    /// Only a cluster proven to be one voice may teach a voiceprint. This is
    /// the rule that stops a mixed cluster poisoning future recognition.
    public var allowsEnrollment: Bool { self == .clean }

    /// The machine never assigns a name on its own below `clean`.
    public var allowsAutoAssign: Bool { self == .clean }

    /// A human may still confirm what was merely unmeasured; they may not
    /// confirm what was measured to hold two people.
    public var allowsBulkConfirm: Bool { self != .mixed }

    /// Always true. Correcting one line is the escape hatch out of every bad
    /// state, and blocking it would trap the user with a wrong transcript.
    public var allowsPerLineCorrection: Bool { true }
  }

  public struct Evidence: Equatable, Sendable {
    /// Weighted mean cosine to the cluster centroid. `nil` = never measured.
    public let cohesion: Double?
    /// The split measurement, whole or absent. Never partial: a cluster is
    /// either split-measured or it is not, and five independently-nillable
    /// fields let "measured, separation 2.3, sample size unknown" be
    /// expressed — a state the domain does not have, which resolved to
    /// `clean` and cleared a never-checked cluster to teach a voiceprint.
    public let split: ClusterSplit.Halves?
    /// Distinct non-nil speaker IDs across the cluster's stored segments.
    /// Always available — it needs no audio.
    public let distinctPersonIDs: Int
    /// The cluster's turns disagree about mic vs remote.
    public let channelConflict: Bool

    // NOTE: cluster duration is deliberately absent. `SpeakerMatch.Thresholds`
    // already filters clusters below `minSeconds` upstream, and
    // `split.minoritySeconds` covers the only duration question this policy
    // asks. A required parameter no rule reads would suggest duration
    // participates in the verdict when it does not.

    public init(
      cohesion: Double?, split: ClusterSplit.Halves?,
      distinctPersonIDs: Int, channelConflict: Bool
    ) {
      self.cohesion = cohesion
      self.split = split
      self.distinctPersonIDs = distinctPersonIDs
      self.channelConflict = channelConflict
    }
  }

  /// Starting values, calibrated against a real mixed 1:1 in Task 10. They are
  /// deliberately in one place so tuning never touches the geometry.
  public struct Thresholds: Equatable, Sendable {
    /// Separation at or above which two halves are two people.
    public var mixedSeparation: Double
    /// The smaller half must be this much of the cluster …
    public var minMinorityShare: Double
    /// … and this many seconds. Both, so neither a brief outlier nor a
    /// proportionally large sliver of a tiny cluster can invent a speaker.
    public var minMinoritySeconds: Double
    /// Fewest turn embeddings a split may be believed over. Below this,
    /// `separation` is an artefact of fitting two centroids to too few points
    /// rather than evidence of two voices.
    ///
    /// This is the binding constraint on the whole gate — far more than
    /// `mixedSeparation`, where anything in 1.2...3.0 behaves identically once
    /// n is adequate. Worst-case separation over 30 seeds for a CLEAN
    /// single-voice cluster, at cohesion matched to the real mixed meeting's
    /// 0.810:
    ///
    ///     n     8     10    12    14    16    20    30
    ///     sep   1.90  1.79  1.71  1.63  1.45  0.82  0.55
    ///
    /// A clean cluster can therefore exceed a 1.6 threshold all the way to
    /// n=14. 16 is the bare minimum with no headroom; 20 leaves real headroom
    /// (0.82 against 1.6). An earlier draft of this plan said 10, which would
    /// have reintroduced the exact false positive the floor exists to prevent.
    public var minSplitSample: Int
    /// Smallest absolute gap between the two half-centroids that may count as
    /// two voices. `separation` is a RATIO, so a physically meaningless gap
    /// divided by a near-zero spread still yields a large number: 20 exact
    /// copies of one embedding plus 20 of another at cosine 0.9999 — one voice,
    /// quantised — measures separation 100 with every other guard satisfied.
    /// Requiring an absolute gap is what stops a ratio speaking for a
    /// difference that is not there.
    public var minBetweenGap: Double
    /// Separation at or above which a cluster is no longer credibly one voice,
    /// even when it falls short of `mixedSeparation` or of the trust floors.
    ///
    /// This is what stops the trust floors cutting both ways. `minSplitSample`
    /// and `minBetweenGap` live inside the mixed rule, so when they fail the
    /// verdict used to fall through to `clean` — meaning a measurement too weak
    /// to convict was read as proof of innocence. A genuinely two-person
    /// 10-turn cluster measures separation around 14.9 and would have been
    /// auto-assigned and enrolled. Clean clusters at an adequate sample top out
    /// near 0.82, so anything at or above 1.0 is outside the single-voice
    /// distribution and belongs in `uncertain` whatever else is true of it.
    public var uncertainSeparation: Double
    /// Below this centroid-mean cosine, a cluster is too loose to trust even
    /// when it does not visibly split.
    public var uncertainCohesion: Double
    /// Seconds of channel evidence required on BOTH sides before a cluster's
    /// turns count as two sources. Shares a value with `minMinoritySeconds`
    /// today and for the same reason — one stray turn is drift, not a source —
    /// but they guard different things and must stay separately tunable: this
    /// one measures covered channel evidence, that one measures a duration
    /// split among embeddings.
    public var minChannelConflictSeconds: Double
    /// Floor on `RecheckPlan`'s identity check: the cosine between a cluster's
    /// STORED centroid and the freshly re-derived one at the same cluster
    /// index. Cluster IDs are first-appearance ordinals per diarization run,
    /// not stable identities — `audioRetention` pruning a chunk, `loadMono16k`
    /// silently `continue`-ing past a bad file, or a model update can all
    /// renumber them, so "same index" is not "same voice" on its own. The
    /// same voice's centroid from the same recording — even averaged from a
    /// pruned subset of its turns — sits near 1.0; two different voices sit
    /// around 0.3-0.5. Below this floor the index join is not trusted, and a
    /// re-check updates quality only, leaving the stored centroid untouched.
    ///
    /// Provisional: 0.85 is a reasonable gap above the different-voices band
    /// and below the same-voice band, but it has not been measured against
    /// real re-check runs. Task 10 measures it on the real clusters.
    public var minRecheckIdentity: Double

    public init(
      mixedSeparation: Double = 1.6,
      minMinorityShare: Double = 0.12,
      minMinoritySeconds: Double = 8,
      minSplitSample: Int = 20,
      minBetweenGap: Double = 0.05,
      uncertainSeparation: Double = 1.0,
      uncertainCohesion: Double = 0.75,
      minChannelConflictSeconds: Double = 8,
      minRecheckIdentity: Double = 0.85
    ) {
      self.mixedSeparation = mixedSeparation
      self.minMinorityShare = minMinorityShare
      self.minMinoritySeconds = minMinoritySeconds
      self.minSplitSample = minSplitSample
      self.minBetweenGap = minBetweenGap
      self.uncertainSeparation = uncertainSeparation
      self.uncertainCohesion = uncertainCohesion
      self.minChannelConflictSeconds = minChannelConflictSeconds
      self.minRecheckIdentity = minRecheckIdentity
    }

    public static let `default` = Thresholds()
  }

  /// Rules in order. Only the first two reach `mixed`, and both are direct
  /// evidence of two identities: stored assignments that disagree, or two
  /// acoustically separated halves. Everything weaker lands in `uncertain`.
  public static func state(
    for evidence: Evidence, thresholds: Thresholds = .default
  ) -> State {
    if evidence.distinctPersonIDs > 1 { return .mixed }

    if let split = evidence.split, splitProvesTwoVoices(split, thresholds: thresholds) {
      return .mixed
    }

    // Measured as split, but not provably two people — either the sample and
    // gap floors above were not met, or the separation sits below
    // `mixedSeparation`. Both are suggestive and neither is proof, which is the
    // definition of `uncertain`. Without this the floors were one-directional:
    // they protected a clean cluster from false accusation while letting an
    // untrustworthy one be certified clean and enrolled.
    if let split = evidence.split, split.separation >= thresholds.uncertainSeparation {
      return .uncertain
    }

    guard let cohesion = evidence.cohesion else { return .uncertain }
    if evidence.channelConflict { return .uncertain }
    if cohesion < thresholds.uncertainCohesion { return .uncertain }

    // Cohesion alone never certifies. The mixed cluster that motivated this
    // gate measured 0.810 centroid-mean — squarely inside the clean band —
    // which is the whole reason the split test exists. A cluster whose
    // two-voice check never ran is unmeasured, not proven.
    // A zero-filled `Halves` is not a measurement either. Nothing stops a
    // caller writing "no split found, so zeros" instead of returning nil, and
    // that shape clears every rule above: totalCount 0 fails the sample floor
    // so the mixed rule skips, separation 0 is below `uncertainSeparation` so
    // that rule skips, and a present cohesion then certifies it. Requiring two
    // embeddings is the floor below which `ClusterSplit` itself refuses to
    // measure, so anything under it was fabricated rather than observed.
    guard let split = evidence.split, split.totalCount >= 2 else { return .uncertain }

    return .clean
  }

  /// Rule 2 of `state(for:)` on its own: the split clears every trust floor
  /// AND separates. This is the only rule whose evidence names LINES — the
  /// minority half — so it is the only one that may light up per-line
  /// markers. Rule 1 (disagreeing assignments) says two identities exist
  /// but nothing about which lines: on a real 1:1, one hand-corrected line
  /// made a single speaker's cluster `mixed`, and gating the markers on the
  /// combined state flagged 80 lines of that one person's own voice.
  public static func splitProvesTwoVoices(
    _ split: ClusterSplit.Halves, thresholds: Thresholds = .default
  ) -> Bool {
    split.totalCount >= thresholds.minSplitSample
      && split.betweenGap >= thresholds.minBetweenGap
      && split.separation >= thresholds.mixedSeparation
      && split.minorityShare >= thresholds.minMinorityShare
      && split.minoritySeconds >= thresholds.minMinoritySeconds
  }

}
