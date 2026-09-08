import SwiftUI

struct SettingsSearchHighlightOverlay: View {
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
          .fill(Color.accentColor.opacity(0.08))
          .overlay {
            RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
              .strokeBorder(
                differentiateWithoutColor ? Color.primary : Color.accentColor,
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
