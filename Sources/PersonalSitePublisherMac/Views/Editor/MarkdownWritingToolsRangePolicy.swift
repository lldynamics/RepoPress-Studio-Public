import Foundation
import PublishingMarkdownCore

/// Protects source-only Markdown regions from system rewrites. All coordinates
/// are UTF-16, matching NSTextView's Writing Tools delegate contract.
enum MarkdownWritingToolsRangePolicy {
  static func ignoredRanges(
    in document: String,
    bodyUTF16Offset: Int,
    enclosingRange: NSRange
  ) -> [NSRange] {
    let length = (document as NSString).length
    guard enclosingRange.location != NSNotFound,
      enclosingRange.location >= 0,
      enclosingRange.length >= 0,
      enclosingRange.location <= length,
      enclosingRange.length <= length - enclosingRange.location
    else { return [] }

    let protectedFrontMatterLength = min(max(bodyUTF16Offset, 0), length)
    var ranges: [NSRange] = []
    if protectedFrontMatterLength > 0 {
      ranges.append(NSRange(location: 0, length: protectedFrontMatterLength))
    }
    ranges.append(contentsOf: MarkdownCodeRangeScanner.scan(document).allRanges)

    let enclosingEnd = NSMaxRange(enclosingRange)
    let clipped = ranges.compactMap { range in
      let start = max(range.location, enclosingRange.location)
      let end = min(NSMaxRange(range), enclosingEnd)
      return end > start ? NSRange(location: start, length: end - start) : nil
    }
    var merged: [NSRange] = []
    for range in clipped.sorted(by: { $0.location < $1.location }) {
      if let previous = merged.last, range.location <= NSMaxRange(previous) {
        merged[merged.count - 1].length =
          max(NSMaxRange(previous), NSMaxRange(range)) - previous.location
      } else {
        merged.append(range)
      }
    }
    return merged
  }
}
