import Foundation
import PDFKit

struct KnowledgeContentExtraction: Sendable {
  var kind: KnowledgeDocumentKind
  var title: String
  var authors: [String]
  var language: String?
  var summary: String
  var tags: [String]
  var sections: [KnowledgeExtractedSection]
  var warnings: [String]
}

struct KnowledgeContentExtractionService {
  private let webContentSanitizer = KnowledgeWebContentSanitizer()
  private let epubParser = KnowledgeEPUBParser()
  private let pdfOCRService = KnowledgePDFOCRService()

  func extract(
    data: Data,
    sourceName: String,
    fileExtension: String,
    preferredKind: KnowledgeDocumentKind?,
    options: KnowledgeImportOptions
  ) throws -> KnowledgeContentExtraction {
    switch fileExtension.lowercased() {
    case "md", "markdown", "mdx":
      return try extractMarkdown(data: data, sourceName: sourceName)
    case "txt", "text":
      return try extractPlainText(data: data, sourceName: sourceName)
    case "html", "htm":
      return try extractHTML(data: data, sourceName: sourceName)
    case "pdf":
      return try extractPDF(data: data, sourceName: sourceName, options: options)
    case "epub":
      return try extractEPUB(data: data, sourceName: sourceName)
    default:
      if preferredKind == .webpage {
        return try extractHTML(data: data, sourceName: sourceName)
      }
      throw KnowledgeLibraryError.unsupportedSource(sourceName)
    }
  }

  private func extractMarkdown(data: Data, sourceName: String) throws -> KnowledgeContentExtraction {
    guard let source = String(data: data, encoding: .utf8) else {
      throw KnowledgeLibraryError.unreadableSource(sourceName)
    }
    let parsed = markdownFrontMatter(source)
    let title = parsed.values["title"]?.nilIfEmpty
      ?? firstMarkdownHeading(parsed.body)
      ?? humanizedFilename(sourceName)
    let authors = listValue(parsed.values["authors"] ?? parsed.values["author"])
    let tags = listValue(parsed.values["tags"] ?? parsed.values["tag"])
    let summary = parsed.values["summary"] ?? parsed.values["description"] ?? ""
    return KnowledgeContentExtraction(
      kind: .markdown,
      title: title,
      authors: authors,
      language: parsed.values["language"] ?? parsed.values["lang"],
      summary: summary,
      tags: tags,
      sections: markdownSections(parsed.body),
      warnings: []
    )
  }

  private func extractPlainText(data: Data, sourceName: String) throws -> KnowledgeContentExtraction {
    guard let text = String(data: data, encoding: .utf8) else {
      throw KnowledgeLibraryError.unreadableSource(sourceName)
    }
    return KnowledgeContentExtraction(
      kind: .text,
      title: firstNonEmptyLine(text) ?? humanizedFilename(sourceName),
      authors: [],
      language: nil,
      summary: "",
      tags: [],
      sections: [KnowledgeExtractedSection(text: text)],
      warnings: []
    )
  }

  private func extractHTML(data: Data, sourceName: String) throws -> KnowledgeContentExtraction {
    let sanitized = try webContentSanitizer.sanitize(data: data, sourceName: sourceName)
    var warnings = ["网页正文已在本机净化；原始 HTML 保持不变。"]
    if sanitized.selectedMainContent {
      warnings.append("已优先提取页面的 article/main 正文区域。")
    }
    if sanitized.removedNoiseBlockCount > 0 {
      warnings.append("已移除 \(sanitized.removedNoiseBlockCount) 个导航、广告或交互噪声区块。")
    }
    return KnowledgeContentExtraction(
      kind: .webpage,
      title: sanitized.title ?? humanizedFilename(sourceName),
      authors: sanitized.authors,
      language: sanitized.language,
      summary: sanitized.summary,
      tags: [],
      sections: sanitized.sections,
      warnings: warnings
    )
  }

  private func extractPDF(
    data: Data,
    sourceName: String,
    options: KnowledgeImportOptions
  ) throws -> KnowledgeContentExtraction {
    guard let document = PDFDocument(data: data) else {
      throw KnowledgeLibraryError.unreadableSource(sourceName)
    }
    var sections: [KnowledgeExtractedSection] = []
    var emptyPageCount = 0
    var ocrAttemptCount = 0
    var ocrRecognizedCount = 0
    var ocrFailureCount = 0
    var ocrLimitSkippedCount = 0
    for index in 0..<document.pageCount {
      try Task.checkCancellation()
      guard let page = document.page(at: index) else {
        emptyPageCount += 1
        continue
      }
      let pageText = page.string?.trimmedForPublishing ?? ""
      if !pageText.isEmpty {
        sections.append(KnowledgeExtractedSection(locator: "第 \(index + 1) 页", text: pageText))
        continue
      }

      guard options.performsPDFOCR else {
        emptyPageCount += 1
        continue
      }
      guard ocrAttemptCount < options.maximumPDFOCRPageCount else {
        emptyPageCount += 1
        ocrLimitSkippedCount += 1
        continue
      }

      ocrAttemptCount += 1
      do {
        let recognizedText = try pdfOCRService.recognizeText(in: page).trimmedForPublishing
        if recognizedText.isEmpty {
          emptyPageCount += 1
        } else {
          ocrRecognizedCount += 1
          sections.append(KnowledgeExtractedSection(
            locator: "第 \(index + 1) 页（OCR）",
            text: recognizedText
          ))
        }
      } catch {
        emptyPageCount += 1
        ocrFailureCount += 1
      }
    }
    var warnings: [String] = []
    if ocrRecognizedCount > 0 {
      warnings.append("已在本机使用 Vision OCR 识别 \(ocrRecognizedCount) 页；原始 PDF 保持不变。")
    }
    if ocrFailureCount > 0 {
      warnings.append("有 \(ocrFailureCount) 页 OCR 处理失败，未加入检索文本。")
    }
    if ocrLimitSkippedCount > 0 {
      warnings.append("OCR 最多处理 \(options.maximumPDFOCRPageCount) 页；另有 \(ocrLimitSkippedCount) 个无文字层页面未识别。")
    }
    if emptyPageCount > 0 {
      let reason = options.performsPDFOCR ? "OCR 后仍没有可识别文字" : "未启用 OCR"
      warnings.append("有 \(emptyPageCount) 页\(reason)，这些页面暂时不能检索。")
    }
    let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.nilIfEmpty
      ?? humanizedFilename(sourceName)
    let author = (document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String)?.nilIfEmpty
    return KnowledgeContentExtraction(
      kind: .pdf,
      title: title,
      authors: author.map { [$0] } ?? [],
      language: nil,
      summary: "",
      tags: [],
      sections: sections,
      warnings: warnings
    )
  }

  private func extractEPUB(data: Data, sourceName: String) throws -> KnowledgeContentExtraction {
    let book = try epubParser.parse(data: data, sourceName: sourceName)
    return KnowledgeContentExtraction(
      kind: .book,
      title: book.title.nilIfEmpty ?? humanizedFilename(sourceName),
      authors: book.authors,
      language: book.language,
      summary: book.summary,
      tags: book.tags,
      sections: book.sections,
      warnings: book.warnings
    )
  }

  private func markdownFrontMatter(_ source: String) -> (values: [String: String], body: String) {
    let lines = source.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
      return ([:], source)
    }
    guard let end = lines.dropFirst().firstIndex(where: {
      $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
    }) else {
      return ([:], source)
    }
    var values: [String: String] = [:]
    for line in lines[1..<end] {
      guard let separator = line.firstIndex(of: ":") else { continue }
      let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = line[line.index(after: separator)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      values[key] = value
    }
    return (values, lines[(end + 1)...].joined(separator: "\n"))
  }

  private func markdownSections(_ source: String) -> [KnowledgeExtractedSection] {
    var sections: [KnowledgeExtractedSection] = []
    var headings: [Int: String] = [:]
    var buffer: [String] = []

    func flush() {
      let text = buffer.joined(separator: "\n").trimmedForPublishing
      buffer = []
      guard !text.isEmpty else { return }
      let path = headings.keys.sorted().compactMap { headings[$0] }.joined(separator: " › ")
      sections.append(KnowledgeExtractedSection(
        headingPath: path.nilIfEmpty,
        text: text
      ))
    }

    for line in source.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let hashes = trimmed.prefix { $0 == "#" }.count
      if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
        flush()
        let heading = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        headings[hashes] = heading
        if hashes < 6 {
          for level in (hashes + 1)...6 { headings.removeValue(forKey: level) }
        }
      } else {
        buffer.append(line)
      }
    }
    flush()
    if sections.isEmpty {
      return [KnowledgeExtractedSection(text: source)]
    }
    return sections
  }

  private func firstMarkdownHeading(_ source: String) -> String? {
    source.components(separatedBy: .newlines).compactMap { line -> String? in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("# ") else { return nil }
      return String(trimmed.dropFirst(2)).trimmedForPublishing.nilIfEmpty
    }.first
  }

  private func listValue(_ value: String?) -> [String] {
    guard let value else { return [] }
    let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    return trimmed
      .components(separatedBy: CharacterSet(charactersIn: ",，"))
      .map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      }
      .filter { !$0.isEmpty }
  }

  private func firstCapture(in text: String, pattern: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
          ),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range]).trimmedForPublishing.nilIfEmpty
  }

  private func firstNonEmptyLine(_ text: String) -> String? {
    text.components(separatedBy: .newlines)
      .map { $0.trimmedForPublishing }
      .first(where: { !$0.isEmpty })?
      .nilIfEmpty
  }

  func humanizedFilename(_ name: String) -> String {
    let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    let humanized = stem
      .replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return humanized.nilIfEmpty ?? "未命名资料"
  }
}
