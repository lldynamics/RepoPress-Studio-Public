import SwiftUI

enum WorkbenchCornerRadius {
  static let chartBar: CGFloat = 3
  static let control: CGFloat = 6
  static let card: CGFloat = 8
}

enum WorkbenchOpacity {
  static let subtleBackground = 0.20
  static let panelBackground = 0.28
  static let cardBackground = 0.35
  static let controlBackground = 0.45
  static let badgeBackground = 0.55
  static let codeBlockBackground = 0.06
  static let selectionBackground = 0.12
  static let accentBackground = 0.16
  static let noticeBackground = 0.10
  static let warningBackground = 0.08
  static let separator = 0.70
  static let chartSecondary = 0.28
  static let chartPrimary = 0.60
  static let chartEmphasis = 0.70
}

enum WorkbenchBackgroundStyle {
  static var subtle: AnyShapeStyle {
    AnyShapeStyle(.quaternary.opacity(WorkbenchOpacity.subtleBackground))
  }

  static var panel: AnyShapeStyle {
    AnyShapeStyle(.quaternary.opacity(WorkbenchOpacity.panelBackground))
  }

  static var card: AnyShapeStyle {
    AnyShapeStyle(.quaternary.opacity(WorkbenchOpacity.cardBackground))
  }

  static var control: AnyShapeStyle {
    AnyShapeStyle(.quaternary.opacity(WorkbenchOpacity.controlBackground))
  }

  static var badge: AnyShapeStyle {
    AnyShapeStyle(.quaternary.opacity(WorkbenchOpacity.badgeBackground))
  }

  static var codeBlock: AnyShapeStyle {
    AnyShapeStyle(.quaternary.opacity(WorkbenchOpacity.codeBlockBackground))
  }
}

extension Font {
  static let workbenchCardTitle: Font = .callout.weight(.semibold)
  static let workbenchMetricValue: Font = .title3.weight(.semibold)
  static let workbenchPath: Font = .caption.monospaced()
}
