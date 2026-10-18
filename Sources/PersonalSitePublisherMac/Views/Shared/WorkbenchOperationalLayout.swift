import Foundation

extension WorkbenchPageMetrics {
  /// Use the outer page geometry, never a measurement of the column itself.
  /// The minimum preserves the existing split layout; the cap keeps the main column dominant.
  static func operationalContextWidth(forAvailableWidth availableWidth: CGFloat) -> CGFloat {
    min(440, max(operationalContextWidth, availableWidth * 0.28))
  }
}
