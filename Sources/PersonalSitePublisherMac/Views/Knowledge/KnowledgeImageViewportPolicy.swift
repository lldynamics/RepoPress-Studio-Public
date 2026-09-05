import CoreGraphics

/// Pure geometry used by the image viewer and its boundary tests.
enum KnowledgeImageViewportPolicy {
  static let minimumZoom: CGFloat = 0.5
  static let maximumZoom: CGFloat = 4

  static func clampedZoom(_ value: CGFloat) -> CGFloat {
    min(maximumZoom, max(minimumZoom, value))
  }

  static func contentSize(imageSize: CGSize, viewportSize: CGSize, zoom: CGFloat) -> CGSize {
    guard imageSize.width > 0, imageSize.height > 0,
      viewportSize.width > 0, viewportSize.height > 0
    else { return .zero }
    let fit = min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
    let fitted = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
    let scale = clampedZoom(zoom)
    return CGSize(
      width: max(viewportSize.width, fitted.width * scale),
      height: max(viewportSize.height, fitted.height * scale)
    )
  }

}
