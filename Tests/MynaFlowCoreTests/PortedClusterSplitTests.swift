import XCTest

@testable import MynaFlowCore

/// Deterministic jitter. `Double.random` would make a failure unreproducible,
/// and this detector's whole contract is that two runs agree.
private struct Deterministic {
  var state: UInt64

  mutating func unit() -> Double {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z = z ^ (z >> 31)
    return Double(z >> 11) / Double(1 << 53)
  }

  mutating func signed() -> Double { unit() * 2 - 1 }
}

// Real wespeaker embeddings run 192-256 dimensions; a low-dimensional fixture
// flatters this detector by roughly 7x (orthogonal axes in a tiny space are
// unrealistically far apart). 192 matches production.
private let dimension = 192

/// A unit-length direction with all its mass on one axis.
private func axisDirection(_ axis: Int) -> [Double] {
  var direction = [Double](repeating: 0, count: dimension)
  direction[axis] = 1
  return direction
}

/// A unit-length blend of two axes. Real distinct speakers measure roughly
/// 0.3-0.5 cosine similarity to each other, not the 0 that two orthogonal
/// axes give — this is how the two-voice fixture stays honest about that.
private func blendedDirection(primary: Int, secondary: Int, primaryWeight: Double) -> [Double] {
  var direction = [Double](repeating: 0, count: dimension)
  let secondaryWeight = (1 - primaryWeight * primaryWeight).squareRoot()
  direction[primary] = primaryWeight
  direction[secondary] = secondaryWeight
  return direction
}

/// `count` embeddings scattered around `direction` by `jitter`.
private func voice(
  direction: [Double], jitter: Double, count: Int, rng: inout Deterministic
) -> [[Float]] {
  (0..<count).map { _ in
    var vector = direction.map(Float.init)
    for index in 0..<dimension {
      vector[index] += Float(rng.signed() * jitter)
    }
    return vector
  }
}

private func voice(
  axis: Int, jitter: Double, count: Int, rng: inout Deterministic
) -> [[Float]] {
  voice(direction: axisDirection(axis), jitter: jitter, count: count, rng: &rng)
}

final class ClusterSplitTests: XCTestCase {
  // Fixture-specific: these magnitudes come from this synthetic geometry at
  // D=192 with a ~0.4 cross-speaker cosine, not from any real meeting. Do NOT
  // copy them into `ClusterQuality`'s thresholds — that calibration has to
  // come from real cluster measurements. Both fixtures are deterministically
  // seeded (fixed below), so they cannot drift on their own — but for
  // context, across 40 candidate seeds at this D the diffuse fixture ranged
  // 0.78-1.10 against the `< 1.2` bound below, and the two-voice fixture
  // ranged 1.67-2.02 against the `> 1.6` bound (4% from failing at the worst
  // seed). A future edit to either fixture's shape should re-check that
  // margin rather than assume it holds.
  func testTwoDistinctVoicesSeparateCleanly() {
    var rng = Deterministic(state: 42)
    let embeddings =
      voice(axis: 0, jitter: 0.15, count: 20, rng: &rng)
      + voice(
        direction: blendedDirection(primary: 1, secondary: 0, primaryWeight: 0.917),
        jitter: 0.15, count: 20, rng: &rng)
    let weights = [Double](repeating: 2.0, count: 40)

    guard let halves = ClusterSplit.split(embeddings: embeddings, weights: weights) else {
      return XCTFail("expected a split for 40 embeddings")
    }
    XCTAssertGreaterThan(
      halves.separation, 1.6,
      "two distinct voices must separate far more than they spread internally")
    XCTAssertEqual(halves.minorityShare, 0.5, accuracy: 0.1)
    XCTAssertEqual(halves.minoritySeconds, 40, accuracy: 8)
  }

  func testOneDiffuseVoiceDoesNotSeparate() {
    var rng = Deterministic(state: 7)
    // One speaker, deliberately noisier than the two-voice case above. A blob
    // still gets halved by 2-means, but the halves sit as far apart as the
    // points within them — which is what separation measures.
    let embeddings = voice(axis: 0, jitter: 0.55, count: 40, rng: &rng)
    let weights = [Double](repeating: 2.0, count: 40)

    let halves = ClusterSplit.split(embeddings: embeddings, weights: weights)

    guard let halves else { return XCTFail("expected a split for 40 embeddings") }
    XCTAssertLessThan(
      halves.separation, 1.2,
      "one voice must not look like two merely because it is noisy")
  }

  func testASingleOutlierTurnDoesNotSeedTheSplit() {
    var rng = Deterministic(state: 11)
    // One voice plus one odd turn (a cough, a door, a crosstalk fragment)
    // pointing somewhere else entirely. Farthest-pair seeding picks that turn
    // as one seed every time, and 2-means then reports "the outlier versus
    // everyone" — a 1/40 cut whose separation reads like two voices when it
    // is evidence of one odd turn. The seeds must come from the body of the
    // cluster, so the reported halves describe the voice, not the outlier.
    // Tight, like real wespeaker turns from one person (cosine ~0.98 to the
    // centroid): with a small within-spread, the outlier cut's gap divides by
    // almost nothing and the ratio explodes — the 1/220 cut that scored 4.94
    // on a real meeting had exactly this shape.
    let embeddings =
      voice(axis: 0, jitter: 0.05, count: 40, rng: &rng)
      + voice(axis: 1, jitter: 0, count: 1, rng: &rng)
    let weights = [Double](repeating: 2.0, count: 41)

    let halves = ClusterSplit.split(embeddings: embeddings, weights: weights)

    guard let halves else { return XCTFail("expected a split for 41 embeddings") }
    XCTAssertGreaterThanOrEqual(
      halves.smallestHalfCount, 2, "the split must not be the outlier against the rest")
    XCTAssertLessThan(
      halves.separation, 1.2, "one voice with one odd turn must still read as one voice")
  }

  func testSplitIsDeterministicAcrossRuns() {
    var rng = Deterministic(state: 99)
    let embeddings =
      voice(axis: 0, jitter: 0.2, count: 12, rng: &rng)
      + voice(axis: 1, jitter: 0.2, count: 12, rng: &rng)
    let weights = (0..<24).map { Double($0 % 5) + 1 }

    let first = ClusterSplit.split(embeddings: embeddings, weights: weights)
    let second = ClusterSplit.split(embeddings: embeddings, weights: weights)

    XCTAssertEqual(first, second)
  }

  func testDegenerateInputReturnsNil() {
    XCTAssertNil(ClusterSplit.split(embeddings: [], weights: []))
    XCTAssertNil(ClusterSplit.split(embeddings: [[1, 0, 0]], weights: [1]))
    XCTAssertNil(
      ClusterSplit.split(embeddings: [[1, 0], [0, 1, 0]], weights: [1, 1]),
      "ragged dimensions are a model-revision mismatch, not a split")
  }

  func testCohesionIsWeightedMeanCosineToCentroid() {
    let identical = [[Float]](repeating: [1, 0, 0, 0], count: 5)
    XCTAssertEqual(
      ClusterSplit.cohesion(embeddings: identical, weights: [1, 1, 1, 1, 1]) ?? 0,
      1.0, accuracy: 0.001)

    let opposed: [[Float]] = [[1, 0], [-1, 0]]
    XCTAssertLessThan(ClusterSplit.cohesion(embeddings: opposed, weights: [1, 1]) ?? 1, 0.01)
  }

  // MARK: - Small-sample bias

  func testTinySamplesReportTheirSizeSoPolicyCanRefuse() {
    // A single, clean voice measured in only two turns. Each half of a
    // 2-means split is then exactly one point, which is its own centroid:
    // `withinSpread` is exactly zero, so `separation` explodes to an
    // arbitrarily large number even though there is obviously no second
    // voice here. `totalCount` is the only thing that lets a caller notice
    // the sample is too small to trust `separation` at all.
    var rng = Deterministic(state: 3)
    let embeddings = voice(axis: 0, jitter: 0.1, count: 2, rng: &rng)
    let weights = [Double](repeating: 5.0, count: 2)

    guard let halves = ClusterSplit.split(embeddings: embeddings, weights: weights) else {
      return XCTFail("expected a split for 2 embeddings")
    }
    XCTAssertGreaterThan(
      halves.separation, 1000,
      "n=2 must expose the small-sample blow-up, not quietly look reasonable")
    XCTAssertEqual(halves.totalCount, 2)
    XCTAssertEqual(halves.countA + halves.countB, halves.totalCount)
  }

  // MARK: - Minority direction (smaller half, not larger)

  func testMinorityIsTheSmallerHalfNotTheLarger() {
    // 36 turns from one voice, 4 from another. If `min` were silently
    // swapped for `max` at the minority computation, this is the only test
    // that would notice — the primary fixture's balanced 20/20 halves give
    // `min` and `max` the same answer.
    var rng = Deterministic(state: 11)
    let embeddings =
      voice(axis: 0, jitter: 0.1, count: 36, rng: &rng)
      + voice(axis: 1, jitter: 0.1, count: 4, rng: &rng)
    let weights = [Double](repeating: 2.0, count: 40)

    guard let halves = ClusterSplit.split(embeddings: embeddings, weights: weights) else {
      return XCTFail("expected a split for 40 embeddings")
    }
    XCTAssertEqual(halves.minorityShare, 0.10, accuracy: 0.02)
    XCTAssertEqual(halves.minoritySeconds, 8, accuracy: 2)
    XCTAssertEqual(halves.smallestHalfCount, 4)
  }

  // MARK: - Weighting is load-bearing

  func testMinoritySecondsReflectsWeightNotTurnCount() {
    // Majority by count: 30 short turns at the typical per-turn weight.
    // Minority by weight: only 3 turns, but each much longer, so their
    // summed weight (15s) still trails the majority's (60s). An
    // implementation that dropped `weights` and substituted a uniform
    // per-turn value would report `minoritySeconds` around the turn count
    // (3) instead of the true summed duration (15) — the real meeting has
    // 52 short turns that must not outweigh a single 60s turn, and this is
    // the fixture that would catch a regression there.
    let typicalWeight = 2.0
    var rng = Deterministic(state: 21)
    let majority = voice(axis: 0, jitter: 0.1, count: 30, rng: &rng)
    let minority = voice(axis: 1, jitter: 0.1, count: 3, rng: &rng)
    let embeddings = majority + minority
    let weights =
      [Double](repeating: typicalWeight, count: 30) + [Double](repeating: 5.0, count: 3)

    guard let halves = ClusterSplit.split(embeddings: embeddings, weights: weights) else {
      return XCTFail("expected a split for 33 embeddings")
    }
    XCTAssertEqual(halves.smallestHalfCount, 3)
    XCTAssertEqual(halves.minoritySeconds, 15, accuracy: 1)
    XCTAssertLessThan(
      Double(halves.smallestHalfCount), halves.minoritySeconds / typicalWeight,
      "the minority's turns are heavier than typical, so its seconds must exceed"
        + " what count-times-typical-weight alone would predict")
  }

  // MARK: - Dropping bad turns, not the whole cluster

  func testOneZeroWeightTurnIsDroppedNotFatal() {
    // 200 good turns plus one zero-duration row must stay measurable: a
    // single bad duration cannot be allowed to void the whole cluster.
    var rng = Deterministic(state: 5)
    let good =
      voice(axis: 0, jitter: 0.1, count: 100, rng: &rng)
      + voice(
        direction: blendedDirection(primary: 1, secondary: 0, primaryWeight: 0.917),
        jitter: 0.1, count: 100, rng: &rng)
    let embeddings = good + [voice(axis: 0, jitter: 0.1, count: 1, rng: &rng)[0]]
    let weights = [Double](repeating: 2.0, count: 200) + [0.0]

    guard let halves = ClusterSplit.split(embeddings: embeddings, weights: weights) else {
      return XCTFail("a single zero-weight turn must not make the cluster unmeasurable")
    }
    XCTAssertEqual(halves.totalCount, 200, "the zero-weight row must be dropped, not counted")
  }

  // MARK: - measure: which turns sit in the minority half

  func testMinorityIndicesReferToOriginalInputsWhenAZeroWeightTurnIsDropped() {
    // The per-line marker in the transcript is looked up by the CALLER's
    // index. `unitPoints` drops non-positive-weight turns internally, so an
    // index into the surviving array would point one row early for every
    // turn after the drop — and flag the wrong lines.
    var rng = Deterministic(state: 99)
    let embeddings =
      [[Float](repeating: 1, count: dimension)]
      + voice(axis: 0, jitter: 0.2, count: 12, rng: &rng)
      + voice(axis: 1, jitter: 0.2, count: 12, rng: &rng)
    let weights = [0.0] + [Double](repeating: 2.0, count: 24)

    guard let split = ClusterSplit.measure(embeddings: embeddings, weights: weights) else {
      return XCTFail("expected a measurement for 24 usable embeddings")
    }
    XCTAssertEqual(split.minorityIndices.count, 12)
    XCTAssertFalse(split.minorityIndices.contains(0), "the dropped turn is nobody's minority")
    XCTAssertTrue(split.minorityIndices.allSatisfy { (1...24).contains($0) })
    XCTAssertEqual(split.minorityIndices, split.minorityIndices.sorted(), "ordered for the jump")
  }

  func testMinorityIndicesCountMatchesTheSmallerWeightHalf() {
    // Four 100s turns against thirty 2s turns: the count-minority is the
    // four, the WEIGHT-minority is the thirty. The marker must describe the
    // same half `minoritySeconds` reports, or the strip would say "60 seconds
    // of another voice" while the transcript flags four long lines.
    var rng = Deterministic(state: 5)
    let embeddings =
      voice(axis: 0, jitter: 0.1, count: 4, rng: &rng)
      + voice(axis: 1, jitter: 0.1, count: 30, rng: &rng)
    let weights = [Double](repeating: 100, count: 4) + [Double](repeating: 2, count: 30)

    guard let split = ClusterSplit.measure(embeddings: embeddings, weights: weights) else {
      return XCTFail("expected a measurement for 34 embeddings")
    }
    XCTAssertEqual(split.halves.smallestHalfCount, 4)
    XCTAssertEqual(split.minorityIndices.count, 30)
    XCTAssertTrue(split.minorityIndices.allSatisfy { $0 >= 4 }, "the thirty short turns")
  }

  func testSingleModeReportsNoMinorityIndices() {
    let identical = [[Float]](repeating: [1, 0, 0, 0], count: 6)
    let weights = [Double](repeating: 2.0, count: 6)

    let split = ClusterSplit.measure(embeddings: identical, weights: weights)

    XCTAssertEqual(split?.halves.separation, 0)
    XCTAssertEqual(split?.minorityIndices, [])
  }

  func testSplitIsAThinWrapperOverMeasure() {
    var rng = Deterministic(state: 3)
    let embeddings =
      voice(axis: 0, jitter: 0.2, count: 10, rng: &rng)
      + voice(axis: 1, jitter: 0.2, count: 10, rng: &rng)
    let weights = (0..<20).map { Double($0 % 3) + 1 }

    XCTAssertEqual(
      ClusterSplit.split(embeddings: embeddings, weights: weights),
      ClusterSplit.measure(embeddings: embeddings, weights: weights)?.halves)
  }

  // MARK: - nil means unmeasurable, not "found one mode"

  func testAllIdenticalEmbeddingsIsAMeasuredZeroNotNil() {
    // A maximally cohesive, obviously-single-voice cluster: 2-means finds
    // only one mode. That is evidence of one voice, not an absence of
    // evidence, so it must come back as a real zero-separation result, not
    // `nil` — `nil` is reserved for genuinely unmeasurable input (too few
    // usable turns, or ragged dimensions).
    let identical = [[Float]](repeating: [1, 0, 0, 0], count: 6)
    let weights = [Double](repeating: 2.0, count: 6)

    guard let halves = ClusterSplit.split(embeddings: identical, weights: weights) else {
      return XCTFail("a measured single mode must not be reported as unmeasurable")
    }
    XCTAssertEqual(halves.separation, 0)
    XCTAssertEqual(halves.minorityShare, 0)
    XCTAssertEqual(halves.smallestHalfCount, 0)
    XCTAssertEqual(halves.betweenGap, 0)
    XCTAssertEqual(halves.totalCount, 6)
  }

  // MARK: - smallestHalfCount and minoritySeconds can name different halves

  func testSmallestHalfCountAndMinoritySecondsCanDisagreeOnWhichHalf() {
    // Half A: 4 turns of 100s each (400s total). Half B: 30 turns of 2s
    // each (60s total) — this is the motivating meeting's shape, 52 turns
    // of 1.0-1.5s alongside far fewer long ones.
    //
    // `smallestHalfCount` (guards separation's population-driven small-
    // sample bias) reports 4 — half A. `minoritySeconds`/`minorityShare`
    // (guards against a manufactured split) report 60s — half B. These are
    // deliberately two DIFFERENT halves, each individually correct for its
    // own job. A policy that reads both as describing "the same minority"
    // is wrong, and wrong in the dangerous direction: it would credit a
    // 4-turn half with 60 seconds of speech it does not have.
    var rng = Deterministic(state: 55)
    let fewLongTurns = voice(axis: 0, jitter: 0.1, count: 4, rng: &rng)
    let manyShortTurns = voice(axis: 1, jitter: 0.1, count: 30, rng: &rng)
    let embeddings = fewLongTurns + manyShortTurns
    let weights = [Double](repeating: 100.0, count: 4) + [Double](repeating: 2.0, count: 30)

    guard let halves = ClusterSplit.split(embeddings: embeddings, weights: weights) else {
      return XCTFail("expected a split for 34 embeddings")
    }
    XCTAssertEqual(halves.smallestHalfCount, 4, "the count-minority is the 4-turn half")
    XCTAssertEqual(halves.minoritySeconds, 60, accuracy: 2, "the weight-minority is the 30-turn half")
    // Only two halves exist, so the weight-minority half's count is
    // whatever is left over from the count-minority half. It is 30, not 4:
    // proof the two statistics name opposite halves here.
    XCTAssertEqual(halves.totalCount - halves.smallestHalfCount, 30)
  }

  // MARK: - separation alone is not enough; betweenGap needs its own floor

  func testBetweenGapExposesAHazardSeparationAloneWouldMiss() {
    // 20 exact copies of one embedding, 20 exact copies of a
    // near-identical one at cosine 0.9999 to it — physically one voice,
    // quantised, not two people. Every sample-size and balance guard
    // passes (healthy count, perfectly even halves, ample duration), and
    // `separation` reads as dramatically mixed — far above the genuinely
    // two-voice fixture at the top of this file — purely because
    // `withinSpread` is driven to nearly zero by the exact duplication.
    // `betweenGap` is the only field that still tells the truth: it is
    // approximately 0.0001, physically nothing. Callers MUST floor on
    // `betweenGap` itself, not lean on `separation` alone.
    var rng = Deterministic(state: 0)
    let oneVoice = axisDirection(0)
    let almostTheSameVoice = blendedDirection(primary: 0, secondary: 1, primaryWeight: 0.9999)
    let embeddings =
      voice(direction: oneVoice, jitter: 0, count: 20, rng: &rng)
      + voice(direction: almostTheSameVoice, jitter: 0, count: 20, rng: &rng)
    let weights = [Double](repeating: 2.0, count: 40)

    guard let halves = ClusterSplit.split(embeddings: embeddings, weights: weights) else {
      return XCTFail("expected a split for 40 embeddings")
    }
    XCTAssertEqual(halves.betweenGap, 0.0001, accuracy: 0.00003)
    XCTAssertGreaterThan(
      halves.separation, 50,
      "separation alone looks dramatically mixed here — exactly the hazard betweenGap catches")
  }
}
