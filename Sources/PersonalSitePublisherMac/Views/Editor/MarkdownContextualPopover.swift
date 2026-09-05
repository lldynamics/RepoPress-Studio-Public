import CoreGraphics
import Foundation

/// A TextKit range expressed in the SwiftUI editor viewport. SwiftUI keeps
/// presentation state while the AppKit bridge supplies only this geometry.
struct MarkdownContextualPopoverAnchor: Equatable {
  let selection: NSRange
  let rect: CGRect
  let viewport: CGRect

  var isUsable: Bool {
    selection.location != NSNotFound && !rect.isNull && !rect.isInfinite && !rect.isEmpty
      && !viewport.isNull && !viewport.isInfinite && !viewport.isEmpty
  }
}

enum MarkdownContextualPopoverPreferredEdge: Equatable {
  case above
  case below
}

enum MarkdownContextualPopoverAnchorResolver {
  /// Mirrors the editor selection bridge: Markdown-body ranges are relative to
  /// the body, while a Front Matter source selection is represented by the
  /// source-mode zero range.
  static func selection(
    forDocumentRange documentRange: NSRange,
    documentUTF16Length: Int,
    bodyUTF16Offset: Int,
    bodyUTF16Length: Int
  ) -> NSRange? {
    guard isValid(documentRange, length: max(0, documentUTF16Length)) else { return nil }
    let bodyOffset = max(0, bodyUTF16Offset)
    let bodyLength = max(0, bodyUTF16Length)
    guard documentRange.location >= bodyOffset else {
      return NSRange(location: 0, length: 0)
    }
    let bodyLocation = min(documentRange.location - bodyOffset, bodyLength)
    return NSRange(
      location: bodyLocation,
      length: min(documentRange.length, bodyLength - bodyLocation)
    )
  }

  static func anchor(
    selection: NSRange,
    textRect: CGRect,
    visibleTextRect: CGRect,
    viewport: CGRect
  ) -> MarkdownContextualPopoverAnchor? {
    guard !textRect.isNull, !textRect.isInfinite, !textRect.isEmpty,
      !visibleTextRect.isNull, !visibleTextRect.isInfinite,
      textRect.intersects(visibleTextRect)
    else { return nil }
    let anchor = MarkdownContextualPopoverAnchor(
      selection: selection,
      rect: textRect.offsetBy(dx: -visibleTextRect.minX, dy: -visibleTextRect.minY),
      viewport: viewport
    )
    return anchor.isUsable ? anchor : nil
  }

  static func normalizedTextRect(_ rect: CGRect, for selection: NSRange) -> CGRect {
    guard selection.length == 0 else { return rect }
    return CGRect(
      x: rect.minX,
      y: rect.minY,
      width: max(1, rect.width),
      height: max(1, rect.height)
    )
  }

  static func isValid(_ range: NSRange, length: Int) -> Bool {
    range.location != NSNotFound
      && range.location >= 0
      && range.length >= 0
      && range.location <= length
      && range.length <= length - range.location
  }
}

struct MarkdownContextualPopoverPlacement: Equatable {
  let frame: CGRect
  let edge: MarkdownContextualPopoverPreferredEdge

  static func resolve(
    anchor: MarkdownContextualPopoverAnchor,
    contentSize: CGSize,
    preferredEdge: MarkdownContextualPopoverPreferredEdge,
    gap: CGFloat = 8,
    margin: CGFloat = 12
  ) -> MarkdownContextualPopoverPlacement? {
    guard anchor.isUsable, contentSize.width > 0, contentSize.height > 0,
      contentSize.width.isFinite, contentSize.height.isFinite
    else { return nil }

    let viewport = anchor.viewport
    let width = min(contentSize.width, max(1, viewport.width - margin * 2))
    let aboveY = anchor.rect.minY - gap - contentSize.height
    let belowY = anchor.rect.maxY + gap
    let canFitAbove = aboveY >= viewport.minY + margin
    let canFitBelow = belowY + contentSize.height <= viewport.maxY - margin
    let edge: MarkdownContextualPopoverPreferredEdge
    switch preferredEdge {
    case .above where canFitAbove || !canFitBelow: edge = .above
    case .below where canFitBelow || !canFitAbove: edge = .below
    case .above: edge = .below
    case .below: edge = .above
    }
    let idealY = edge == .above ? aboveY : belowY
    let y = min(
      max(idealY, viewport.minY + margin),
      max(viewport.minY + margin, viewport.maxY - margin - contentSize.height))
    let idealX = anchor.rect.midX - width / 2
    let x = min(
      max(idealX, viewport.minX + margin),
      max(viewport.minX + margin, viewport.maxX - margin - width))
    return MarkdownContextualPopoverPlacement(
      frame: CGRect(x: x, y: y, width: width, height: contentSize.height), edge: edge)
  }
}
