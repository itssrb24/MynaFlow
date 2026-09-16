import Foundation
import MynaFlowCore

/// Watches the field that just received a dictation for a short window and
/// logs the user's first edit as a correction candidate. Data collection
/// only — nothing learns from it yet.
@MainActor
final class CorrectionWatcher {
  private var task: Task<Void, Never>?
  private static let pollOffsets: [Duration] = [
    .seconds(3), .seconds(6), .seconds(10), .seconds(15),
  ]

  func watch(insertedText: String, dictationID: UUID, log: @escaping @Sendable (CorrectionPair) async -> Void) {
    task?.cancel()
    task = Task { @MainActor in
      // Let the paste settle before taking the baseline.
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled, let field = SelectionReader.focusedField(),
        let before = field.value, before.contains(insertedText)
      else { return }
      var elapsed: Duration = .zero
      for offset in Self.pollOffsets {
        try? await Task.sleep(for: offset - elapsed)
        elapsed = offset
        guard !Task.isCancelled else { return }
        guard let after = field.value else { return }
        if let pair = CorrectionDetector.detect(before: before, after: after, inserted: insertedText) {
          await log(pair)
          return
        }
      }
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }
}
