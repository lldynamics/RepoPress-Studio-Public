import AppKit
import SwiftUI

/// Secondary text that stays readable on 1x external displays.
///
/// The system `.secondary` style is black at 50% opacity, which measures about
/// 3.9:1 on white and falls below 4.5:1 on window backgrounds. Workbench text
/// uses a stronger tint instead (about 5.7:1 on white) while still deferring to
/// the system hierarchy on emphasized backgrounds, such as focused list
/// selections, where the label must turn light.
struct WorkbenchSecondaryTextStyle: ShapeStyle {
  private static let color = Color(
    nsColor: NSColor(name: nil) { appearance in
      switch appearance.bestMatch(from: [
        .accessibilityHighContrastAqua,
        .accessibilityHighContrastDarkAqua,
        .aqua,
        .darkAqua,
      ]) {
      case .accessibilityHighContrastAqua:
        return NSColor(white: 0, alpha: 0.76)
      case .accessibilityHighContrastDarkAqua:
        return NSColor(white: 1, alpha: 0.82)
      case .darkAqua:
        return NSColor(white: 1, alpha: 0.68)
      default:
        return NSColor(white: 0, alpha: 0.60)
      }
    })

  func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
    if environment.backgroundProminence == .increased {
      return AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }
    return AnyShapeStyle(Self.color)
  }
}

extension ShapeStyle where Self == WorkbenchSecondaryTextStyle {
  /// Use for supporting text and metadata instead of the system `.secondary`.
  static var workbenchSecondary: WorkbenchSecondaryTextStyle { WorkbenchSecondaryTextStyle() }
}

extension View {
  /// Titles of articles, notes and other named items truncate at the end so
  /// the reader keeps the beginning of the name; paths and URLs keep using
  /// `workbenchTruncatedIdentity`, which preserves both ends.
  func workbenchTruncatedTitle(_ value: String, lineLimit: Int = 1) -> some View {
    workbenchTruncatedIdentity(value, lineLimit: lineLimit, truncationMode: .tail)
  }
}
