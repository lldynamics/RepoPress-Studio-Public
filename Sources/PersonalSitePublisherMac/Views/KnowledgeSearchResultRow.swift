import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeSearchResultRow: View {
  let result: KnowledgeSearchResult
  let query: String

  private var hit: KnowledgeSearchHitPresentation {
    KnowledgeSearchPresentationService().presentation(for: result, query: query)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 7) {
        Image(systemName: result.document.kind.systemImage)
          .foregroundStyle(.secondary)
          .frame(width: 14)
          .accessibilityHidden(true)
        KnowledgeHighlightedText(text: result.document.title, terms: hit.highlightTerms)
          .font(.callout.weight(.medium))
          .workbenchTruncatedIdentity(result.document.title)
        Spacer(minLength: 0)
      }

      if let location = hit.locationLabel {
        Label(location, systemImage: "mappin.and.ellipse")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(location)
      }

      KnowledgeHighlightedText(text: hit.snippet, terms: hit.highlightTerms)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)

      HStack(spacing: 5) {
        ForEach(hit.reasons, id: \.self) { reason in
          Text(reason.shortDisplayName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(reason.foregroundStyle)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(reason.backgroundStyle, in: Capsule())
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(hit.reasons.map(\.accessibilityDisplayName).joined(separator: "、"))
    }
    .padding(.vertical, 5)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilitySummary)
    .accessibilityHint("选择后跳转到正文中的准确段落")
  }

  private var accessibilitySummary: String {
    let reasons = hit.reasons.map(\.accessibilityDisplayName).joined(separator: "、")
    let location = hit.locationLabel.map { "，位置：\($0)" } ?? ""
    return "\(result.document.title)，\(reasons)\(location)。上下文：\(hit.snippet)"
  }
}

struct KnowledgeHighlightedText: View {
  let text: String
  let terms: [String]

  var body: some View {
    Self.highlightedText(text, terms: terms)
  }

  static func highlightedText(
    _ source: String,
    terms: [String]
  ) -> Text {
    var matches: [Range<String.Index>] = []
    for term in terms where !term.isEmpty {
      var remaining = source.startIndex..<source.endIndex
      while let match = source.range(
        of: term,
        options: [.caseInsensitive, .diacriticInsensitive],
        range: remaining,
        locale: .current
      ) {
        matches.append(match)
        guard match.upperBound < source.endIndex else { break }
        remaining = match.upperBound..<source.endIndex
      }
    }
    matches.sort { lhs, rhs in
      if lhs.lowerBound != rhs.lowerBound { return lhs.lowerBound < rhs.lowerBound }
      return source.distance(from: lhs.lowerBound, to: lhs.upperBound)
        > source.distance(from: rhs.lowerBound, to: rhs.upperBound)
    }

    var output = Text("")
    var cursor = source.startIndex
    for match in matches where match.lowerBound >= cursor {
      if cursor < match.lowerBound {
        output = output + Text(verbatim: String(source[cursor..<match.lowerBound]))
      }
      output = output + Text(verbatim: String(source[match]))
        .bold()
        .foregroundColor(.accentColor)
        .underline(true, color: .yellow)
      cursor = match.upperBound
    }
    if cursor < source.endIndex {
      output = output + Text(verbatim: String(source[cursor...]))
    }
    return output
  }
}

extension KnowledgeRetrievalSignal {
  var shortDisplayName: String {
    switch self {
    case .title: "标题"
    case .fullText: "全文"
    case .semantic: "语义"
    }
  }

  var accessibilityDisplayName: String {
    "\(shortDisplayName)命中"
  }

  var foregroundStyle: Color {
    switch self {
    case .title: .blue
    case .fullText: .green
    case .semantic: .purple
    }
  }

  var backgroundStyle: Color {
    foregroundStyle.opacity(0.12)
  }
}
