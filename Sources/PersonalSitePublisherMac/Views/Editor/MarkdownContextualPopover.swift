import SwiftUI

enum MarkdownContextualPopoverEdge: Equatable {
  case above
  case below
}

enum MarkdownContextualPopoverHorizontalAlignment: Equatable {
  case leading
  case center
}

struct MarkdownContextualPopoverPlacement: Equatable {
  let origin: CGPoint
  let edge: MarkdownContextualPopoverEdge

  static func resolve(
    anchor: CGRect,
    contentSize: CGSize,
    containerSize: CGSize,
    preferredEdge: MarkdownContextualPopoverEdge,
    horizontalAlignment: MarkdownContextualPopoverHorizontalAlignment,
    gap: CGFloat = 8,
    margin: CGFloat = 12
  ) -> Self {
    let safeMargin = max(0, margin)
    let safeGap = max(0, gap)
    let maximumX = max(safeMargin, containerSize.width - safeMargin - contentSize.width)
    let desiredX: CGFloat =
      switch horizontalAlignment {
      case .leading:
        anchor.minX
      case .center:
        anchor.midX - contentSize.width / 2
      }
    let x = min(max(desiredX, safeMargin), maximumX)

    let aboveY = anchor.minY - safeGap - contentSize.height
    let belowY = anchor.maxY + safeGap
    let maximumY = max(safeMargin, containerSize.height - safeMargin - contentSize.height)
    let fitsAbove = aboveY >= safeMargin
    let fitsBelow = belowY <= maximumY
    let resolvedEdge: MarkdownContextualPopoverEdge
    switch preferredEdge {
    case .above where fitsAbove:
      resolvedEdge = .above
    case .below where fitsBelow:
      resolvedEdge = .below
    case .above where fitsBelow:
      resolvedEdge = .below
    case .below where fitsAbove:
      resolvedEdge = .above
    default:
      let spaceAbove = max(0, anchor.minY - safeMargin - safeGap)
      let spaceBelow = max(0, containerSize.height - safeMargin - safeGap - anchor.maxY)
      resolvedEdge = spaceAbove >= spaceBelow ? .above : .below
    }

    let desiredY = resolvedEdge == .above ? aboveY : belowY
    let y = min(max(desiredY, safeMargin), maximumY)
    return Self(origin: CGPoint(x: x, y: y), edge: resolvedEdge)
  }
}

struct MarkdownContextualPopoverLayout: Layout {
  let anchor: CGRect
  let preferredEdge: MarkdownContextualPopoverEdge
  let horizontalAlignment: MarkdownContextualPopoverHorizontalAlignment
  var gap: CGFloat = 8
  var margin: CGFloat = 12

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    guard let subview = subviews.first else { return }
    let availableSize = CGSize(
      width: max(0, bounds.width - (margin * 2)),
      height: max(0, bounds.height - (margin * 2))
    )
    let contentSize = subview.sizeThatFits(
      ProposedViewSize(width: availableSize.width, height: availableSize.height)
    )
    let placement = MarkdownContextualPopoverPlacement.resolve(
      anchor: anchor.offsetBy(dx: -bounds.minX, dy: -bounds.minY),
      contentSize: contentSize,
      containerSize: bounds.size,
      preferredEdge: preferredEdge,
      horizontalAlignment: horizontalAlignment,
      gap: gap,
      margin: margin
    )
    subview.place(
      at: CGPoint(
        x: bounds.minX + placement.origin.x,
        y: bounds.minY + placement.origin.y
      ),
      anchor: .topLeading,
      proposal: ProposedViewSize(contentSize)
    )
  }
}
