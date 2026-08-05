import AppKit
import Foundation
import SwiftUI

@MainActor
public final class ThinRedScroller: NSScroller {
  public static let thinWidth: CGFloat = 3.5

  override public class var isCompatibleWithOverlayScrollers: Bool {
    true
  }

  override public class func scrollerWidth(
    for controlSize: NSControl.ControlSize,
    scrollerStyle: NSScroller.Style
  ) -> CGFloat {
    thinWidth
  }

  override public func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
    // Keep slot completely transparent for a clean borderless look
  }

  override public func drawKnob() {
    let rect = self.rect(for: .knob)
    guard !rect.isEmpty else { return }

    let knobRect: NSRect
    let isVertical = bounds.width < bounds.height
    if isVertical {
      let x = bounds.maxX - Self.thinWidth
      knobRect = NSRect(x: x, y: rect.minY, width: Self.thinWidth, height: rect.height)
    } else {
      let y = bounds.maxY - Self.thinWidth
      knobRect = NSRect(x: rect.minX, y: y, width: rect.width, height: Self.thinWidth)
    }

    let path = NSBezierPath(
      roundedRect: knobRect,
      xRadius: Self.thinWidth / 2.0,
      yRadius: Self.thinWidth / 2.0
    )
    let redColor = NSColor.systemRed.withAlphaComponent(0.85)
    redColor.setFill()
    path.fill()
  }
}

extension NSScrollView {
  private static let swizzleTileOnce: Void = {
    let originalSelector = #selector(tile)
    let swizzledSelector = #selector(thinRed_tile)
    guard let originalMethod = class_getInstanceMethod(NSScrollView.self, originalSelector),
          let swizzledMethod = class_getInstanceMethod(NSScrollView.self, swizzledSelector) else { return }
    method_exchangeImplementations(originalMethod, swizzledMethod)
  }()

  @MainActor
  public static func enableGlobalThinRedScrollers() {
    _ = swizzleTileOnce
  }

  @objc private func thinRed_tile() {
    thinRed_tile()
    if hasVerticalScroller, !(verticalScroller is ThinRedScroller) {
      let scroller = ThinRedScroller()
      scroller.scrollerStyle = .overlay
      verticalScroller = scroller
    }
    if hasHorizontalScroller, !(horizontalScroller is ThinRedScroller) {
      let scroller = ThinRedScroller()
      scroller.scrollerStyle = .overlay
      horizontalScroller = scroller
    }
  }
}
