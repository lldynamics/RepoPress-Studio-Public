import Foundation

public enum FrontMatterDocumentSyntax: String, Codable, Hashable, Sendable {
  case yaml
  case toml
}

public enum FrontMatterTaxonomyLayout: String, Codable, Hashable, Sendable {
  case inlineTable
  case table
}

public struct FrontMatterDocument: Codable, Hashable, Sendable {
  public var syntax: FrontMatterDocumentSyntax
  public var title: String
  public var formattedDate: String
  public var slug: String?
  public var draftFlag: Bool?
  public var summaryField: String?
  public var summary: String?
  public var authors: [String]
  public var tags: [String]
  public var categories: [String]
  public var taxonomyLayout: FrontMatterTaxonomyLayout
  public var coverField: String?
  public var coverPath: String?
  public var writesCoverInExtraTable: Bool
  public var bodyMarkdown: String

  public init(
    syntax: FrontMatterDocumentSyntax,
    title: String,
    formattedDate: String,
    slug: String?,
    draftFlag: Bool?,
    summaryField: String?,
    summary: String?,
    authors: [String],
    tags: [String],
    categories: [String],
    taxonomyLayout: FrontMatterTaxonomyLayout,
    coverField: String?,
    coverPath: String?,
    writesCoverInExtraTable: Bool,
    bodyMarkdown: String
  ) {
    self.syntax = syntax
    self.title = title
    self.formattedDate = formattedDate
    self.slug = slug
    self.draftFlag = draftFlag
    self.summaryField = summaryField
    self.summary = summary
    self.authors = authors
    self.tags = tags
    self.categories = categories
    self.taxonomyLayout = taxonomyLayout
    self.coverField = coverField
    self.coverPath = coverPath
    self.writesCoverInExtraTable = writesCoverInExtraTable
    self.bodyMarkdown = bodyMarkdown
  }
}

public struct FrontMatterDocumentRenderer: Sendable {
  public init() {}

  public func render(_ document: FrontMatterDocument) -> String {
    switch document.syntax {
    case .yaml:
      return renderYAML(document)
    case .toml:
      return renderTOML(document)
    }
  }

  public func markdownDocument(_ document: FrontMatterDocument) -> String {
    "\(render(document))\n\n\(document.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines))\n"
  }

  private func renderYAML(_ document: FrontMatterDocument) -> String {
    var lines = [
      "---",
      "title: \(quoted(document.title))",
      "date: \(quoted(document.formattedDate))",
    ]
    appendCommonScalarFields(to: &lines, document: document, separator: ":")
    appendYAMLCollections(to: &lines, document: document)
    if let draftFlag = document.draftFlag {
      lines.append("draft: \(draftFlag ? "true" : "false")")
    }
    appendSummary(to: &lines, document: document, separator: ":")
    appendCover(to: &lines, document: document, separator: ":")
    lines.append("---")
    return lines.joined(separator: "\n")
  }

  private func renderTOML(_ document: FrontMatterDocument) -> String {
    var lines = [
      "+++",
      "title = \(quoted(document.title))",
      "date = \(document.formattedDate)",
    ]
    appendCommonScalarFields(to: &lines, document: document, separator: "=")
    if let draftFlag = document.draftFlag {
      lines.append("draft = \(draftFlag ? "true" : "false")")
    }
    appendSummary(to: &lines, document: document, separator: "=")
    if !document.authors.isEmpty {
      lines.append("authors = [\(quotedList(document.authors))]")
    }
    if !document.writesCoverInExtraTable {
      appendCover(to: &lines, document: document, separator: "=")
    }
    appendTOMLTaxonomies(to: &lines, document: document)
    if document.writesCoverInExtraTable, let coverPath = document.coverPath {
      lines.append("[extra]")
      lines.append("og_preview_img = \(quoted(coverPath))")
    }
    lines.append("+++")
    return lines.joined(separator: "\n")
  }

  private func appendCommonScalarFields(
    to lines: inout [String],
    document: FrontMatterDocument,
    separator: String
  ) {
    if let slug = document.slug {
      lines.append(assignment(field: "slug", value: quoted(slug), separator: separator))
    }
  }

  private func appendYAMLCollections(
    to lines: inout [String],
    document: FrontMatterDocument
  ) {
    if !document.tags.isEmpty {
      lines.append("tags: [\(quotedList(document.tags))]")
    }
    if !document.categories.isEmpty {
      lines.append("categories: [\(quotedList(document.categories))]")
    }
    if !document.authors.isEmpty {
      lines.append("authors: [\(quotedList(document.authors))]")
    }
  }

  private func appendSummary(
    to lines: inout [String],
    document: FrontMatterDocument,
    separator: String
  ) {
    guard let field = document.summaryField, let summary = document.summary else {
      return
    }
    lines.append(assignment(field: field, value: quoted(summary), separator: separator))
  }

  private func appendCover(
    to lines: inout [String],
    document: FrontMatterDocument,
    separator: String
  ) {
    guard let field = document.coverField, let path = document.coverPath else {
      return
    }
    lines.append(assignment(field: field, value: quoted(path), separator: separator))
  }

  private func appendTOMLTaxonomies(
    to lines: inout [String],
    document: FrontMatterDocument
  ) {
    guard !document.tags.isEmpty || !document.categories.isEmpty else {
      return
    }
    switch document.taxonomyLayout {
    case .inlineTable:
      var entries: [String] = []
      if !document.tags.isEmpty {
        entries.append("tags = [\(quotedList(document.tags))]")
      }
      if !document.categories.isEmpty {
        entries.append("categories = [\(quotedList(document.categories))]")
      }
      lines.append("taxonomies = { \(entries.joined(separator: ", ")) }")
    case .table:
      lines.append("[taxonomies]")
      if !document.tags.isEmpty {
        lines.append("tags = [\(quotedList(document.tags))]")
      }
      if !document.categories.isEmpty {
        lines.append("categories = [\(quotedList(document.categories))]")
      }
    }
  }

  private func quotedList(_ values: [String]) -> String {
    values.map(quoted).joined(separator: ", ")
  }

  private func assignment(field: String, value: String, separator: String) -> String {
    separator == ":" ? "\(field): \(value)" : "\(field) = \(value)"
  }

  private func quoted(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
  }
}
