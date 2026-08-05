import Foundation

public enum ExternalPlatformSourceKind: String, Sendable, CaseIterable, Identifiable {
  case notion = "Notion"
  case readwise = "Readwise"
  case localMarkdown = "Markdown 目录"

  public var id: String { rawValue }
}

public struct ExternalPlatformImportItem: Hashable, Identifiable, Sendable {
  public var id: UUID
  public var title: String
  public var bodyMarkdown: String
  public var tags: [String]
  public var sourceKind: ExternalPlatformSourceKind
  public var originalURLText: String?
  public var date: Date?

  public init(
    id: UUID = UUID(),
    title: String,
    bodyMarkdown: String,
    tags: [String] = [],
    sourceKind: ExternalPlatformSourceKind,
    originalURLText: String? = nil,
    date: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.bodyMarkdown = bodyMarkdown
    self.tags = tags
    self.sourceKind = sourceKind
    self.originalURLText = originalURLText
    self.date = date
  }
}

public struct ExternalPlatformImportAdapter: Sendable {
  public init() {}

  /// Parses Notion export archives (.zip or extracted directory with Markdown & CSV files)
  public func parseNotionExport(at url: URL) throws -> [ExternalPlatformImportItem] {
    let fileManager = FileManager.default
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
      return []
    }

    var items: [ExternalPlatformImportItem] = []
    let targetURLs: [URL]
    if isDir.boolValue {
      targetURLs = try fileManager.subpathsOfDirectory(atPath: url.path).compactMap { relativePath in
        guard relativePath.hasSuffix(".md") || relativePath.hasSuffix(".csv") else { return nil }
        return url.appendingPathComponent(relativePath)
      }
    } else if url.pathExtension.lowercased() == "md" {
      targetURLs = [url]
    } else {
      targetURLs = []
    }

    for fileURL in targetURLs {
      guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
      let title = cleanNotionTitle(fileURL.deletingPathExtension().lastPathComponent)
      items.append(ExternalPlatformImportItem(
        title: title,
        bodyMarkdown: content,
        tags: ["Notion"],
        sourceKind: .notion,
        date: try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
      ))
    }

    return items
  }

  /// Parses Readwise exported JSON / CSV highlights
  public func parseReadwiseExport(data: Data) throws -> [ExternalPlatformImportItem] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let highlights = json["highlights"] as? [[String: Any]] else {
      return []
    }

    var itemsByBook: [String: [String]] = [:]
    for highlight in highlights {
      let text = (highlight["text"] as? String) ?? ""
      let bookTitle = (highlight["title"] as? String) ?? "Readwise 标注集"
      guard !text.isEmpty else { continue }
      itemsByBook[bookTitle, default: []].append("> \(text)")
    }

    return itemsByBook.map { bookTitle, quotes in
      ExternalPlatformImportItem(
        title: bookTitle,
        bodyMarkdown: quotes.joined(separator: "\n\n"),
        tags: ["Readwise", "Highlight"],
        sourceKind: .readwise,
        date: Date()
      )
    }
  }

  /// Parses a local directory tree of Markdown files
  public func parseLocalMarkdownFolder(at url: URL) throws -> [ExternalPlatformImportItem] {
    let fileManager = FileManager.default
    let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])

    var items: [ExternalPlatformImportItem] = []
    while let fileURL = enumerator?.nextObject() as? URL {
      guard fileURL.pathExtension.lowercased() == "md" || fileURL.pathExtension.lowercased() == "markdown" else { continue }
      guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
      let title = fileURL.deletingPathExtension().lastPathComponent
      let modDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

      items.append(ExternalPlatformImportItem(
        title: title,
        bodyMarkdown: content,
        tags: ["LocalImport"],
        sourceKind: .localMarkdown,
        date: modDate
      ))
    }

    return items
  }

  private func cleanNotionTitle(_ raw: String) -> String {
    // Notion export filenames look like "My Page Name 3a4b5c6d7e8f"
    let components = raw.split(separator: " ")
    if let last = components.last, last.count == 32 || last.count == 36, last.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
      return components.dropLast().joined(separator: " ")
    }
    return raw
  }
}
