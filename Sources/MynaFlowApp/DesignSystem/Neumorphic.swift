import SwiftUI

/// Soft extruded surface: the card, the resting control.
struct RaisedSurface: ViewModifier {
  var radius: CGFloat = Theme.Radius.card
  var padding: CGFloat = Theme.Spacing.lg

  func body(content: Content) -> some View {
    content
      .padding(padding)
      .background(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(Theme.Colors.surface)
          .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
              .strokeBorder(
                LinearGradient(
                  colors: [Theme.Colors.highlight, .clear, Theme.Colors.shade.opacity(0.3)],
                  startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1))
          .shadow(
            color: Theme.Colors.shade, radius: Theme.Elevation.raisedShadeRadius,
            x: Theme.Elevation.raisedOffset, y: Theme.Elevation.raisedOffset)
          .shadow(
            color: Theme.Colors.highlight, radius: Theme.Elevation.raisedLightRadius,
            x: -Theme.Elevation.raisedOffset / 2, y: -Theme.Elevation.raisedOffset / 2))
  }
}

/// Pressed-in surface: fields, wells, list grounds.
struct InsetSurface: ViewModifier {
  var radius: CGFloat = Theme.Radius.control
  var padding: CGFloat = Theme.Spacing.md

  func body(content: Content) -> some View {
    content
      .padding(padding)
      .background(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(Theme.Colors.well)
          .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
              .strokeBorder(Theme.Colors.shade.opacity(0.5), lineWidth: 1)
              .blur(radius: 1.5)
              .offset(x: 1, y: 1)
              .mask(RoundedRectangle(cornerRadius: radius, style: .continuous)))
          .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
              .strokeBorder(Theme.Colors.hairline, lineWidth: 0.5)))
  }
}

extension View {
  func raised(radius: CGFloat = Theme.Radius.card, padding: CGFloat = Theme.Spacing.lg)
    -> some View
  {
    modifier(RaisedSurface(radius: radius, padding: padding))
  }

  func inset(radius: CGFloat = Theme.Radius.control, padding: CGFloat = Theme.Spacing.md)
    -> some View
  {
    modifier(InsetSurface(radius: radius, padding: padding))
  }
}

/// Primary action: a raised pill that presses in.
struct NeuButtonStyle: ButtonStyle {
  var prominent = false
  var destructive = false

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    let foreground: Color =
      destructive
      ? Theme.Colors.danger : prominent ? Theme.Colors.base : Theme.Colors.textPrimary
    return configuration.label
      .font(Theme.Fonts.bodyStrong)
      .foregroundStyle(foreground)
      .padding(.horizontal, Theme.Spacing.md)
      .padding(.vertical, Theme.Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
          .fill(prominent ? Theme.Colors.accent : Theme.Colors.surface)
          .shadow(
            color: pressed ? .clear : Theme.Colors.shade, radius: 8, x: 3, y: 3)
          .shadow(
            color: pressed ? .clear : Theme.Colors.highlight, radius: 6, x: -2, y: -2))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
          .strokeBorder(Theme.Colors.hairline, lineWidth: 1))
      .scaleEffect(pressed ? 0.985 : 1)
      .animation(.easeOut(duration: Theme.Motion.fast), value: pressed)
  }
}

/// Keycap chip for shortcuts ("⌃⌥1").
struct Keycap: View {
  let label: String

  var body: some View {
    Text(label)
      .font(Theme.Fonts.keycap)
      .foregroundStyle(Theme.Colors.textPrimary)
      .padding(.horizontal, Theme.Spacing.sm)
      .padding(.vertical, Theme.Spacing.xs)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Theme.Colors.surface)
          .shadow(color: Theme.Colors.shade, radius: 3, x: 1, y: 2))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(Theme.Colors.hairline, lineWidth: 1))
  }
}

/// Section heading with the app's confident, spaced-out capitals.
struct SectionLabel: View {
  let text: String

  var body: some View {
    Text(text.uppercased())
      .font(Theme.Fonts.caption)
      .kerning(1.4)
      .foregroundStyle(Theme.Colors.textTertiary)
  }
}

/// Text field that sits in a well.
struct NeuTextField: View {
  let placeholder: String
  @Binding var text: String
  var monospaced = false

  var body: some View {
    TextField(placeholder, text: $text)
      .textFieldStyle(.plain)
      .font(monospaced ? Theme.Fonts.mono : Theme.Fonts.body)
      .foregroundStyle(Theme.Colors.textPrimary)
      .inset(padding: Theme.Spacing.sm + 2)
  }
}
