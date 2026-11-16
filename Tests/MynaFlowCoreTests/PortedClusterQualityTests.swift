import XCTest

@testable import MynaFlowCore

final class ClusterQualityTests: XCTestCase {
  // Mirrors the pre-refactor five-parameter shape so every existing fixture
  // below reads unchanged; nil `separation` (the marker every existing test
  // already used for "unmeasured") collapses the whole split to nil, and a
  // non-nil `separation` always arrives alongside the other four in every
  // call below, so folding them into one `Halves` changes no test's meaning.
  private func evidence(
    cohesion: Double? = 0.9,
    separation: Double? = 0.6,
    minorityShare: Double? = 0.4,
    minoritySeconds: Double? = 60,
    splitSampleCount: Int? = 40,
    betweenGap: Double? = 0.4,
    distinctPersonIDs: Int = 1,
    channelConflict: Bool = false
  ) -> ClusterQuality.Evidence {
    let split: ClusterSplit.Halves?
    if let separation, let minorityShare, let minoritySeconds, let splitSampleCount,
      let betweenGap
    {
      split = ClusterSplit.Halves(
        betweenGap: betweenGap, withinSpread: 0, separation: separation,
        minorityShare: minorityShare, minoritySeconds: minoritySeconds,
        // Split across both halves rather than piling the whole sample into
        // one: `countB: 0` made `smallestHalfCount` zero in every fixture,
        // which is harmless only until a rule reads it — and `Halves` argues at
        // length that the small-sample guard should count the smaller half.
        countA: splitSampleCount / 2, countB: splitSampleCount - splitSampleCount / 2)
    } else {
      split = nil
    }
    return ClusterQuality.Evidence(
      cohesion: cohesion, split: split, distinctPersonIDs: distinctPersonIDs,
      channelConflict: channelConflict)
  }

  func testDisagreeingPersonIDsAreMixed() {
    XCTAssertEqual(ClusterQuality.state(for: evidence(distinctPersonIDs: 2)), .mixed)
  }

  func testHighSeparationWithBothGuardsMetIsMixed() {
    let state = ClusterQuality.state(
      for: evidence(separation: 2.4, minorityShare: 0.3, minoritySeconds: 90))
    XCTAssertEqual(state, .mixed)
  }

  func testHighSeparationOverTooFewTurnsIsNotMixed() {
    // The regression that nearly shipped. A CLEAN single-voice two-turn cluster
    // measures separation ~360000 and passes both minority guards, because two
    // turns split 50/50 with ample seconds each side. Only the sample floor
    // stops it being branded mixed.
    let state = ClusterQuality.state(
      for: evidence(
        separation: 360_000, minorityShare: 0.5, minoritySeconds: 60,
        splitSampleCount: 2))
    XCTAssertNotEqual(state, .mixed)
  }

  func testTenTurnsIsStillTooFewToBelieve() {
    // The second draft of this floor said 10. Measured worst-case separation
    // for a CLEAN cluster at cohesion 0.810 is 1.79 at n=10 — above the 1.6
    // threshold. The floor has to clear the clean band, not merely exclude the
    // absurd two-turn case.
    let state = ClusterQuality.state(
      for: evidence(separation: 1.79, splitSampleCount: 10))
    XCTAssertNotEqual(state, .mixed)
  }

  func testAVanishingGapIsNotTwoVoicesHoweverLargeTheRatio() {
    // separation is a RATIO. One voice quantised into two near-identical
    // embeddings (cosine 0.9999) divides a gap of 0.0001 by a spread near zero
    // and scores 100 — with sample, share and seconds all healthy. Only an
    // absolute gap floor rejects it.
    let state = ClusterQuality.state(
      for: evidence(
        separation: 100, minorityShare: 0.5, minoritySeconds: 200,
        splitSampleCount: 40, betweenGap: 0.0001))
    XCTAssertNotEqual(state, .mixed)
  }

  func testHighSeparationFromATinyMinorityIsNotMixed() {
    // One outlier turn must not invent a second speaker.
    let state = ClusterQuality.state(
      for: evidence(separation: 3.0, minorityShare: 0.02, minoritySeconds: 1.5))
    XCTAssertNotEqual(state, .mixed)
  }

  func testNeverMeasuredIsUncertainNotClean() {
    // Every cluster recorded before quality was persisted lands here. Calling
    // it clean would leave the contaminated 1:1 bulk-confirmable.
    XCTAssertEqual(
      ClusterQuality.state(for: evidence(cohesion: nil, separation: nil)), .uncertain)
  }

  func testLowCohesionIsUncertain() {
    XCTAssertEqual(ClusterQuality.state(for: evidence(cohesion: 0.55)), .uncertain)
  }

  func testAnUntrustworthySplitIsNotCertifiedClean() {
    // The false-exoneration hole. The sample floor lives inside the mixed rule,
    // so failing it used to fall through to clean — and a genuinely two-person
    // 10-turn cluster measures separation around 14.9. It would have been
    // auto-assigned and enrolled: the exact contamination this gate exists to
    // stop, reachable by every cluster under 20 turns.
    let state = ClusterQuality.state(
      for: evidence(cohesion: 0.9, separation: 14.9, splitSampleCount: 10))
    XCTAssertEqual(state, .uncertain)
    XCTAssertFalse(state.allowsEnrollment)
  }

  func testADegenerateGapIsNotCertifiedCleanEither() {
    let state = ClusterQuality.state(
      for: evidence(cohesion: 0.9, separation: 100, betweenGap: 0.0001))
    XCTAssertEqual(state, .uncertain)
  }

  func testSeparationBetweenTheBandsIsUncertain() {
    // Trustworthy sample, separation short of mixed but far outside the clean
    // distribution, which tops out near 0.82.
    XCTAssertEqual(ClusterQuality.state(for: evidence(separation: 1.59)), .uncertain)
  }

  func testTinyMinorityShareAloneBlocksMixed() {
    // Pinned separately from the seconds guard: a single test failing both at
    // once would pass even if one guard were deleted.
    let state = ClusterQuality.state(
      for: evidence(separation: 2.4, minorityShare: 0.02, minoritySeconds: 200))
    XCTAssertNotEqual(state, .mixed)
  }

  func testTinyMinoritySecondsAloneBlocksMixed() {
    let state = ClusterQuality.state(
      for: evidence(separation: 2.4, minorityShare: 0.4, minoritySeconds: 1.5))
    XCTAssertNotEqual(state, .mixed)
  }

  func testInjectedThresholdsAreHonoured() {
    // Every other test uses the defaults, so nothing verified that the
    // parameter is read at all rather than `Thresholds.default` being used.
    let permissive = ClusterQuality.Thresholds(mixedSeparation: 1.0, minSplitSample: 2)
    let state = ClusterQuality.state(
      for: evidence(separation: 1.2, splitSampleCount: 4), thresholds: permissive)
    XCTAssertEqual(state, .mixed)
  }

  func testDisagreeingPersonIDsOutrankNeverBeingMeasured() {
    // Rule 1 is the only rule that works without audio, and every pre-existing
    // meeting has nil cohesion by definition. If rule 1 ever sank below the
    // uncertain rules this would silently stop working on exactly those rows.
    let state = ClusterQuality.state(
      for: evidence(cohesion: nil, separation: nil, distinctPersonIDs: 2))
    XCTAssertEqual(state, .mixed)
  }

  func testAFabricatedZeroSplitDoesNotCertifyClean() {
    // The shape a caller writes when the split could not be computed and they
    // reach for zeros instead of nil. It clears every rule above: totalCount 0
    // fails the sample floor so the mixed rule skips, separation 0 sits below
    // `uncertainSeparation` so that rule skips, and a healthy cohesion then
    // certifies it. Two embeddings is the floor below which `ClusterSplit`
    // itself refuses to measure, so anything under it was invented.
    let fabricated = ClusterSplit.Halves(
      betweenGap: 0, withinSpread: 0, separation: 0, minorityShare: 0,
      minoritySeconds: 0, countA: 0, countB: 0)

    let state = ClusterQuality.state(
      for: ClusterQuality.Evidence(
        cohesion: 0.9, split: fabricated, distinctPersonIDs: 1, channelConflict: false))

    XCTAssertEqual(state, .uncertain)
    XCTAssertFalse(state.allowsEnrollment)
  }

  func testCohesiveSingleVoiceIsClean() {
    XCTAssertEqual(ClusterQuality.state(for: evidence()), .clean)
  }

  func testHighCohesionWithNoSplitMeasurementIsUncertainNotClean() {
    // The Critical: a cluster whose two-voice check never ran must not be
    // certified clean merely because cohesion looks good. The real mixed
    // cluster that motivated this whole gate measured 0.810 centroid-mean —
    // squarely in the "clean-looking" band — which is exactly why cohesion
    // alone can never stand in for the split test having actually run.
    let state = ClusterQuality.state(
      for: evidence(
        cohesion: 0.95, separation: nil, minorityShare: nil, minoritySeconds: nil,
        splitSampleCount: nil, betweenGap: nil))
    XCTAssertEqual(state, .uncertain)
    XCTAssertFalse(state.allowsEnrollment)
  }

  func testGatePermissions() {
    XCTAssertTrue(ClusterQuality.State.clean.allowsEnrollment)
    XCTAssertTrue(ClusterQuality.State.clean.allowsBulkConfirm)
    XCTAssertTrue(ClusterQuality.State.clean.allowsAutoAssign)

    XCTAssertFalse(ClusterQuality.State.uncertain.allowsEnrollment)
    XCTAssertFalse(ClusterQuality.State.uncertain.allowsAutoAssign)
    XCTAssertTrue(
      ClusterQuality.State.uncertain.allowsBulkConfirm,
      "unmeasured is not proof of contamination; a human may still answer")

    XCTAssertFalse(ClusterQuality.State.mixed.allowsEnrollment)
    XCTAssertFalse(ClusterQuality.State.mixed.allowsAutoAssign)
    XCTAssertFalse(ClusterQuality.State.mixed.allowsBulkConfirm)
  }

  func testPerLineCorrectionIsNeverBlocked() {
    for state in [ClusterQuality.State.clean, .uncertain, .mixed] {
      XCTAssertTrue(
        state.allowsPerLineCorrection,
        "per-line correction is the escape hatch and must survive every state")
    }
  }

  // MARK: - Boundary inclusivity
  //
  // Every rule in `state(for:)` is a comparison against a threshold, and every
  // test above sits comfortably on one side of its boundary. That left the
  // inclusivity of each comparison — `>=` versus `>`, `<` versus `<=` — the one
  // mutation class the suite could not catch: flipping any of them changes the
  // verdict for exactly one input, the value ON the boundary, and nothing else
  // in the file uses those values. They were deliberately left unpinned while
  // the numbers were provisional. Task 10 measured them against the real mixed
  // meeting and changed none of them, so they are final and pinned here: one
  // test per threshold, each asserting the state EXACTLY AT the boundary.
  //
  // Each test states which mutation it kills, because a boundary test whose
  // fixture drifts off the boundary still passes while testing nothing.

  func testSeparationExactlyAtMixedThresholdIsMixed() {
    // Kills `separation > mixedSeparation`, which would drop this to uncertain.
    XCTAssertEqual(
      ClusterQuality.state(
        for: evidence(separation: ClusterQuality.Thresholds.default.mixedSeparation)),
      .mixed)
  }

  func testSampleCountExactlyAtTheFloorIsBelieved() {
    // Kills `totalCount > minSplitSample`. 20 is the measured floor where a
    // clean cluster's worst-case separation (0.82) finally clears the 1.6
    // threshold by a real margin; the boundary itself must count as adequate.
    XCTAssertEqual(
      ClusterQuality.state(
        for: evidence(
          separation: 2.4,
          splitSampleCount: ClusterQuality.Thresholds.default.minSplitSample)),
      .mixed)
  }

  func testBetweenGapExactlyAtTheFloorIsBelieved() {
    // Kills `betweenGap > minBetweenGap`.
    XCTAssertEqual(
      ClusterQuality.state(
        for: evidence(
          separation: 2.4, betweenGap: ClusterQuality.Thresholds.default.minBetweenGap)),
      .mixed)
  }

  func testMinorityShareExactlyAtTheFloorIsBelieved() {
    // Kills `minorityShare > minMinorityShare`. Pinned separately from the
    // seconds boundary below for the same reason the two guards are tested
    // separately above: one test on both boundaries survives either deletion.
    XCTAssertEqual(
      ClusterQuality.state(
        for: evidence(
          separation: 2.4,
          minorityShare: ClusterQuality.Thresholds.default.minMinorityShare)),
      .mixed)
  }

  func testMinoritySecondsExactlyAtTheFloorIsBelieved() {
    // Kills `minoritySeconds > minMinoritySeconds`.
    XCTAssertEqual(
      ClusterQuality.state(
        for: evidence(
          separation: 2.4,
          minoritySeconds: ClusterQuality.Thresholds.default.minMinoritySeconds)),
      .mixed)
  }

  func testSeparationExactlyAtTheUncertainThresholdIsUncertain() {
    // Kills `separation > uncertainSeparation`, which would let this cohesive
    // fixture fall all the way through to clean — the false-exoneration hole
    // the uncertain rule exists to close, reopened by one character.
    let state = ClusterQuality.state(
      for: evidence(
        cohesion: 0.9, separation: ClusterQuality.Thresholds.default.uncertainSeparation))
    XCTAssertEqual(state, .uncertain)
    XCTAssertFalse(state.allowsEnrollment)
  }

  func testCohesionExactlyAtTheUncertainThresholdIsStillClean() {
    // The one boundary that resolves the permissive way, and deliberately so:
    // the rule is `cohesion < uncertainCohesion`, so the threshold value itself
    // is the lowest cohesion that still certifies. Kills `cohesion <=
    // uncertainCohesion`, which would move the real floor a hair above 0.75 and
    // quietly withhold enrollment from clusters calibration cleared.
    XCTAssertEqual(
      ClusterQuality.state(
        for: evidence(cohesion: ClusterQuality.Thresholds.default.uncertainCohesion)),
      .clean)
  }
}
