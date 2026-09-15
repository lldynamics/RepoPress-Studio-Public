import Foundation

public enum MarkdownSyntaxHighlightAttributeApplier {
  @discardableResult
  public static func apply(
    _ snapshot: MarkdownSyntaxHighlightSnapshot,
    to textStorage: NSMutableAttributedString,
    defaultAttributes: [NSAttributedString.Key: Any],
    styleAttributes: [MarkdownSyntaxHighlightStyle: [NSAttributedString.Key: Any]]
  ) -> Int {
    apply(
      snapshot,
      to: textStorage,
      within: snapshot.range,
      defaultAttributes: defaultAttributes,
      styleAttributes: styleAttributes
    )
  }

  @discardableResult
  public static func apply(
    _ snapshot: MarkdownSyntaxHighlightSnapshot,
    to textStorage: NSMutableAttributedString,
    within applicationRange: NSRange,
    defaultAttributes: [NSAttributedString.Key: Any],
    styleAttributes: [MarkdownSyntaxHighlightStyle: [NSAttributedString.Key: Any]]
  ) -> Int {
    guard isValid(snapshot.range, length: textStorage.length) else { return 0 }
    guard isValid(
      applicationRange,
      within: snapshot.range,
      storageLength: textStorage.length
    ) else {
      return 0
    }

    textStorage.setAttributes(defaultAttributes, range: applicationRange)
    var appliedRunCount = 0
    for run in snapshot.runs {
      guard let attributes = styleAttributes[run.style],
            isValid(run.range, within: snapshot.range, storageLength: textStorage.length) else {
        continue
      }
      let intersection = NSIntersectionRange(run.range, applicationRange)
      guard intersection.length > 0 else { continue }
      textStorage.addAttributes(attributes, range: intersection)
      appliedRunCount += 1
    }
    return appliedRunCount
  }

  private static func isValid(_ range: NSRange, length: Int) -> Bool {
    range.location != NSNotFound
      && range.location >= 0
      && range.length >= 0
      && range.location <= length
      && range.length <= length - range.location
  }

  private static func isValid(
    _ range: NSRange,
    within enclosingRange: NSRange,
    storageLength: Int
  ) -> Bool {
    isValid(range, length: storageLength)
      && range.location >= enclosingRange.location
      && range.length <= NSMaxRange(enclosingRange) - range.location
  }
}
