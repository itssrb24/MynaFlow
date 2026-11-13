import SwiftUI

// Small parts of the floating indicator, sized for its 34 pt capsule.

extension Text {
  /// The pill's one-line label: medium weight, near-white.
  func pillLabel() -> some View {
    font(.system(size: 12, weight: .medium))
      .foregroundStyle(.white.opacity(0.92))
      .lineLimit(1)
  }

  /// Elapsed time: rounded digits that don't jitter as they tick.
  func pillTimer() -> some View {
    font(.system(size: 12, weight: .medium, design: .rounded))
      .monospacedDigit()
      .foregroundStyle(.white.opacity(0.62))
  }
}

/// Stop for toggle dictation and meeting notes. The whole pill is the click
/// target; this is the visible promise that clicking stops.
struct StopButton: View {
  @State private var hovering = false

  var body: some View {
    ZStack {
      Circle().fill(.white.opacity(hovering ? 0.2 : 0.12))
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(.white.opacity(0.9))
        .frame(width: 7, height: 7)
        .scaleEffect(hovering ? 1.1 : 1)
    }
    .frame(width: 20, height: 20)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: Theme.Motion.fast), value: hovering)
    .accessibilityLabel("Stop")
  }
}

/// "On air" for meeting notes: a red dot that breathes, still under Reduce
/// Motion. Long recordings shouldn't look like a dictation in progress.
struct RecordingDot: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dim = false

  var body: some View {
    Circle()
      .fill(Theme.Colors.danger)
      .frame(width: 7, height: 7)
      .opacity(dim ? 0.6 : 1)
      .shadow(color: Theme.Colors.danger.opacity(dim ? 0 : 0.6), radius: 3)
      .padding(.leading, 3)
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
      }
      .accessibilityHidden(true)
  }
}

/// A red "!" in a soft red disc — the error state's only colour.
struct ErrorBadge: View {
  var body: some View {
    ZStack {
      Circle().fill(Theme.Colors.danger.opacity(0.22))
      Image(systemName: "exclamationmark")
        .font(.system(size: 9, weight: .heavy))
        .foregroundStyle(Theme.Colors.danger)
    }
    .frame(width: 16, height: 16)
    .accessibilityHidden(true)
  }
}

/// Download progress as a thin ring that fills clockwise from the top.
struct ProgressRing: View {
  let fraction: Double

  var body: some View {
    ZStack {
      Circle().stroke(.white.opacity(0.14), lineWidth: 2)
      Circle()
        .trim(from: 0, to: max(0.02, min(1, fraction)))
        .stroke(Theme.Colors.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.easeOut(duration: Theme.Motion.normal), value: fraction)
    }
    .frame(width: 14, height: 14)
    .padding(.leading, 3)
    .accessibilityHidden(true)
  }
}
