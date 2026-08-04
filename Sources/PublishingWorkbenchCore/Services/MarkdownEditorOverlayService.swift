import Foundation

public struct MarkdownEditorDiagnosticOverlay: Hashable, Sendable {
  public var range: NSRange
  public var severity: MarkdownInlineDiagnosticSeverity

  public init(
    range: NSRange,
    severity: MarkdownInlineDiagnosticSeverity
  ) {
    self.range = range
    self.severity = severity
  }
}

public enum MarkdownEditorOverlayService {
  public static func currentParagraphRange(
    in markdown: String,
    selectedRange: NSRange,
    isEnabled: Bool
  ) -> NSRange? {
    let source = markdown as NSString
    guard isEnabled, source.length > 0 else { return nil }

    let selectionLocation: Int
    if selectedRange.location == NSNotFound {
      selectionLocation = 0
    } else {
      selectionLocation = min(max(selectedRange.location, 0), source.length)
    }
    let probeLocation = min(selectionLocation, source.length - 1)
    return source.paragraphRange(
      for: NSRange(location: probeLocation, length: 0)
    )
  }

  public static func diagnosticOverlays(
    in markdown: String,
    diagnostics: [MarkdownInlineDiagnostic]
  ) -> [MarkdownEditorDiagnosticOverlay] {
    let length = (markdown as NSString).length
    return diagnostics.compactMap { diagnostic in
      guard let range = clampedNonEmptyRange(diagnostic.range, length: length) else {
        return nil
      }
      return MarkdownEditorDiagnosticOverlay(
        range: range,
        severity: diagnostic.severity
      )
    }
  }

  public static func clampedNonEmptyRange(
    _ range: NSRange,
    length: Int
  ) -> NSRange? {
    guard length > 0,
          range.location != NSNotFound,
          range.location >= 0,
          range.length > 0 else {
      return nil
    }
    let location = min(range.location, length)
    let availableLength = max(0, length - location)
    let clampedLength = min(range.length, availableLength)
    guard clampedLength > 0 else { return nil }
    return NSRange(location: location, length: clampedLength)
  }
}
