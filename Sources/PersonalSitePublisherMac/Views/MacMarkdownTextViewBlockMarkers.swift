import AppKit
import PublishingWorkbenchCore

@MainActor
final class MarkdownBlockMarkerOverlayView: NSView {
  private let presentation: MarkdownSyntaxMarker.Presentation
  private let font: NSFont
  private let onTaskToggle: ((Bool) -> Void)?
  private var checkbox: NSButton?

  init(
    frame frameRect: NSRect,
    presentation: MarkdownSyntaxMarker.Presentation,
    font: NSFont,
    onTaskToggle: ((Bool) -> Void)? = nil
  ) {
    self.presentation = presentation
    self.font = font
    self.onTaskToggle = onTaskToggle
    super.init(frame: frameRect)
    setAccessibilityElement(false)
    if case .taskList(let isChecked) = presentation {
      let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleTask))
      checkbox.controlSize = .small
      checkbox.state = isChecked ? .on : .off
      checkbox.setAccessibilityLabel(isChecked ? "标记任务为未完成" : "标记任务为已完成")
      addSubview(checkbox)
      self.checkbox = checkbox
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    checkbox == nil ? nil : super.hitTest(point)
  }

  override func layout() {
    super.layout()
    guard let checkbox else { return }
    let side = min(16, max(12, bounds.height))
    checkbox.frame = NSRect(
      x: bounds.minX,
      y: bounds.midY - (side / 2),
      width: side,
      height: side
    )
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    switch presentation {
    case .unorderedList:
      drawLabel("•", color: WorkbenchThemeNSColor.success)
    case .orderedList(let ordinal):
      drawLabel(ordinal, color: WorkbenchThemeNSColor.success)
    case .taskList:
      break
    case .quote:
      let barWidth: CGFloat = 2.5
      let barRect = NSRect(
        x: bounds.minX + 1,
        y: bounds.minY + 1,
        width: barWidth,
        height: max(2, bounds.height - 2)
      )
      WorkbenchThemeNSColor.primary.withAlphaComponent(0.72).setFill()
      NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    case .hidden:
      break
    }
  }

  @objc private func toggleTask() {
    guard let checkbox else { return }
    let isChecked = checkbox.state == .on
    checkbox.setAccessibilityLabel(isChecked ? "标记任务为未完成" : "标记任务为已完成")
    onTaskToggle?(isChecked)
  }

  private func drawLabel(_ label: String, color: NSColor) {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    let attributedLabel = NSAttributedString(
      string: label,
      attributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraphStyle,
      ]
    )
    let size = attributedLabel.size()
    attributedLabel.draw(
      in: NSRect(
        x: bounds.minX,
        y: bounds.midY - (size.height / 2),
        width: bounds.width,
        height: size.height
      )
    )
  }
}

extension MacMarkdownTextView.Coordinator {
  func clearBlockMarkerOverlays() {
    for overlay in blockMarkerOverlayViews.values {
      overlay.removeFromSuperview()
    }
    blockMarkerOverlayViews.removeAll()
    blockMarkerOverlayMarkers.removeAll()
  }

  func applyBlockMarkerOverlays(
    _ markers: [MarkdownSyntaxMarker],
    in textView: NSTextView,
    rangeResolver: MarkdownTextKit2RangeAdapter.RangeResolver? = nil
  ) {
    let desiredMarkers = Dictionary(
      markers.lazy
        .filter { $0.presentation != .hidden }
        .map { ($0.range.location, $0) },
      uniquingKeysWith: { _, newest in newest }
    )

    let obsoleteLocations = blockMarkerOverlayViews.keys.filter {
      desiredMarkers[$0] != blockMarkerOverlayMarkers[$0]
    }
    for location in obsoleteLocations {
      blockMarkerOverlayViews[location]?.removeFromSuperview()
      blockMarkerOverlayViews[location] = nil
      blockMarkerOverlayMarkers[location] = nil
    }

    if let rangeResolver {
      rangeResolver.manager.ensureLayout(for: rangeResolver.baseTextRange)
    }
    for (location, marker) in desiredMarkers {
      guard let overlayFrame = blockMarkerOverlayFrame(
        for: marker,
        in: textView,
        rangeResolver: rangeResolver
      ) else {
        blockMarkerOverlayViews[location]?.removeFromSuperview()
        blockMarkerOverlayViews[location] = nil
        blockMarkerOverlayMarkers[location] = nil
        continue
      }
      if let overlay = blockMarkerOverlayViews[location],
        blockMarkerOverlayMarkers[location] == marker
      {
        overlay.frame = overlayFrame
        continue
      }
      let overlay = MarkdownBlockMarkerOverlayView(
        frame: overlayFrame,
        presentation: marker.presentation,
        font: syntaxHighlightPalette.baseFont,
        onTaskToggle: { [weak self, weak textView] isChecked in
          guard let self, let textView else { return }
          self.setTaskMarker(
            marker.range,
            checked: isChecked,
            in: textView
          )
        }
      )
      textView.addSubview(overlay)
      blockMarkerOverlayViews[location] = overlay
      blockMarkerOverlayMarkers[location] = marker
    }
  }

  private func blockMarkerOverlayFrame(
    for marker: MarkdownSyntaxMarker,
    in textView: NSTextView,
    rangeResolver: MarkdownTextKit2RangeAdapter.RangeResolver?
  ) -> NSRect? {
    let sourceRect = rangeResolver.flatMap {
      MarkdownTextKit2RangeAdapter.rect(
        for: marker.range,
        using: $0,
        in: textView,
        ensuringLayout: false
      )
    } ?? MarkdownTextKit2RangeAdapter.rect(for: marker.range, in: textView)
    guard let sourceRect else { return nil }
    if case .taskList = marker.presentation,
      NSMaxRange(marker.range) < (textView.string as NSString).length,
      let contentRect = rangeResolver.flatMap({
        MarkdownTextKit2RangeAdapter.rect(
          for: NSRange(location: NSMaxRange(marker.range), length: 1),
          using: $0,
          in: textView,
          ensuringLayout: false
        )
      }) ?? MarkdownTextKit2RangeAdapter.rect(
        for: NSRange(location: NSMaxRange(marker.range), length: 1),
        in: textView
      )
    {
      return NSRect(
        x: sourceRect.minX,
        y: contentRect.midY - 8,
        width: max(16, sourceRect.width),
        height: 16
      )
    }
    return sourceRect
  }

  func setTaskMarker(
    _ markerRange: NSRange,
    checked: Bool,
    in textView: NSTextView
  ) {
    let source = textView.string as NSString
    guard NSMaxRange(markerRange) <= source.length else { return }
    let marker = source.substring(with: markerRange) as NSString
    let openingBracket = marker.range(of: "[")
    guard openingBracket.location != NSNotFound,
      openingBracket.location + 2 < marker.length,
      marker.character(at: openingBracket.location + 2) == 93
    else { return }
    let stateRange = NSRange(
      location: markerRange.location + openingBracket.location + 1,
      length: 1
    )
    let currentState = source.substring(with: stateRange)
    guard currentState == " " || currentState == "x" || currentState == "X" else { return }
    let replacement = checked ? "x" : " "
    guard currentState != replacement else { return }
    let selection = textView.selectedRange()
    textView.insertText(replacement, replacementRange: stateRange)
    textView.setSelectedRange(selection)
    updateSelectionBinding(from: selection)
  }
}
