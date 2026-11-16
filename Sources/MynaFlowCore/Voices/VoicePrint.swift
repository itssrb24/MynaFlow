import Foundation

// Ported from the Myna app (Meetings.swift). A voice profile is numbers
// averaged from a speaker's embeddings — never audio — and only exists for
// people the user named, when they opted in to recognising voices.

/// Which side of the call a voice was heard on. Myna Flow only profiles
/// "Others" (remote); the mic is always "You".
public enum VoiceChannel: String, Codable, Equatable, Sendable {
  case mic
  case remote
}

public struct VoicePrint: Codable, Equatable, Sendable {
  public var embedding: [Float]
  public var channel: VoiceChannel
  public var sampleCount: Int
  public var updatedAt: Date

  public init(embedding: [Float], channel: VoiceChannel, sampleCount: Int, updatedAt: Date) {
    self.embedding = embedding
    self.channel = channel
    self.sampleCount = sampleCount
    self.updatedAt = updatedAt
  }
}
