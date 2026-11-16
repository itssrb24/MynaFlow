import Foundation

/// Recognising voices for one meeting: the people with a voice profile and
/// their names. Present only when the user opted in.
public struct MeetingVoices: Sendable {
  public let candidates: [SpeakerMatch.Candidate]
  public let names: [UUID: String]

  public init(candidates: [SpeakerMatch.Candidate], names: [UUID: String]) {
    self.candidates = candidates
    self.names = names
  }
}

/// One diarized turn of a speaker: its voice embedding and how long it ran.
public struct SpeakerSample: Equatable, Sendable {
  public let embedding: [Float]
  public let seconds: Double

  public init(embedding: [Float], seconds: Double) {
    self.embedding = embedding
    self.seconds = seconds
  }
}

/// A speaker's voice in one meeting: the average of its turns (numbers, not
/// audio), how long it spoke, and whether it was provably one voice. Kept
/// with the meeting so a later confirmation can still teach the person's
/// voice after the audio is gone — and only when voices are opted in.
public struct SpeakerProfile: Codable, Equatable, Sendable {
  public let speaker: Int
  public let embedding: [Float]
  public let seconds: Double
  public let quality: ClusterQuality.State
  /// The person this profile taught, so reassigning can take it back out.
  public var enrolledPerson: UUID?

  public init(
    speaker: Int, embedding: [Float], seconds: Double, quality: ClusterQuality.State,
    enrolledPerson: UUID? = nil
  ) {
    self.speaker = speaker
    self.embedding = embedding
    self.seconds = seconds
    self.quality = quality
    self.enrolledPerson = enrolledPerson
  }
}

/// Builds each speaker's profile and quality verdict (Myna's gate: only a
/// cluster measured to be one voice is clean).
public enum SpeakerProfiler {
  public static func profiles(from samples: [Int: [SpeakerSample]]) -> [SpeakerProfile] {
    samples.keys.sorted().compactMap { speaker in
      let turns = samples[speaker] ?? []
      let embeddings = turns.map(\.embedding)
      let weights = turns.map(\.seconds)
      guard let centroid = weightedMean(embeddings, weights: weights) else { return nil }
      let evidence = ClusterQuality.Evidence(
        cohesion: ClusterSplit.cohesion(embeddings: embeddings, weights: weights),
        split: ClusterSplit.split(embeddings: embeddings, weights: weights),
        distinctPersonIDs: 1, channelConflict: false)
      return SpeakerProfile(
        speaker: speaker, embedding: centroid, seconds: weights.reduce(0, +),
        quality: ClusterQuality.state(for: evidence))
    }
  }

  /// Duration-weighted mean of unit-normalized embeddings.
  static func weightedMean(_ embeddings: [[Float]], weights: [Double]) -> [Float]? {
    guard let dims = embeddings.first?.count, dims > 0 else { return nil }
    var sum = [Double](repeating: 0, count: dims)
    var total = 0.0
    for (embedding, weight) in zip(embeddings, weights) where embedding.count == dims && weight > 0 {
      let norm = sqrt(embedding.reduce(0) { $0 + Double($1) * Double($1) })
      guard norm > 0 else { continue }
      for d in 0..<dims { sum[d] += Double(embedding[d]) / norm * weight }
      total += weight
    }
    guard total > 0 else { return nil }
    return sum.map { Float($0 / total) }
  }
}

/// Who the meeting's speakers are, by voice: named when a clean speaker
/// clears 0.62, suggested from 0.45 (Myna's thresholds, invitees nudged).
public enum VoiceRecognition {
  public struct Result: Equatable, Sendable {
    public var named: [Int: UUID] = [:]
    public var suggested: [Int: UUID] = [:]
  }

  public static func recognise(_ profiles: [SpeakerProfile], candidates: [SpeakerMatch.Candidate])
    -> Result
  {
    let clusters = profiles.map {
      SpeakerCluster(id: $0.speaker, embedding: $0.embedding, seconds: $0.seconds, micDominance: 0)
    }
    let quality = Dictionary(uniqueKeysWithValues: profiles.map { ($0.speaker, $0.quality) })
    var result = Result()
    for decision in SpeakerMatch.identify(
      clusters: clusters, candidates: candidates, selfPersonID: nil, quality: quality)
    {
      guard let person = decision.personID else { continue }
      switch decision.kind {
      case .auto: result.named[decision.clusterID] = person
      case .suggestion: result.suggested[decision.clusterID] = person
      case .unnamed: break
      }
    }
    return result
  }
}
