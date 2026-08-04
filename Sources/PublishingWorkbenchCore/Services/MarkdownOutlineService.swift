import Foundation

public struct MarkdownOutlineItem: Identifiable, Hashable, Sendable {
  public var id: String { "\(headingLocation)-\(headingLength)" }
  public var level: Int
  public var title: String
  public var headingLocation: Int
  public var headingLength: Int
  public var sectionLocation: Int
  public var sectionLength: Int
  public var publicRiskSummary: PublicRiskSummary

  public init(
    level: Int,
    title: String,
    headingLocation: Int,
    headingLength: Int,
    sectionLocation: Int,
    sectionLength: Int,
    publicRiskSummary: PublicRiskSummary
  ) {
    self.level = level
    self.title = title
    self.headingLocation = headingLocation
    self.headingLength = headingLength
    self.sectionLocation = sectionLocation
    self.sectionLength = sectionLength
    self.publicRiskSummary = publicRiskSummary
  }

  public var headingRange: NSRange {
    NSRange(location: headingLocation, length: headingLength)
  }

  public var sectionRange: NSRange {
    NSRange(location: sectionLocation, length: sectionLength)
  }
}

public enum MarkdownOutlineMoveDirection: Equatable, Sendable {
  case up
  case down
}

public struct MarkdownOutlineService {
  private let publicRiskScanner: PublicRiskScanner

  public init(publicRiskScanner: PublicRiskScanner = PublicRiskScanner()) {
    self.publicRiskScanner = publicRiskScanner
  }

  public func outline(in markdown: String) -> [MarkdownOutlineItem] {
    let source = markdown as NSString
    guard source.length > 0,
          let regex = try? NSRegularExpression(pattern: #"(?m)^(#{2,3})[ \t]+(.+?)[ \t#]*$"#)
    else {
      return []
    }

    let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: source.length))
    guard !matches.isEmpty else {
      return []
    }

    let headingLevels = matches.map { match in
      source.substring(with: match.range(at: 1)).count
    }

    return matches.enumerated().map { index, match in
      let headingRange = match.range
      let level = headingLevels[index]
      let rawTitle = source.substring(with: match.range(at: 2)).trimmedForPublishing
      let nextLocation = ((index + 1)..<matches.count)
        .first(where: { headingLevels[$0] <= level })
        .map { matches[$0].range.location }
        ?? source.length
      let sectionRange = NSRange(
        location: headingRange.location,
        length: max(0, nextLocation - headingRange.location)
      )
      let sectionMarkdown = source.substring(with: sectionRange)
      let sectionDraft = ArticleDraft(
        siteProfileID: UUID(),
        title: rawTitle.isEmpty ? "未命名段落" : rawTitle,
        bodyMarkdown: sectionMarkdown
      )
      let riskSummary = PublicRiskSummary(issues: publicRiskScanner.scan(draft: sectionDraft))

      return MarkdownOutlineItem(
        level: level,
        title: rawTitle.isEmpty ? "未命名段落" : rawTitle,
        headingLocation: headingRange.location,
        headingLength: headingRange.length,
        sectionLocation: sectionRange.location,
        sectionLength: sectionRange.length,
        publicRiskSummary: riskSummary
      )
    }
  }

  public func canMoveSection(
    _ item: MarkdownOutlineItem,
    direction: MarkdownOutlineMoveDirection,
    in markdown: String
  ) -> Bool {
    let items = outline(in: markdown)
    guard let itemIndex = resolvedItemIndex(for: item, in: items) else { return false }
    return moveTargetIndex(for: itemIndex, direction: direction, in: items) != nil
  }

  public func moveSectionEdit(
    in markdown: String,
    item: MarkdownOutlineItem,
    direction: MarkdownOutlineMoveDirection
  ) -> MarkdownSmartEdit? {
    let source = markdown as NSString
    let items = outline(in: markdown)
    guard let itemIndex = resolvedItemIndex(for: item, in: items),
          let targetIndex = moveTargetIndex(for: itemIndex, direction: direction, in: items)
    else {
      return nil
    }

    let current = items[itemIndex]
    let target = items[targetIndex]
    guard valid(current.sectionRange, in: source),
          valid(target.sectionRange, in: source) else {
      return nil
    }

    let earlier = direction == .up ? target : current
    let later = direction == .up ? current : target
    guard NSMaxRange(earlier.sectionRange) == later.sectionRange.location else {
      return nil
    }

    let earlierMarkdown = source.substring(with: earlier.sectionRange)
    let laterMarkdown = source.substring(with: later.sectionRange)
    let separator = laterMarkdown.hasSuffix("\n") ? "" : "\n\n"
    let replacement = laterMarkdown + separator + earlierMarkdown
    let replacedRange = NSRange(
      location: earlier.sectionRange.location,
      length: NSMaxRange(later.sectionRange) - earlier.sectionRange.location
    )
    let movedHeadingLocation = direction == .up
      ? replacedRange.location
      : replacedRange.location
        + (laterMarkdown as NSString).length
        + (separator as NSString).length

    return MarkdownSmartEdit(
      replacedRange: replacedRange,
      replacement: replacement,
      selectedRange: NSRange(location: movedHeadingLocation, length: 0)
    )
  }

  public func duplicateSectionEdit(
    in markdown: String,
    item: MarkdownOutlineItem
  ) -> MarkdownSmartEdit? {
    let source = markdown as NSString
    let items = outline(in: markdown)
    guard let itemIndex = resolvedItemIndex(for: item, in: items) else { return nil }
    let current = items[itemIndex]
    guard valid(current.sectionRange, in: source) else { return nil }

    let sectionMarkdown = source.substring(with: current.sectionRange)
    guard !sectionMarkdown.isEmpty else { return nil }
    let insertionLocation = NSMaxRange(current.sectionRange)
    let separator = insertionLocation == source.length && !sectionMarkdown.hasSuffix("\n")
      ? "\n\n"
      : ""

    return MarkdownSmartEdit(
      replacedRange: NSRange(location: insertionLocation, length: 0),
      replacement: separator + sectionMarkdown,
      selectedRange: NSRange(
        location: insertionLocation + (separator as NSString).length,
        length: 0
      )
    )
  }

  public func deleteSectionEdit(
    in markdown: String,
    item: MarkdownOutlineItem
  ) -> MarkdownSmartEdit? {
    let source = markdown as NSString
    let items = outline(in: markdown)
    guard let itemIndex = resolvedItemIndex(for: item, in: items) else { return nil }
    let current = items[itemIndex]
    guard valid(current.sectionRange, in: source) else { return nil }

    return MarkdownSmartEdit(
      replacedRange: current.sectionRange,
      replacement: "",
      selectedRange: NSRange(
        location: min(current.sectionRange.location, source.length - current.sectionRange.length),
        length: 0
      )
    )
  }

  public func anchorLink(
    for item: MarkdownOutlineItem,
    in markdown: String
  ) -> String? {
    let items = outline(in: markdown)
    guard let itemIndex = resolvedItemIndex(for: item, in: items) else { return nil }
    var usedAnchors = Set<String>()
    for index in 0...itemIndex {
      let baseAnchor = anchorSlug(for: items[index].title)
      var resolvedAnchor = baseAnchor
      var suffix = 0
      while usedAnchors.contains(resolvedAnchor) {
        suffix += 1
        resolvedAnchor = "\(baseAnchor)-\(suffix)"
      }
      usedAnchors.insert(resolvedAnchor)
      if index == itemIndex {
        return "#\(resolvedAnchor)"
      }
    }
    return nil
  }

  private func resolvedItemIndex(
    for item: MarkdownOutlineItem,
    in items: [MarkdownOutlineItem]
  ) -> Int? {
    items.firstIndex {
      $0.headingLocation == item.headingLocation
        && $0.headingLength == item.headingLength
        && $0.level == item.level
        && $0.title == item.title
    }
  }

  private func moveTargetIndex(
    for itemIndex: Int,
    direction: MarkdownOutlineMoveDirection,
    in items: [MarkdownOutlineItem]
  ) -> Int? {
    guard items.indices.contains(itemIndex) else { return nil }
    let item = items[itemIndex]
    let lowerBound = stride(from: itemIndex - 1, through: 0, by: -1)
      .first(where: { items[$0].level < item.level })
      .map { $0 + 1 }
      ?? 0
    let upperBound = ((itemIndex + 1)..<items.count)
      .first(where: { items[$0].level < item.level })
      ?? items.count
    let siblingIndices = (lowerBound..<upperBound).filter { items[$0].level == item.level }
    guard let siblingPosition = siblingIndices.firstIndex(of: itemIndex) else { return nil }

    switch direction {
    case .up:
      guard siblingPosition > siblingIndices.startIndex else { return nil }
      return siblingIndices[siblingIndices.index(before: siblingPosition)]
    case .down:
      let nextPosition = siblingIndices.index(after: siblingPosition)
      guard nextPosition < siblingIndices.endIndex else { return nil }
      return siblingIndices[nextPosition]
    }
  }

  private func valid(_ range: NSRange, in source: NSString) -> Bool {
    range.location >= 0
      && range.length >= 0
      && NSMaxRange(range) <= source.length
  }

  private func anchorSlug(for title: String) -> String {
    let plainTitle = title
      .replacingOccurrences(
        of: #"!?\[([^\]]+)\]\([^)]+\)"#,
        with: "$1",
        options: .regularExpression
      )
      .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: "`", with: "")
    let anchor = plainTitle
      .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
      .lowercased()
      .replacingOccurrences(
        of: #"[^\p{L}\p{N}\p{M}\s_-]"#,
        with: "",
        options: .regularExpression
      )
      .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
      .replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return anchor.isEmpty ? "section" : anchor
  }
}
