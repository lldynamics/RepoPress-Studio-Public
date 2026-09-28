import Foundation
import PublishingMarkdownCore

struct MarkdownFindMatchSnapshot: Equatable {
  var ranges: [NSRange]
  var errorMessage: String?

  static let empty = MarkdownFindMatchSnapshot(ranges: [], errorMessage: nil)

  func position(selectedRange: NSRange) -> MarkdownFindPosition {
    guard !ranges.isEmpty else {
      return MarkdownFindPosition(currentNumber: nil, total: 0)
    }
    let currentIndex =
      ranges.firstIndex { NSEqualRanges($0, selectedRange) }
      ?? ranges.firstIndex { NSIntersectionRange($0, selectedRange).length > 0 }
    return MarkdownFindPosition(
      currentNumber: currentIndex.map { $0 + 1 }, total: ranges.count
    )
  }

  func result(
    selectedRange: NSRange,
    direction: MarkdownFindDirection
  ) -> MarkdownFindResult? {
    guard !ranges.isEmpty else { return nil }
    let currentIndex = ranges.firstIndex { NSEqualRanges($0, selectedRange) }
    let target: (index: Int, didWrap: Bool)
    switch direction {
    case .next:
      if let currentIndex {
        let nextIndex = (currentIndex + 1) % ranges.count
        target = (nextIndex, nextIndex <= currentIndex)
      } else if let nextIndex = ranges.firstIndex(where: {
        $0.location >= NSMaxRange(selectedRange)
      }) {
        target = (nextIndex, false)
      } else {
        target = (0, true)
      }
    case .previous:
      if let currentIndex {
        let previousIndex = currentIndex == 0 ? ranges.count - 1 : currentIndex - 1
        target = (previousIndex, previousIndex >= currentIndex)
      } else if let previousIndex = ranges.lastIndex(where: {
        NSMaxRange($0) <= selectedRange.location
      }) {
        target = (previousIndex, false)
      } else {
        target = (ranges.count - 1, true)
      }
    }
    return MarkdownFindResult(
      range: ranges[target.index], didWrap: target.didWrap,
      currentNumber: target.index + 1, total: ranges.count
    )
  }

}
