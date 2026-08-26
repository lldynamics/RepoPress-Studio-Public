import Foundation

public struct MarkdownFindOptions: Equatable, Sendable {
  public var caseSensitive: Bool
  public var wholeWord: Bool
  public var usesRegularExpression: Bool

  public init(
    caseSensitive: Bool = false,
    wholeWord: Bool = false,
    usesRegularExpression: Bool = false
  ) {
    self.caseSensitive = caseSensitive
    self.wholeWord = wholeWord
    self.usesRegularExpression = usesRegularExpression
  }
}

public enum MarkdownFindDirection: Equatable, Sendable {
  case next
  case previous
}

public enum MarkdownFindReplaceError: LocalizedError, Equatable, Sendable {
  case invalidRegularExpression(String)

  public var errorDescription: String? {
    switch self {
    case .invalidRegularExpression:
      return "正则表达式无效。"
    }
  }
}

public struct MarkdownFindPosition: Equatable, Sendable {
  public var currentNumber: Int?
  public var total: Int

  public init(currentNumber: Int?, total: Int) {
    self.currentNumber = currentNumber
    self.total = total
  }
}

public struct MarkdownFindResult: Equatable, Sendable {
  public var range: NSRange
  public var didWrap: Bool
  public var currentNumber: Int
  public var total: Int

  public init(
    range: NSRange,
    didWrap: Bool,
    currentNumber: Int = 1,
    total: Int = 1
  ) {
    self.range = range
    self.didWrap = didWrap
    self.currentNumber = currentNumber
    self.total = total
  }
}

public struct MarkdownFindReplaceMutation: Equatable, Sendable {
  public var text: String
  public var selectedRange: NSRange
  public var replacementCount: Int
  public var edit: MarkdownSmartEdit?

  public init(
    text: String,
    selectedRange: NSRange,
    replacementCount: Int,
    edit: MarkdownSmartEdit? = nil
  ) {
    self.text = text
    self.selectedRange = selectedRange
    self.replacementCount = replacementCount
    self.edit = edit
  }
}

public struct MarkdownFindReplaceService: Sendable {
  public init() {}

  public func matches(
    in text: String,
    query: String,
    options: MarkdownFindOptions = MarkdownFindOptions(),
    shouldCancel: @Sendable () -> Bool = { false }
  ) throws -> [NSRange] {
    try matchContext(
      in: text,
      query: query,
      options: options,
      shouldCancel: shouldCancel
    ).matches.map(\.range)
  }

  public func position(
    in text: String,
    query: String,
    selectedRange: NSRange,
    options: MarkdownFindOptions = MarkdownFindOptions()
  ) throws -> MarkdownFindPosition {
    let sourceLength = (text as NSString).length
    let selection = clamped(selectedRange, length: sourceLength)
    let ranges = try matches(in: text, query: query, options: options)
    let currentIndex = ranges.firstIndex { NSEqualRanges($0, selection) }
    return MarkdownFindPosition(
      currentNumber: currentIndex.map { $0 + 1 },
      total: ranges.count
    )
  }

  public func find(
    in text: String,
    query: String,
    selectedRange: NSRange,
    direction: MarkdownFindDirection,
    options: MarkdownFindOptions = MarkdownFindOptions()
  ) throws -> MarkdownFindResult? {
    let sourceLength = (text as NSString).length
    let selection = clamped(selectedRange, length: sourceLength)
    let ranges = try matches(in: text, query: query, options: options)
    guard !ranges.isEmpty else { return nil }

    let currentIndex = ranges.firstIndex { NSEqualRanges($0, selection) }
    let target: (index: Int, didWrap: Bool)

    switch direction {
    case .next:
      if let currentIndex {
        let nextIndex = (currentIndex + 1) % ranges.count
        target = (nextIndex, nextIndex <= currentIndex)
      } else if let nextIndex = ranges.firstIndex(where: { $0.location >= NSMaxRange(selection) }) {
        target = (nextIndex, false)
      } else {
        target = (0, true)
      }

    case .previous:
      if let currentIndex {
        let previousIndex = currentIndex == 0 ? ranges.count - 1 : currentIndex - 1
        target = (previousIndex, previousIndex >= currentIndex)
      } else if let previousIndex = ranges.lastIndex(where: { NSMaxRange($0) <= selection.location }) {
        target = (previousIndex, false)
      } else {
        target = (ranges.count - 1, true)
      }
    }

    return MarkdownFindResult(
      range: ranges[target.index],
      didWrap: target.didWrap,
      currentNumber: target.index + 1,
      total: ranges.count
    )
  }

  public func findNext(
    in text: String,
    query: String,
    selectedRange: NSRange,
    caseSensitive: Bool = false
  ) -> MarkdownFindResult? {
    try? find(
      in: text,
      query: query,
      selectedRange: selectedRange,
      direction: .next,
      options: MarkdownFindOptions(caseSensitive: caseSensitive)
    )
  }

  public func replaceCurrentOrNext(
    in text: String,
    query: String,
    replacement: String,
    selectedRange: NSRange,
    options: MarkdownFindOptions
  ) throws -> MarkdownFindReplaceMutation {
    let source = text as NSString
    let selection = clamped(selectedRange, length: source.length)
    let context = try matchContext(in: text, query: query, options: options)
    guard !context.matches.isEmpty else {
      return unchangedMutation(text: text, selectedRange: selection)
    }

    let selectedMatchIndex = context.matches.firstIndex { NSEqualRanges($0.range, selection) }
    let targetIndex: Int
    if let selectedMatchIndex {
      targetIndex = selectedMatchIndex
    } else if let next = context.matches.firstIndex(where: { $0.range.location >= NSMaxRange(selection) }) {
      targetIndex = next
    } else {
      targetIndex = 0
    }

    let match = context.matches[targetIndex]
    let replacementValue = replacementString(
      for: match,
      in: text,
      template: replacement,
      options: options,
      regularExpression: context.regularExpression
    )
    let updatedText = source.replacingCharacters(in: match.range, with: replacementValue)
    let updatedSelection = NSRange(
      location: match.range.location,
      length: (replacementValue as NSString).length
    )
    let edit = MarkdownSmartEdit(
      replacedRange: match.range,
      replacement: replacementValue,
      selectedRange: updatedSelection
    )
    return MarkdownFindReplaceMutation(
      text: updatedText,
      selectedRange: updatedSelection,
      replacementCount: 1,
      edit: edit
    )
  }

  public func replaceCurrentOrNext(
    in text: String,
    query: String,
    replacement: String,
    selectedRange: NSRange,
    caseSensitive: Bool = false
  ) -> MarkdownFindReplaceMutation {
    (try? replaceCurrentOrNext(
      in: text,
      query: query,
      replacement: replacement,
      selectedRange: selectedRange,
      options: MarkdownFindOptions(caseSensitive: caseSensitive)
    )) ?? unchangedMutation(text: text, selectedRange: clamped(selectedRange, length: (text as NSString).length))
  }

  public func replaceAll(
    in text: String,
    query: String,
    replacement: String,
    options: MarkdownFindOptions
  ) throws -> MarkdownFindReplaceMutation {
    let source = text as NSString
    let context = try matchContext(in: text, query: query, options: options)
    guard !context.matches.isEmpty else {
      return unchangedMutation(text: text, selectedRange: NSRange(location: 0, length: 0))
    }

    let mutableText = NSMutableString(string: text)
    let replacementTemplate = options.usesRegularExpression
      ? replacement
      : NSRegularExpression.escapedTemplate(for: replacement)
    let replacementCount = context.regularExpression.replaceMatches(
      in: mutableText,
      options: [],
      range: NSRange(location: 0, length: source.length),
      withTemplate: replacementTemplate
    )
    let updatedText = mutableText as String
    let updatedSelection = NSRange(location: 0, length: 0)
    return MarkdownFindReplaceMutation(
      text: updatedText,
      selectedRange: updatedSelection,
      replacementCount: replacementCount,
      edit: MarkdownSmartEdit(
        replacedRange: NSRange(location: 0, length: source.length),
        replacement: updatedText,
        selectedRange: updatedSelection
      )
    )
  }

  public func replaceAll(
    in text: String,
    query: String,
    replacement: String,
    caseSensitive: Bool = false
  ) -> MarkdownFindReplaceMutation {
    (try? replaceAll(
      in: text,
      query: query,
      replacement: replacement,
      options: MarkdownFindOptions(caseSensitive: caseSensitive)
    )) ?? unchangedMutation(text: text, selectedRange: NSRange(location: 0, length: 0))
  }

  private func matchContext(
    in text: String,
    query: String,
    options: MarkdownFindOptions,
    shouldCancel: @Sendable () -> Bool = { false }
  ) throws -> MatchContext {
    guard !shouldCancel() else { throw CancellationError() }
    guard (query as NSString).length > 0 else {
      return MatchContext(regularExpression: try emptyRegularExpression(), matches: [])
    }

    let escapedQuery = options.usesRegularExpression
      ? query
      : NSRegularExpression.escapedPattern(for: query)
    let pattern = options.wholeWord
      ? #"(?<![\p{L}\p{N}_])(?:\#(escapedQuery))(?![\p{L}\p{N}_])"#
      : escapedQuery
    let regexOptions: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]

    do {
      let regularExpression = try NSRegularExpression(pattern: pattern, options: regexOptions)
      let fullRange = NSRange(location: 0, length: (text as NSString).length)
      var matches: [NSTextCheckingResult] = []
      var wasCancelled = false
      regularExpression.enumerateMatches(in: text, options: [], range: fullRange) {
        match, _, stop in
        if shouldCancel() {
          wasCancelled = true
          stop.pointee = true
          return
        }
        if let match {
          matches.append(match)
        }
      }
      guard !wasCancelled, !shouldCancel() else { throw CancellationError() }
      return MatchContext(
        regularExpression: regularExpression,
        matches: matches
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw MarkdownFindReplaceError.invalidRegularExpression(error.localizedDescription)
    }
  }

  private func replacementString(
    for match: NSTextCheckingResult,
    in text: String,
    template: String,
    options: MarkdownFindOptions,
    regularExpression: NSRegularExpression
  ) -> String {
    guard options.usesRegularExpression else { return template }
    return regularExpression.replacementString(
      for: match,
      in: text,
      offset: 0,
      template: template
    )
  }

  private func unchangedMutation(text: String, selectedRange: NSRange) -> MarkdownFindReplaceMutation {
    MarkdownFindReplaceMutation(
      text: text,
      selectedRange: selectedRange,
      replacementCount: 0
    )
  }

  private func clamped(_ range: NSRange, length: Int) -> NSRange {
    let location = min(max(range.location, 0), length)
    let maxLength = max(0, length - location)
    return NSRange(location: location, length: min(range.length, maxLength))
  }

  private func emptyRegularExpression() throws -> NSRegularExpression {
    try NSRegularExpression(pattern: #"(?!)"#)
  }

  private struct MatchContext {
    var regularExpression: NSRegularExpression
    var matches: [NSTextCheckingResult]
  }
}
