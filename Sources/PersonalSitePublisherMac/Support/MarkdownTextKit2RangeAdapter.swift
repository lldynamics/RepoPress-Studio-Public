import AppKit
import PublishingWorkbenchCore

@MainActor
enum MarkdownTextKit2RangeAdapter {
  struct RangeResolver {
    let manager: NSTextLayoutManager
    let contentManager: NSTextContentManager
    let baseRange: NSRange
    let baseTextRange: NSTextRange

    func textRange(for range: NSRange) -> NSTextRange? {
      guard range.location != NSNotFound,
        range.location >= baseRange.location,
        NSMaxRange(range) <= NSMaxRange(baseRange),
        let start = contentManager.location(
          baseTextRange.location,
          offsetBy: range.location - baseRange.location
        ),
        let end = contentManager.location(start, offsetBy: range.length)
      else { return nil }
      return NSTextRange(location: start, end: end)
    }
  }

  static func textRange(
    for range: NSRange,
    in textView: NSTextView
  ) -> NSTextRange? {
    guard let contentManager = textView.textLayoutManager?.textContentManager else {
      return nil
    }
    let length = (textView.string as NSString).length
    guard range.location != NSNotFound,
      range.location >= 0,
      range.length >= 0,
      range.location <= length,
      range.length <= length - range.location,
      let start = contentManager.location(
        contentManager.documentRange.location,
        offsetBy: range.location
      ),
      let end = contentManager.location(start, offsetBy: range.length)
    else {
      return nil
    }
    return NSTextRange(location: start, end: end)
  }

  static func range(
    for textRange: NSTextRange,
    in textView: NSTextView
  ) -> NSRange? {
    guard let contentManager = textView.textLayoutManager?.textContentManager else {
      return nil
    }
    let location = contentManager.offset(
      from: contentManager.documentRange.location,
      to: textRange.location
    )
    let length = contentManager.offset(
      from: textRange.location,
      to: textRange.endLocation
    )
    guard location >= 0, length >= 0 else { return nil }
    return NSRange(location: location, length: length)
  }

  static func visibleRange(in textView: NSTextView) -> NSRange? {
    guard
      let viewportRange = textView.textLayoutManager?
        .textViewportLayoutController.viewportRange
    else {
      return nil
    }
    return range(for: viewportRange, in: textView)
  }

  static func rangeResolver(
    for baseRange: NSRange,
    in textView: NSTextView
  ) -> RangeResolver? {
    guard let manager = textView.textLayoutManager,
      let contentManager = manager.textContentManager,
      let baseTextRange = textRange(for: baseRange, in: textView)
    else { return nil }
    return RangeResolver(
      manager: manager,
      contentManager: contentManager,
      baseRange: baseRange,
      baseTextRange: baseTextRange
    )
  }

  static func addRenderingAttributes(
    _ attributes: [NSAttributedString.Key: Any],
    for range: NSRange,
    in textView: NSTextView
  ) {
    guard let manager = textView.textLayoutManager,
      let textRange = textRange(for: range, in: textView)
    else { return }
    for (attribute, value) in attributes {
      manager.addRenderingAttribute(attribute, value: value, for: textRange)
    }
  }

  static func addRenderingAttributes(
    _ attributes: [NSAttributedString.Key: Any],
    for range: NSRange,
    using resolver: RangeResolver
  ) {
    guard let textRange = resolver.textRange(for: range) else { return }
    for (attribute, value) in attributes {
      resolver.manager.addRenderingAttribute(attribute, value: value, for: textRange)
    }
  }

  @discardableResult
  static func applySyntaxHighlighting(
    _ snapshot: MarkdownSyntaxHighlightSnapshot,
    defaultAttributes: [NSAttributedString.Key: Any],
    styleAttributes: [MarkdownSyntaxHighlightStyle: [NSAttributedString.Key: Any]],
    in textView: NSTextView
  ) -> Int {
    guard let resolver = rangeResolver(for: snapshot.range, in: textView) else {
      return 0
    }

    for (attribute, value) in defaultAttributes {
      resolver.manager.addRenderingAttribute(
        attribute,
        value: value,
        for: resolver.baseTextRange
      )
    }

    var appliedRunCount = 0
    for run in snapshot.runs {
      let intersection = NSIntersectionRange(run.range, snapshot.range)
      guard intersection.length > 0,
        let attributes = styleAttributes[run.style],
        let runRange = resolver.textRange(for: intersection)
      else {
        continue
      }
      for (attribute, value) in attributes {
        resolver.manager.addRenderingAttribute(attribute, value: value, for: runRange)
      }
      appliedRunCount += 1
    }
    for fontRun in MarkdownTextViewSemanticAttributeApplier.composedFontRuns(
      snapshot,
      within: snapshot.range,
      defaultAttributes: defaultAttributes,
      styleAttributes: styleAttributes
    ) {
      guard let runRange = resolver.textRange(for: fontRun.range) else { continue }
      resolver.manager.addRenderingAttribute(.font, value: fontRun.font, for: runRange)
    }
    return appliedRunCount
  }

  static func removeRenderingAttributes(
    _ attributes: [NSAttributedString.Key],
    for range: NSRange,
    in textView: NSTextView
  ) {
    guard let manager = textView.textLayoutManager,
      let textRange = textRange(for: range, in: textView)
    else {
      return
    }
    for attribute in attributes {
      manager.removeRenderingAttribute(attribute, for: textRange)
    }
  }

  static func removeRenderingAttribute(
    _ attribute: NSAttributedString.Key,
    for range: NSRange,
    in textView: NSTextView
  ) {
    guard let manager = textView.textLayoutManager,
      let textRange = textRange(for: range, in: textView)
    else { return }
    manager.removeRenderingAttribute(attribute, for: textRange)
  }

  static func rect(for range: NSRange, in textView: NSTextView) -> NSRect? {
    guard let manager = textView.textLayoutManager,
      let textRange = textRange(for: range, in: textView)
    else { return nil }

    manager.ensureLayout(for: textRange)
    var result = NSRect.null
    manager.enumerateTextSegments(
      in: textRange,
      type: .standard,
      options: []
    ) { _, rect, _, _ in
      result = result.union(rect)
      return true
    }
    if !result.isNull, !result.isEmpty {
      return result.offsetBy(
        dx: textView.textContainerOrigin.x,
        dy: textView.textContainerOrigin.y
      )
    }

    let screenRect = textView.firstRect(
      forCharacterRange: range,
      actualRange: nil
    )
    guard !screenRect.isEmpty else { return nil }
    let windowRect = textView.window?.convertFromScreen(screenRect) ?? screenRect
    return textView.convert(windowRect, from: nil)
  }

  static func rect(
    for range: NSRange,
    using resolver: RangeResolver,
    in textView: NSTextView,
    ensuringLayout: Bool = true
  ) -> NSRect? {
    guard let textRange = resolver.textRange(for: range) else { return nil }
    if ensuringLayout {
      resolver.manager.ensureLayout(for: textRange)
    }
    var result = NSRect.null
    resolver.manager.enumerateTextSegments(
      in: textRange,
      type: .standard,
      options: []
    ) { _, rect, _, _ in
      result = result.union(rect)
      return true
    }
    if !result.isNull, !result.isEmpty {
      return result.offsetBy(
        dx: textView.textContainerOrigin.x,
        dy: textView.textContainerOrigin.y
      )
    }
    return nil
  }
}
