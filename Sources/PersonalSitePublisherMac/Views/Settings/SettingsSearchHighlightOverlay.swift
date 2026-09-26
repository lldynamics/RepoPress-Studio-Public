import SwiftUI

struct SettingsSearchHighlightOverlay: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  let highlight: SettingsSearchHighlight?
  let anchorFrames: [SettingsSubsection: CGRect]
  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

  var body: some View {
    GeometryReader { geometry in
      if let frame = highlight?.visibleFrame(
        anchorFrames: anchorFrames,
        viewport: CGRect(origin: .zero, size: geometry.size)
      ) {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .fill(workbenchAccentColor.opacity(0.08))
          .overlay {
            RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
              .strokeBorder(
                differentiateWithoutColor ? Color.primary : workbenchAccentColor,
                lineWidth: 2
              )
          }
          .frame(width: frame.width, height: frame.height)
          .position(x: frame.midX, y: frame.midY)
      }
    }
    .clipped()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
