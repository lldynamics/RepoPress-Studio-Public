import Foundation

public struct MarkdownFindResult: Equatable {
  public var range: NSRange
  public var didWrap: Bool

  public init(range: NSRange, didWrap: Bool) {
    self.range = range
    self.didWrap = didWrap
  }
}

public struct MarkdownFindReplaceMutation: Equatable {
  public var text: String
  public var selectedRange: NSRange
  public var replacementCount: Int

  public init(text: String, selectedRange: NSRange, replacementCount: Int) {
    self.text = text
    self.selectedRange = selectedRange
    self.replacementCount = replacementCount
  }
}

public struct MarkdownFindReplaceService {
  public init() {}

  public func findNext(
    in text: String,
    query: String,
    selectedRange: NSRange,
    caseSensitive: Bool = false
  ) -> MarkdownFindResult? {
    let source = text as NSString
    let queryLength = (query as NSString).length
    guard source.length > 0, queryLength > 0 else {
      return nil
    }

    let clampedRange = clamped(selectedRange, length: source.length)
    let start = min(clampedRange.location + clampedRange.length, source.length)
    if let range = firstRange(
      in: source,
      query: query,
      searchRange: NSRange(location: start, length: source.length - start),
      caseSensitive: caseSensitive
    ) {
      return MarkdownFindResult(range: range, didWrap: false)
    }

    guard start > 0 else {
      return nil
    }

    if let range = firstRange(
      in: source,
      query: query,
      searchRange: NSRange(location: 0, length: start),
      caseSensitive: caseSensitive
    ) {
      return MarkdownFindResult(range: range, didWrap: true)
    }

    return nil
  }

  public func replaceCurrentOrNext(
    in text: String,
    query: String,
    replacement: String,
    selectedRange: NSRange,
    caseSensitive: Bool = false
  ) -> MarkdownFindReplaceMutation {
    let source = text as NSString
    let clampedRange = clamped(selectedRange, length: source.length)
    guard (query as NSString).length > 0 else {
      return MarkdownFindReplaceMutation(text: text, selectedRange: clampedRange, replacementCount: 0)
    }

    let replacementRange: NSRange?
    if range(clampedRange, in: source, matches: query, caseSensitive: caseSensitive) {
      replacementRange = clampedRange
    } else {
      replacementRange = findNext(
        in: text,
        query: query,
        selectedRange: clampedRange,
        caseSensitive: caseSensitive
      )?.range
    }

    guard let replacementRange else {
      return MarkdownFindReplaceMutation(text: text, selectedRange: clampedRange, replacementCount: 0)
    }

    let updatedText = source.replacingCharacters(in: replacementRange, with: replacement)
    let updatedSelection = NSRange(location: replacementRange.location, length: (replacement as NSString).length)
    return MarkdownFindReplaceMutation(text: updatedText, selectedRange: updatedSelection, replacementCount: 1)
  }

  public func replaceAll(
    in text: String,
    query: String,
    replacement: String,
    caseSensitive: Bool = false
  ) -> MarkdownFindReplaceMutation {
    let queryLength = (query as NSString).length
    guard queryLength > 0 else {
      return MarkdownFindReplaceMutation(text: text, selectedRange: NSRange(location: 0, length: 0), replacementCount: 0)
    }

    let source = NSMutableString(string: text)
    var replacementCount = 0
    var searchLocation = 0
    let replacementLength = (replacement as NSString).length

    while searchLocation <= source.length {
      let searchRange = NSRange(location: searchLocation, length: source.length - searchLocation)
      let foundRange = source.range(of: query, options: options(caseSensitive: caseSensitive), range: searchRange)
      guard foundRange.location != NSNotFound else {
        break
      }

      source.replaceCharacters(in: foundRange, with: replacement)
      replacementCount += 1
      searchLocation = foundRange.location + replacementLength

      if queryLength == 0 {
        break
      }
    }

    return MarkdownFindReplaceMutation(
      text: source as String,
      selectedRange: NSRange(location: min(searchLocation, source.length), length: 0),
      replacementCount: replacementCount
    )
  }

  private func firstRange(
    in source: NSString,
    query: String,
    searchRange: NSRange,
    caseSensitive: Bool
  ) -> NSRange? {
    guard searchRange.length > 0 else {
      return nil
    }

    let range = source.range(of: query, options: options(caseSensitive: caseSensitive), range: searchRange)
    return range.location == NSNotFound ? nil : range
  }

  private func range(_ range: NSRange, in source: NSString, matches query: String, caseSensitive: Bool) -> Bool {
    guard range.length > 0, range.location + range.length <= source.length else {
      return false
    }

    return source.compare(query, options: options(caseSensitive: caseSensitive), range: range) == .orderedSame
  }

  private func clamped(_ range: NSRange, length: Int) -> NSRange {
    let location = min(max(range.location, 0), length)
    let maxLength = max(0, length - location)
    return NSRange(location: location, length: min(range.length, maxLength))
  }

  private func options(caseSensitive: Bool) -> NSString.CompareOptions {
    caseSensitive ? [] : [.caseInsensitive]
  }
}
