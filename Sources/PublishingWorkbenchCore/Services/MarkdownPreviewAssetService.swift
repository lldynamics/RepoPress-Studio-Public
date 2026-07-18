import Foundation

public struct MarkdownPreviewAssetHTMLReplacement: Equatable, Sendable {
  public var token: String
  public var html: String

  public init(token: String, html: String) {
    self.token = token
    self.html = html
  }
}

public struct MarkdownPreviewPreparedMarkdown: Equatable, Sendable {
  public var markdown: String
  public var replacements: [MarkdownPreviewAssetHTMLReplacement]

  public init(
    markdown: String,
    replacements: [MarkdownPreviewAssetHTMLReplacement]
  ) {
    self.markdown = markdown
    self.replacements = replacements
  }
}

public enum MarkdownPreviewAssetService {
  public static let URLScheme = "publisher-asset"

  public static func prepare(
    markdown: String,
    attachments: [DraftAttachment],
    previewURLByAttachmentID: [UUID: String]
  ) -> MarkdownPreviewPreparedMarkdown {
    let assets = attachments.compactMap { attachment -> Asset? in
      guard let previewURL = previewURLByAttachmentID[attachment.id] else { return nil }
      return Asset(attachment: attachment, previewURL: previewURL)
    }
    guard !assets.isEmpty else {
      return MarkdownPreviewPreparedMarkdown(markdown: markdown, replacements: [])
    }

    let assetByReference = referenceLookup(for: assets)
    let protectedRanges = protectedMarkdownRanges(in: markdown)
    var candidates: [Candidate] = []

    candidates.append(contentsOf: videoCandidates(
      in: markdown,
      assetByReference: assetByReference,
      protectedRanges: protectedRanges
    ))
    candidates.append(contentsOf: rawImageCandidates(
      in: markdown,
      assetByReference: assetByReference,
      protectedRanges: protectedRanges,
      excluding: candidates.map(\.range)
    ))
    candidates.append(contentsOf: markdownImageCandidates(
      in: markdown,
      assetByReference: assetByReference,
      protectedRanges: protectedRanges,
      excluding: candidates.map(\.range)
    ))

    var preparedMarkdown = markdown
    var replacements: [MarkdownPreviewAssetHTMLReplacement] = []
    for candidate in candidates.sorted(by: { $0.range.location > $1.range.location }) {
      let token = placeholderToken(for: candidate)
      let replacement = MarkdownPreviewAssetHTMLReplacement(
        token: token,
        html: htmlFragment(for: candidate)
      )
      guard let range = Range(candidate.range, in: preparedMarkdown) else { continue }
      preparedMarkdown.replaceSubrange(range, with: token)
      replacements.append(replacement)
    }

    return MarkdownPreviewPreparedMarkdown(
      markdown: preparedMarkdown,
      replacements: replacements
    )
  }
}

private extension MarkdownPreviewAssetService {
  struct Asset {
    let attachment: DraftAttachment
    let previewURL: String

    var references: [String] {
      [attachment.relativePublishPath, attachment.repositoryPath]
        .flatMap(referenceVariants)
    }
  }

  enum CandidateKind {
    case image
    case video
  }

  struct Candidate {
    let range: NSRange
    let asset: Asset
    let kind: CandidateKind
    let accessibleText: String?
  }

  static let videoExpression = try! NSRegularExpression(
    pattern: #"<video\b[^>]*>.*?</video\s*>"#,
    options: [.caseInsensitive, .dotMatchesLineSeparators]
  )
  static let rawImageExpression = try! NSRegularExpression(
    pattern: #"<img\b[^>]*>"#,
    options: [.caseInsensitive]
  )
  static let markdownImageExpression = try! NSRegularExpression(
    pattern: #"!\[((?:\\.|[^\]])*)\]\((?:<([^>]+)>|(.+?))(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?\)"#
  )
  static let sourceAttributeExpression = try! NSRegularExpression(
    pattern: #"\b(?:src|href)\s*=\s*[\"']([^\"']+)[\"']"#,
    options: [.caseInsensitive]
  )
  static let altAttributeExpression = try! NSRegularExpression(
    pattern: #"\balt\s*=\s*[\"']([^\"']*)[\"']"#,
    options: [.caseInsensitive]
  )
  static let fencedCodeExpression = try! NSRegularExpression(
    pattern: #"(?ms)^[ \t]{0,3}(`{3,}|~{3,})[^\n]*\n.*?^[ \t]{0,3}\1[ \t]*(?:\n|$)"#
  )
  static let inlineCodeExpression = try! NSRegularExpression(
    pattern: #"(?m)(`+)[^`\n]*\1"#
  )

  static func referenceLookup(for assets: [Asset]) -> [String: Asset] {
    var result: [String: Asset] = [:]
    for asset in assets {
      for reference in asset.references where result[reference] == nil {
        result[reference] = asset
      }
    }
    return result
  }

  static func referenceVariants(_ value: String) -> [String] {
    let decoded = decodeHTMLAttribute(value)
      .removingPercentEncoding
      ?? decodeHTMLAttribute(value)
    var normalized = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasPrefix("<"), normalized.hasSuffix(">"), normalized.count > 2 {
      normalized.removeFirst()
      normalized.removeLast()
    }
    while normalized.hasPrefix("./") {
      normalized.removeFirst(2)
    }
    guard !normalized.isEmpty else { return [] }

    var variants = [normalized]
    if normalized.hasPrefix("/") {
      variants.append(String(normalized.dropFirst()))
    } else {
      variants.append("/" + normalized)
    }
    return Array(Set(variants))
  }

  static func protectedMarkdownRanges(in markdown: String) -> [NSRange] {
    let fullRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    return fencedCodeExpression.matches(in: markdown, range: fullRange).map(\.range)
      + inlineCodeExpression.matches(in: markdown, range: fullRange).map(\.range)
  }

  static func videoCandidates(
    in markdown: String,
    assetByReference: [String: Asset],
    protectedRanges: [NSRange]
  ) -> [Candidate] {
    let fullRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    return videoExpression.matches(in: markdown, range: fullRange).compactMap { match in
      guard !intersects(match.range, any: protectedRanges),
            let source = firstAttributeValue(
              in: markdown,
              matchRange: match.range,
              expression: sourceAttributeExpression
            ),
            let asset = asset(for: source, in: assetByReference),
            asset.attachment.mediaKind == .video else {
        return nil
      }
      return Candidate(
        range: match.range,
        asset: asset,
        kind: .video,
        accessibleText: nil
      )
    }
  }

  static func rawImageCandidates(
    in markdown: String,
    assetByReference: [String: Asset],
    protectedRanges: [NSRange],
    excluding excludedRanges: [NSRange]
  ) -> [Candidate] {
    let fullRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    return rawImageExpression.matches(in: markdown, range: fullRange).compactMap { match in
      guard !intersects(match.range, any: protectedRanges + excludedRanges),
            let source = firstAttributeValue(
              in: markdown,
              matchRange: match.range,
              expression: sourceAttributeExpression
            ),
            let asset = asset(for: source, in: assetByReference),
            asset.attachment.mediaKind == .image else {
        return nil
      }
      return Candidate(
        range: match.range,
        asset: asset,
        kind: .image,
        accessibleText: firstAttributeValue(
          in: markdown,
          matchRange: match.range,
          expression: altAttributeExpression
        )
      )
    }
  }

  static func markdownImageCandidates(
    in markdown: String,
    assetByReference: [String: Asset],
    protectedRanges: [NSRange],
    excluding excludedRanges: [NSRange]
  ) -> [Candidate] {
    let fullRange = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    return markdownImageExpression.matches(in: markdown, range: fullRange).compactMap { match in
      guard !intersects(match.range, any: protectedRanges + excludedRanges),
            match.numberOfRanges >= 4,
            let sourceRange = [match.range(at: 2), match.range(at: 3)]
              .first(where: { $0.location != NSNotFound })
              .flatMap({ Range($0, in: markdown) }),
            let asset = asset(for: String(markdown[sourceRange]), in: assetByReference),
            asset.attachment.mediaKind == .image else {
        return nil
      }
      let altText: String?
      if let range = Range(match.range(at: 1), in: markdown) {
        altText = String(markdown[range])
      } else {
        altText = nil
      }
      return Candidate(
        range: match.range,
        asset: asset,
        kind: .image,
        accessibleText: altText
      )
    }
  }

  static func firstAttributeValue(
    in markdown: String,
    matchRange: NSRange,
    expression: NSRegularExpression
  ) -> String? {
    guard let match = expression.firstMatch(in: markdown, range: matchRange),
          match.numberOfRanges >= 2,
          let range = Range(match.range(at: 1), in: markdown) else {
      return nil
    }
    return decodeHTMLAttribute(String(markdown[range]))
  }

  static func asset(
    for reference: String,
    in assetByReference: [String: Asset]
  ) -> Asset? {
    for variant in referenceVariants(reference) {
      if let asset = assetByReference[variant] {
        return asset
      }
    }
    return nil
  }

  static func intersects(_ range: NSRange, any ranges: [NSRange]) -> Bool {
    ranges.contains { NSIntersectionRange(range, $0).length > 0 }
  }

  static func placeholderToken(for candidate: Candidate) -> String {
    let identifier = candidate.asset.attachment.id.uuidString.replacingOccurrences(of: "-", with: "")
    return "PUBLISHER_ASSET_\(identifier)_\(candidate.range.location)"
  }

  static func htmlFragment(for candidate: Candidate) -> String {
    let attachment = candidate.asset.attachment
    let caption = attachment.caption
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let captionHTML = caption.isEmpty
      ? ""
      : #"<span class="local-asset-caption">\#(escapeHTML(caption))</span>"#
    let previewURL = escapeHTMLAttribute(candidate.asset.previewURL)

    switch candidate.kind {
    case .image:
      let accessibleText = candidate.accessibleText?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let altText = accessibleText?.isEmpty == false
        ? accessibleText!
        : attachment.altText.nilIfEmpty ?? attachment.originalFilename
      return #"<span class="local-asset local-image" role="group"><img src="\#(previewURL)" alt="\#(escapeHTMLAttribute(altText))" loading="lazy" decoding="async">\#(captionHTML)</span>"#
    case .video:
      let title = attachment.altText.nilIfEmpty
        ?? attachment.caption.nilIfEmpty
        ?? VideoFileSupport.accessibleTitle(
          for: URL(fileURLWithPath: attachment.originalFilename)
        )
      let mimeType = VideoFileSupport.mimeType(
        for: attachment.sourceFilePath ?? attachment.relativePublishPath
      )
      return #"<span class="local-asset local-video" role="group"><video controls preload="metadata" playsinline aria-label="\#(escapeHTMLAttribute(title))"><source src="\#(previewURL)" type="\#(escapeHTMLAttribute(mimeType))">您的浏览器不支持视频播放。</video>\#(captionHTML)</span>"#
    }
  }

  static func decodeHTMLAttribute(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&amp;", with: "&")
  }

  static func escapeHTML(_ value: String) -> String {
    escapeHTMLAttribute(value)
  }

  static func escapeHTMLAttribute(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}
