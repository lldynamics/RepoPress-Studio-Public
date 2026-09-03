import AppKit
import PublishingMarkdownCore

/// Paint-only state for a visible Markdown block marker. The source range is
/// retained for the single task-checkbox hit proxy; the text view owns the
/// actual drawing and therefore no marker needs a child NSView.
struct MarkdownBlockMarkerDrawing: Equatable {
  let marker: MarkdownSyntaxMarker
  let frame: NSRect
  let taskHitFrame: NSRect?
}

/// Accessibility-only representation of a painted task checkbox.
///
/// The checkbox is not an `NSView`: the text view owns this element while the
/// task marker is visible and vends it as an accessibility child. Keeping the
/// action on the element means VoiceOver uses the same source replacement and
/// selection-preserving path as a pointer click.
@MainActor
final class MarkdownTaskCheckboxAccessibilityElement: NSAccessibilityElement {
  let markerRange: NSRange
  private let onPress: (NSRange, Bool) -> Void
  private(set) var isChecked: Bool

  init(
    markerRange: NSRange,
    frame: NSRect,
    isChecked: Bool,
    parent: DroppableMarkdownTextView,
    onPress: @escaping (NSRange, Bool) -> Void
  ) {
    self.markerRange = markerRange
    self.onPress = onPress
    self.isChecked = isChecked
    super.init()
    setAccessibilityElement(true)
    setAccessibilityRole(.checkBox)
    setAccessibilityParent(parent)
    setAccessibilityFrameInParentSpace(frame)
    updateAccessibilityState(isChecked: isChecked, frame: frame)
  }

  required init?(coder: NSCoder) {
    nil
  }

  func updateAccessibilityState(isChecked: Bool, frame: NSRect) {
    self.isChecked = isChecked
    setAccessibilityFrameInParentSpace(frame)
    setAccessibilityRole(.checkBox)
    setAccessibilityLabel(isChecked ? "标记任务为未完成" : "标记任务为已完成")
    setAccessibilityValue(NSNumber(value: isChecked))
  }

  @objc(accessibilityPerformPress)
  func performAccessibilityPress() -> Bool {
    onPress(markerRange, !isChecked)
    return true
  }
}

extension MacMarkdownTextView.Coordinator {
  func clearBlockMarkerDrawings(in textView: NSTextView? = nil) {
    let targetTextView = textView ?? self.textView
    guard let targetTextView = targetTextView as? DroppableMarkdownTextView else {
      return
    }
    targetTextView.markdownBlockMarkerDrawings = []
    targetTextView.markdownBlockMarkerTaskToggleHandler = nil
  }

  func applyBlockMarkerDrawings(
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

    guard let droppableTextView = textView as? DroppableMarkdownTextView else {
      return
    }
    var drawings: [MarkdownBlockMarkerDrawing] = []
    drawings.reserveCapacity(desiredMarkers.count)
    for marker in desiredMarkers.values.sorted(by: { $0.range.location < $1.range.location }) {
      guard let drawing = blockMarkerDrawing(
        for: marker,
        in: textView,
        rangeResolver: rangeResolver
      ) else {
        continue
      }
      drawings.append(drawing)
    }
    droppableTextView.markdownBlockMarkerFont = syntaxHighlightPalette.baseFont
    droppableTextView.markdownBlockMarkerTaskToggleHandler = {
      [weak self, weak droppableTextView] markerRange, checked in
      guard let self, let droppableTextView else { return }
      self.setTaskMarker(markerRange, checked: checked, in: droppableTextView)
    }
    droppableTextView.markdownBlockMarkerDrawings = drawings
  }

  private func blockMarkerDrawing(
    for marker: MarkdownSyntaxMarker,
    in textView: NSTextView,
    rangeResolver: MarkdownTextKit2RangeAdapter.RangeResolver?
  ) -> MarkdownBlockMarkerDrawing? {
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
      let taskFrame = NSRect(
        x: sourceRect.minX,
        y: contentRect.midY - 8,
        width: max(16, sourceRect.width),
        height: 16
      )
      return MarkdownBlockMarkerDrawing(
        marker: marker,
        frame: taskFrame,
        taskHitFrame: taskFrame.insetBy(dx: -3, dy: -3)
      )
    }
    return MarkdownBlockMarkerDrawing(
      marker: marker,
      frame: sourceRect,
      taskHitFrame: nil
    )
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
    if let droppableTextView = textView as? DroppableMarkdownTextView {
      droppableTextView.markdownBlockMarkerDrawings = droppableTextView
        .markdownBlockMarkerDrawings
        .map { drawing in
          guard drawing.marker.range == markerRange,
            case .taskList = drawing.marker.presentation
          else {
            return drawing
          }
          return MarkdownBlockMarkerDrawing(
            marker: MarkdownSyntaxMarker(
              range: markerRange,
              presentation: .taskList(isChecked: checked)
            ),
            frame: drawing.frame,
            taskHitFrame: drawing.taskHitFrame
          )
        }
    }
  }
}

extension DroppableMarkdownTextView {
  @discardableResult
  func handleMarkdownBlockMarkerClick(at point: NSPoint) -> Bool {
    guard let drawing = markdownBlockMarkerDrawings.reversed().first(where: {
      guard case .taskList = $0.marker.presentation,
        let taskHitFrame = $0.taskHitFrame
      else {
        return false
      }
      return taskHitFrame.contains(point)
    }),
      case .taskList(let isChecked) = drawing.marker.presentation,
      let markdownBlockMarkerTaskToggleHandler
    else {
      return false
    }
    markdownBlockMarkerTaskToggleHandler(drawing.marker.range, !isChecked)
    return true
  }

  func drawMarkdownBlockMarkers(in dirtyRect: NSRect) {
    guard !markdownBlockMarkerDrawings.isEmpty else { return }
    for drawing in markdownBlockMarkerDrawings where drawing.frame.intersects(dirtyRect) {
      switch drawing.marker.presentation {
      case .unorderedList:
        drawMarkdownBlockMarkerLabel(
          "•",
          in: drawing.frame,
          color: WorkbenchThemeNSColor.success
        )
      case .orderedList(let ordinal):
        drawMarkdownBlockMarkerLabel(
          ordinal,
          in: drawing.frame,
          color: WorkbenchThemeNSColor.success
        )
      case .taskList(let isChecked):
        drawMarkdownTaskCheckbox(in: drawing.frame, isChecked: isChecked)
      case .quote:
        let barWidth: CGFloat = 2.5
        let barRect = NSRect(
          x: drawing.frame.minX + 1,
          y: drawing.frame.minY + 1,
          width: barWidth,
          height: max(2, drawing.frame.height - 2)
        )
        WorkbenchThemeNSColor.primary.withAlphaComponent(0.72).setFill()
        NSBezierPath(
          roundedRect: barRect,
          xRadius: barWidth / 2,
          yRadius: barWidth / 2
        ).fill()
      case .hidden:
        break
      }
    }
  }

  private func drawMarkdownBlockMarkerLabel(
    _ label: String,
    in frame: NSRect,
    color: NSColor
  ) {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    let attributedLabel = NSAttributedString(
      string: label,
      attributes: [
        .font: markdownBlockMarkerFont,
        .foregroundColor: color,
        .paragraphStyle: paragraphStyle,
      ]
    )
    let size = attributedLabel.size()
    attributedLabel.draw(
      in: NSRect(
        x: frame.minX,
        y: frame.midY - (size.height / 2),
        width: frame.width,
        height: size.height
      )
    )
  }

  private func drawMarkdownTaskCheckbox(in frame: NSRect, isChecked: Bool) {
    let side = min(14, max(12, frame.height - 2))
    let checkboxFrame = NSRect(
      x: frame.midX - side / 2,
      y: frame.midY - side / 2,
      width: side,
      height: side
    )
    let path = NSBezierPath(
      roundedRect: checkboxFrame,
      xRadius: 3,
      yRadius: 3
    )
    if isChecked {
      WorkbenchThemeNSColor.primary.setFill()
      path.fill()
      NSColor.white.setStroke()
      let check = NSBezierPath()
      check.lineWidth = 1.5
      check.move(to: NSPoint(x: checkboxFrame.minX + 3, y: checkboxFrame.midY))
      check.line(to: NSPoint(x: checkboxFrame.midX - 1, y: checkboxFrame.minY + 3.5))
      check.line(to: NSPoint(x: checkboxFrame.maxX - 2.5, y: checkboxFrame.maxY - 3))
      check.stroke()
    } else {
      NSColor.controlAccentColor.withAlphaComponent(0.78).setStroke()
      path.lineWidth = 1.25
      path.stroke()
    }
  }
}
