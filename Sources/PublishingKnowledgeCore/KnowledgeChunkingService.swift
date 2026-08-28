import CryptoKit
import Foundation
import PublishingCoreSupport

public struct KnowledgeChunkingService: Sendable {
  private static let tokenizer = LocalBPETokenizer(encoding: .o200kBase)

  public var maximumChunkCharacters: Int
  public var overlapCharacters: Int

  public init(
    maximumChunkCharacters: Int = 1_400,
    overlapCharacters: Int = 160
  ) {
    self.maximumChunkCharacters = max(320, maximumChunkCharacters)
    self.overlapCharacters = min(max(0, overlapCharacters), self.maximumChunkCharacters / 3)
  }

  public func chunks(
    documentID: UUID,
    revisionID: UUID,
    sections: [KnowledgeExtractedSection]
  ) -> [KnowledgeChunk] {
    var output: [KnowledgeChunk] = []

    for section in sections {
      let normalized = Self.normalizedText(section.text)
      guard !normalized.isEmpty else { continue }

      let paragraphs = normalized
        .components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

      var buffer = ""
      for paragraph in paragraphs {
        if paragraph.count > maximumChunkCharacters {
          flush(
            &buffer,
            documentID: documentID,
            revisionID: revisionID,
            section: section,
            output: &output
          )
          appendLongParagraph(
            paragraph,
            documentID: documentID,
            revisionID: revisionID,
            section: section,
            output: &output
          )
          continue
        }

        let separator = buffer.isEmpty ? "" : "\n\n"
        if buffer.count + separator.count + paragraph.count > maximumChunkCharacters {
          let overlap = suffixForOverlap(buffer)
          flush(
            &buffer,
            documentID: documentID,
            revisionID: revisionID,
            section: section,
            output: &output
          )
          buffer = overlap
        }

        if !buffer.isEmpty {
          buffer += "\n\n"
        }
        buffer += paragraph
      }

      flush(
        &buffer,
        documentID: documentID,
        revisionID: revisionID,
        section: section,
        output: &output
      )
    }

    return output.enumerated().map { index, chunk in
      var numbered = chunk
      numbered.ordinal = index
      return numbered
    }
  }

  public static func normalizedText(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .joined(separator: "\n")
      .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func contentHash(for data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func contentHash(for text: String) -> String {
    contentHash(for: Data(text.utf8))
  }

  private func appendLongParagraph(
    _ paragraph: String,
    documentID: UUID,
    revisionID: UUID,
    section: KnowledgeExtractedSection,
    output: inout [KnowledgeChunk]
  ) {
    var start = paragraph.startIndex
    while start < paragraph.endIndex {
      let end = paragraph.index(
        start,
        offsetBy: maximumChunkCharacters,
        limitedBy: paragraph.endIndex
      ) ?? paragraph.endIndex
      let text = String(paragraph[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        output.append(makeChunk(
          text,
          documentID: documentID,
          revisionID: revisionID,
          section: section,
          ordinal: output.count
        ))
      }
      guard end < paragraph.endIndex else { break }
      start = paragraph.index(
        end,
        offsetBy: -overlapCharacters,
        limitedBy: paragraph.startIndex
      ) ?? end
    }
  }

  private func flush(
    _ buffer: inout String,
    documentID: UUID,
    revisionID: UUID,
    section: KnowledgeExtractedSection,
    output: inout [KnowledgeChunk]
  ) {
    let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    buffer = ""
    guard !text.isEmpty else { return }
    output.append(makeChunk(
      text,
      documentID: documentID,
      revisionID: revisionID,
      section: section,
      ordinal: output.count
    ))
  }

  private func makeChunk(
    _ text: String,
    documentID: UUID,
    revisionID: UUID,
    section: KnowledgeExtractedSection,
    ordinal: Int
  ) -> KnowledgeChunk {
    KnowledgeChunk(
      documentID: documentID,
      revisionID: revisionID,
      ordinal: ordinal,
      headingPath: section.headingPath?.nilIfEmpty,
      locator: section.locator?.nilIfEmpty,
      content: text,
      tokenEstimate: max(1, Self.tokenizer.tokenCount(text)),
      contentHash: Self.contentHash(for: text),
      visualAnchor: section.visualAnchor
    )
  }

  private func suffixForOverlap(_ text: String) -> String {
    guard overlapCharacters > 0, text.count > overlapCharacters else { return "" }
    let start = text.index(text.endIndex, offsetBy: -overlapCharacters)
    let suffix = String(text[start...])
    if let paragraphBoundary = suffix.range(of: "\n\n") {
      return String(suffix[paragraphBoundary.upperBound...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
