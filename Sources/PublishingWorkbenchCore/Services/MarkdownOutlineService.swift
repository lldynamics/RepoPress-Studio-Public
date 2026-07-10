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

    return matches.enumerated().map { index, match in
      let headingRange = match.range
      let level = source.substring(with: match.range(at: 1)).count
      let rawTitle = source.substring(with: match.range(at: 2)).trimmedForPublishing
      let nextLocation = index + 1 < matches.count ? matches[index + 1].range.location : source.length
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
}
