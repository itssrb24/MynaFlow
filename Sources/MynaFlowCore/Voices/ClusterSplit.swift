import Foundation

// MARK: - Cluster self-split (pure)
// Splits one diarization cluster's own turn embeddings in two and measures how
// cleanly they come apart. Measurement only: no thresholds, no verdict. The
// policy that reads these numbers is `ClusterQuality`.

/// Why separation rather than cohesion.
///
/// A cluster holding two people splits into two tight, distant halves. One
/// person recorded across varied acoustics is a diffuse blob that gets halved
/// through its middle, leaving the halves no further apart than the points
/// inside them. Mean cohesion cannot tell those apart: a real 1:1 measured
/// 0.810 centroid-mean cosine while containing both speakers, which is where
/// genuinely clean clusters also sit. A threshold low enough to catch it would
/// condemn good meetings, and a gate that cries wolf gets ignored.
public enum ClusterSplit {
  /// NOTE: this is a PERSISTED schema, not only an in-memory measurement — it
  /// is stored whole inside `MeetingClusterProfile`. Any field added here must
  /// be optional, because `EncryptedLocalStore` decodes rows with `try?` and
  /// silently DROPS any that fail. A new non-optional field would therefore not
  /// error; it would quietly delete every cluster profile written before it,
  /// and those profiles hold the only centroid that can withdraw a
  /// contaminated voiceprint once the audio is gone.
  public struct Halves: Equatable, Sendable, Codable {
    /// Cosine distance between the two half-centroids. Clamped to `0` — the
    /// dot product of two unit vectors can round fractionally above `1`,
    /// which would otherwise store a nonsense negative distance.
    ///
    /// Callers MUST also require a minimum absolute `betweenGap`, not
    /// `separation` alone: 20 exact copies of one embedding plus 20 exact
    /// copies of a near-identical one (cosine 0.9999 — one voice, quantised)
    /// measures `separation = 100` — fifty times the genuinely mixed
    /// fixture below — from a `betweenGap` of 0.0001, which is physically
    /// nothing. Every sample-size and balance guard passes on that input;
    /// only a floor on `betweenGap` itself catches it.
    public let betweenGap: Double
    /// Weighted mean cosine distance from each embedding to its own half's
    /// centroid. Clamped to `0` for the same floating-point reason.
    public let withinSpread: Double
    /// `betweenGap / withinSpread`. ~1 means a blob cut in half; well above
    /// means two populations. Meaningless without also checking `betweenGap`
    /// itself — see its doc.
    public let separation: Double
    /// The smaller-by-weight half's share of total weight (0...0.5). This
    /// and `minoritySeconds` describe the same half; `smallestHalfCount`
    /// deliberately does not (see its doc).
    public let minorityShare: Double
    /// The smaller-by-weight half's absolute weight. Weights are turn
    /// seconds, so this is how long the second voice spoke.
    public let minoritySeconds: Double
    /// Number of embeddings in each half, counted after unusable turns are
    /// dropped — so `countA + countB` is what was actually measured, not what
    /// was handed in.
    public let countA: Int
    public let countB: Int

    /// The smaller-by-COUNT half's size — `min(countA, countB)`, not
    /// derived from weight. This is deliberately NOT the same half as
    /// `minorityShare`/`minoritySeconds` when turn durations are uneven:
    /// `separation`'s small-sample bias comes from population (fewer points
    /// make a flimsier centroid), not duration, so the guard against it must
    /// count turns, not seconds. A cluster with a 4-turn/100s-each half and a
    /// 30-turn/2s-each half has `smallestHalfCount == 4` (guards the
    /// small-sample bias) while `minoritySeconds == 60` (guards against a
    /// manufactured split) — two different, individually correct answers
    /// about two different halves. A caller that treats them as describing
    /// one half will be wrong.
    public var smallestHalfCount: Int { min(countA, countB) }

    /// How many embeddings `separation` was measured over.
    ///
    /// Callers MUST refuse to read `separation` as evidence below a minimum
    /// sample size; this count is how they can. `withinSpread` is the scatter
    /// of points around centroids fitted to those same points, so it is
    /// downward-biased by roughly `(1 - 2/n)` and is exactly zero at `n == 2`,
    /// where each half is a single point and therefore its own centroid. A
    /// CLEAN single-voice two-turn cluster measures a `separation` in the
    /// hundreds of thousands, and passes every balance guard besides — two
    /// turns split evenly, with ample duration on each side.
    ///
    /// The bias does not vanish quickly. Worst-case `separation` over 30 seeds
    /// for a clean single voice, at cohesion matched to a real mixed meeting's
    /// 0.810:
    ///
    ///     n     8     10    12    14    16    20    30
    ///     sep   1.90  1.79  1.71  1.63  1.45  0.82  0.55
    ///
    /// A clean cluster can therefore clear a threshold of 1.6 all the way to
    /// n=14. This is deliberately reported rather than corrected for: a
    /// degrees-of-freedom fudge factor would bury the problem, where an honest
    /// `n` lets policy refuse to judge.
    public var totalCount: Int { countA + countB }

    public init(
      betweenGap: Double, withinSpread: Double, separation: Double,
      minorityShare: Double, minoritySeconds: Double, countA: Int, countB: Int
    ) {
      self.betweenGap = betweenGap
      self.withinSpread = withinSpread
      self.separation = separation
      self.minorityShare = minorityShare
      self.minoritySeconds = minoritySeconds
      self.countA = countA
      self.countB = countB
    }
  }

  /// Floor on `withinSpread` before dividing. Identical embeddings give a
  /// spread of exactly zero, and the ratio has to stay finite.
  static let epsilon = 1e-6
  /// 2-means on turn embeddings converges in a handful of steps in practice;
  /// this is a backstop against oscillation, not a tuned budget. Hitting the
  /// cap without `changed` going false means the assignment is flapping
  /// between two unstable centroids — a sign of shot-noise-level geometry,
  /// not two real populations — and the loop simply reports whatever the
  /// last iteration settled on rather than spinning forever.
  static let maxIterations = 20

  /// Weighted mean cosine similarity to the cluster centroid — the "centroid
  /// mean" statistic. `nil` only when there are fewer than two usable
  /// embeddings or their dimensions disagree; a valid centroid always
  /// produces a value.
  ///
  /// Note for callers: this used to return `1.0` for a single-embedding
  /// cluster before the `>= 2` floor moved here; a single-turn cluster
  /// already sitting in a user's database will now resolve to `nil`
  /// (unmeasurable) instead of a perfect score. That is the conservative
  /// direction — one turn is not enough to claim anything — but it is a
  /// real change in what those clusters report, not just a refactor.
  public static func cohesion(embeddings: [[Float]], weights: [Double]) -> Double? {
    guard let points = unitPoints(embeddings, weights) else { return nil }
    guard let centre = centroid(points.vectors, weights: points.weights) else { return nil }
    var total = 0.0
    var accumulated = 0.0
    for (vector, weight) in zip(points.vectors, points.weights) {
      accumulated += dot(vector, centre) * weight
      total += weight
    }
    guard total > 0 else { return nil }
    return accumulated / total
  }

  /// 2-means over the cluster's embeddings.
  ///
  /// `nil` means "cannot measure": fewer than two usable embeddings (after
  /// dropping non-positive-weight turns), ragged dimensions — one embedding
  /// predates a model revision, and there is no meaningful geometry between
  /// them, the same refusal `SpeakerMatch.unenroll` makes — or a zero-norm
  /// embedding, which is the model producing no direction at all rather than
  /// a bad duration.
  ///
  /// A non-nil result with `separation == 0` means the opposite: the split
  /// was measured and 2-means found only one mode (e.g. every embedding is
  /// identical). That is evidence of a single voice, not an absence of
  /// evidence, so it must not be conflated with the unmeasurable case above.
  public static func split(embeddings: [[Float]], weights: [Double]) -> Halves? {
    measure(embeddings: embeddings, weights: weights)?.halves
  }

  /// The split plus WHICH turns fell in the minority half. Not Codable and
  /// not persisted: `Halves` is the stored schema, and the membership goes
  /// to the segment rows instead, where the transcript can mark each line.
  public struct Split: Equatable, Sendable {
    public let halves: Halves
    /// Indices into the CALLER's `embeddings` — not the internal array that
    /// has dropped non-positive-weight turns — ascending, so a "jump to the
    /// first flagged line" reads the first element. Empty when 2-means found
    /// one mode. Minority is by WEIGHT, the same half `minoritySeconds`
    /// reports, so the strip and the transcript describe the same voice.
    public let minorityIndices: [Int]
  }

  public static func measure(embeddings: [[Float]], weights: [Double]) -> Split? {
    guard let points = unitPoints(embeddings, weights) else { return nil }
    let vectors = points.vectors
    let pointWeights = points.weights
    let originalIndices = points.originalIndices

    guard var (centreA, centreB) = farthestPair(seedCandidates(vectors)) else { return nil }

    var assignment = [Bool](repeating: false, count: vectors.count)  // true = half B
    for _ in 0..<maxIterations {
      var changed = false
      for index in vectors.indices {
        let toB = dot(vectors[index], centreB) > dot(vectors[index], centreA)
        if toB != assignment[index] {
          assignment[index] = toB
          changed = true
        }
      }
      let a = centroid(
        pick(vectors, assignment, half: false),
        weights: pick(pointWeights, assignment, half: false))
      let b = centroid(
        pick(vectors, assignment, half: true),
        weights: pick(pointWeights, assignment, half: true))
      // A half going empty mid-iteration means this assignment has collapsed
      // to one mode. Stop here rather than compute a centroid from nothing —
      // the final tally below reads this same (now one-sided) `assignment`
      // and reports it as a real, zero-separation finding.
      guard let a, let b else { break }
      centreA = a
      centreB = b
      if !changed { break }
    }

    let countA = assignment.filter { !$0 }.count
    let countB = assignment.filter { $0 }.count
    let weightA = zip(pointWeights, assignment).filter { !$0.1 }.map(\.0).reduce(0, +)
    let weightB = zip(pointWeights, assignment).filter { $0.1 }.map(\.0).reduce(0, +)
    let total = weightA + weightB
    guard total > 0 else { return nil }

    guard weightA > 0, weightB > 0 else {
      // 2-means found only one mode. This is a measured result, not a
      // failure to measure: report it as zero separation rather than nil.
      return Split(
        halves: Halves(
          betweenGap: 0, withinSpread: 0, separation: 0,
          minorityShare: 0, minoritySeconds: 0, countA: countA, countB: countB),
        minorityIndices: [])
    }

    var spread = 0.0
    for (index, vector) in vectors.enumerated() {
      let own = assignment[index] ? centreB : centreA
      spread += (1 - dot(vector, own)) * pointWeights[index]
    }
    let withinSpread = max(0, spread / total)
    let betweenGap = max(0, 1 - dot(centreA, centreB))
    let minority = min(weightA, weightB)

    // Ties: equal weight falls to the smaller-count half, then to half B —
    // the half seeded from the farther point, which is the likelier stranger.
    let minorityIsB =
      weightB < weightA || (weightB == weightA && (countB < countA || countB == countA))
    let minorityIndices = assignment.indices
      .filter { assignment[$0] == minorityIsB }
      .map { originalIndices[$0] }

    return Split(
      halves: Halves(
        betweenGap: betweenGap,
        withinSpread: withinSpread,
        separation: betweenGap / max(withinSpread, epsilon),
        minorityShare: minority / total,
        minoritySeconds: minority,
        countA: countA,
        countB: countB),
      minorityIndices: minorityIndices)
  }

  // MARK: Geometry

  private static func unitPoints(
    _ embeddings: [[Float]], _ weights: [Double]
  ) -> (vectors: [[Double]], weights: [Double], originalIndices: [Int])? {
    guard !embeddings.isEmpty, embeddings.count == weights.count else { return nil }
    guard let dimension = embeddings.first?.count, dimension > 0 else { return nil }
    var vectors: [[Double]] = []
    var kept: [Double] = []
    // Which input each surviving point came from: a dropped turn shifts
    // every later index, and the caller's per-line marker is keyed by input.
    var originalIndices: [Int] = []
    for (index, (embedding, weight)) in zip(embeddings, weights).enumerated() {
      // Ragged dimensions mean one embedding predates a model revision —
      // there is no meaningful geometry between them, a hard failure for
      // the whole cluster.
      guard embedding.count == dimension else { return nil }
      // A non-positive-weight turn (e.g. a zero-duration row) is dropped,
      // not a reason to refuse the whole cluster: 200 good turns plus one
      // bad duration must stay measurable.
      guard weight > 0 else { continue }
      // A zero-norm embedding is not a bad duration — it is the model
      // producing no direction at all, a different and more serious
      // failure. That is a hard refusal of the whole cluster, same as
      // ragged dimensions, rather than something to quietly drop.
      guard let unit = normalize(embedding.map(Double.init)) else { return nil }
      vectors.append(unit)
      kept.append(weight)
      originalIndices.append(index)
    }
    guard vectors.count >= 2 else { return nil }
    return (vectors, kept, originalIndices)
  }

  private static func normalize(_ vector: [Double]) -> [Double]? {
    let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
    guard norm > 0 else { return nil }
    return vector.map { $0 / norm }
  }

  private static func dot(_ a: [Double], _ b: [Double]) -> Double {
    zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
  }

  private static func centroid(_ vectors: [[Double]], weights: [Double]) -> [Double]? {
    guard let dimension = vectors.first?.count, dimension > 0 else { return nil }
    var accumulated = [Double](repeating: 0, count: dimension)
    var total = 0.0
    for (vector, weight) in zip(vectors, weights) {
      for index in 0..<dimension { accumulated[index] += vector[index] * weight }
      total += weight
    }
    guard total > 0 else { return nil }
    let mean = accumulated.map { $0 / total }
    // Exactly opposed inputs cancel to a zero-norm mean: there is no
    // direction to normalize, but that is a valid degenerate centroid (not
    // an empty half), so keep the zero vector rather than failing.
    return normalize(mean) ?? mean
  }

  private static func pick<T>(_ items: [T], _ assignment: [Bool], half: Bool) -> [T] {
    zip(items, assignment).filter { $0.1 == half }.map(\.0)
  }

  /// Seeds from the two most dissimilar embeddings rather than at random.
  /// Determinism is the contract: a user re-running a check must get the same
  /// answer twice, and a failing test must be reproducible.
  /// Below this many turns every point stays a seed candidate: there is no
  /// "body" to trim towards, and `ClusterQuality.minSplitSample` refuses to
  /// judge such clusters anyway.
  static let seedTrimFloor = 20

  /// The points the seeds may be drawn from: everything except the most
  /// isolated few.
  ///
  /// Farthest-pair seeding hands one seed to any single odd turn — a cough, a
  /// door, a crosstalk fragment — because nothing is farther from the cluster
  /// than the one point that is not part of it. 2-means then converges on
  /// "that turn versus everyone", and on a tight single voice the gap divides
  /// by a within-spread of almost nothing: a real 1/220 cut scored 4.94, a
  /// number that reads as two voices when it is evidence of one odd turn.
  /// Seeding from the body of the cluster instead lets the iterations find
  /// the structure that is actually there. The outlier is still assigned to a
  /// half afterwards; it simply cannot be one on its own.
  ///
  /// Isolation is mean cosine to every other point. Trimming one in twenty
  /// keeps a genuine minority voice seedable — its turns are similar to each
  /// other, so only the most extreme land in the trimmed tail — while a lone
  /// stray is always the first out.
  private static func seedCandidates(_ vectors: [[Double]]) -> [[Double]] {
    guard vectors.count >= seedTrimFloor else { return vectors }
    let trim = max(1, vectors.count / seedTrimFloor)
    let isolation = vectors.indices.map { i -> Double in
      var total = 0.0
      for j in vectors.indices where j != i { total += dot(vectors[i], vectors[j]) }
      return total / Double(vectors.count - 1)
    }
    // Stable on ties so two runs over the same input pick the same seeds —
    // determinism is this detector's contract.
    let keep = isolation.indices.sorted { (isolation[$0], $0) > (isolation[$1], $1) }
      .dropLast(trim).sorted()
    return keep.map { vectors[$0] }
  }

  private static func farthestPair(_ vectors: [[Double]]) -> ([Double], [Double])? {
    guard vectors.count >= 2 else { return nil }
    var best = (a: 0, b: 1)
    var worstSimilarity = Double.infinity
    for i in vectors.indices {
      for j in (i + 1)..<vectors.count {
        let similarity = dot(vectors[i], vectors[j])
        if similarity < worstSimilarity {
          worstSimilarity = similarity
          best = (i, j)
        }
      }
    }
    return (vectors[best.a], vectors[best.b])
  }
}
