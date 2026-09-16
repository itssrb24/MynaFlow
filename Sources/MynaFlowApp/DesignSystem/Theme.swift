import SwiftUI

/// Design tokens. Every feature view reads from here — no raw colors,
/// spacing, or radii in views — so the final Stitch treatment lands by
/// changing tokens, not rewriting views.
///
/// Direction: dark, minimal, neumorphic, luxury. Near-black surfaces with
/// soft dual-source extrusion; depth as hierarchy, never decoration.
enum Theme {
  enum Colors {
    /// Window ground.
    static let base = Color(red: 0.075, green: 0.078, blue: 0.086)
    /// Raised surfaces (cards, controls at rest).
    static let surface = Color(red: 0.094, green: 0.098, blue: 0.108)
    /// Inset surfaces (fields, wells).
    static let well = Color(red: 0.062, green: 0.065, blue: 0.072)
    /// Neumorphic light source (top-left highlight).
    static let highlight = Color.white.opacity(0.045)
    /// Neumorphic shadow source (bottom-right).
    static let shade = Color.black.opacity(0.55)
    static let hairline = Color.white.opacity(0.06)

    static let textPrimary = Color(white: 0.92)
    static let textSecondary = Color(white: 0.62)
    static let textTertiary = Color(white: 0.42)

    /// Warm brass accent — hardware-dial rather than dashboard-blue.
    static let accent = Color(red: 0.86, green: 0.72, blue: 0.48)
    static let accentMuted = accent.opacity(0.18)
    static let success = Color(red: 0.48, green: 0.78, blue: 0.56)
    static let warning = Color(red: 0.92, green: 0.66, blue: 0.32)
    static let danger = Color(red: 0.88, green: 0.42, blue: 0.40)
    static let recordingToggle = warning
  }

  enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 14
    static let lg: CGFloat = 22
    static let xl: CGFloat = 36
    static let section: CGFloat = 48
  }

  enum Radius {
    static let control: CGFloat = 10
    static let card: CGFloat = 18
    static let pill: CGFloat = 999
  }

  enum Fonts {
    static let display = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let title = Font.system(size: 18, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 13, weight: .regular)
    static let bodyStrong = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 11, weight: .medium)
    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let keycap = Font.system(size: 12, weight: .semibold, design: .rounded)
  }

  enum Motion {
    static let fast: Double = 0.15
    static let normal: Double = 0.28
    static let ease = Animation.easeOut(duration: normal)
  }

  enum Elevation {
    /// Dual-source extrusion: light from top-left, shade to bottom-right.
    static let raisedLightRadius: CGFloat = 10
    static let raisedShadeRadius: CGFloat = 16
    static let raisedOffset: CGFloat = 6
    static let insetDepth: CGFloat = 4
  }
}
