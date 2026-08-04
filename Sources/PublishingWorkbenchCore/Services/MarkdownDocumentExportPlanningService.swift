import Foundation

public enum MarkdownDocumentExportFormat: String, CaseIterable, Equatable, Sendable {
  case markdown
  case html
  case pdf
  case print
  case share

  public var defaultFileExtension: String? {
    switch self {
    case .markdown, .share:
      return "md"
    case .html:
      return "html"
    case .pdf:
      return "pdf"
    case .print:
      return nil
    }
  }
}

public struct MarkdownDocumentExportCapabilities: Equatable, Sendable {
  public var canWriteFiles: Bool
  public var canRenderPDF: Bool
  public var canPrint: Bool
  public var canShare: Bool

  public init(
    canWriteFiles: Bool = true,
    canRenderPDF: Bool = true,
    canPrint: Bool = true,
    canShare: Bool = true
  ) {
    self.canWriteFiles = canWriteFiles
    self.canRenderPDF = canRenderPDF
    self.canPrint = canPrint
    self.canShare = canShare
  }

  public static let allAvailable = MarkdownDocumentExportCapabilities()
}

public enum MarkdownDocumentExportAvailabilityIssue: Equatable, Sendable {
  case emptyDocument
  case fileWritingUnavailable
  case pdfRenderingUnavailable
  case printingUnavailable
  case sharingUnavailable
}

public struct MarkdownDocumentExportAvailability: Equatable, Sendable {
  public var issues: [MarkdownDocumentExportAvailabilityIssue]

  public init(issues: [MarkdownDocumentExportAvailabilityIssue]) {
    self.issues = issues
  }

  public var isAvailable: Bool {
    issues.isEmpty
  }
}

public enum MarkdownDocumentExportOperation: Equatable, Sendable {
  case writeUTF8File
  case renderHTMLToPDF
  case printHTML
  case shareMarkdown
}

public enum MarkdownDocumentExportPayload: Equatable, Sendable {
  case text(String)
  case html(String)
}

public struct MarkdownDocumentExportPlan: Equatable, Sendable {
  public var format: MarkdownDocumentExportFormat
  public var operation: MarkdownDocumentExportOperation
  public var title: String
  public var suggestedFilename: String?
  public var mimeType: String?
  public var payload: MarkdownDocumentExportPayload

  public init(
    format: MarkdownDocumentExportFormat,
    operation: MarkdownDocumentExportOperation,
    title: String,
    suggestedFilename: String?,
    mimeType: String?,
    payload: MarkdownDocumentExportPayload
  ) {
    self.format = format
    self.operation = operation
    self.title = title
    self.suggestedFilename = suggestedFilename
    self.mimeType = mimeType
    self.payload = payload
  }
}

public enum MarkdownDocumentExportPlanningError: LocalizedError, Equatable, Sendable {
  case unavailable([MarkdownDocumentExportAvailabilityIssue])

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      return CoreL10n.text("当前环境无法执行所选导出操作。")
    }
  }
}

public struct MarkdownDocumentExportPlanningService: Sendable {
  public init() {}

  public func availability(
    title: String,
    markdown: String,
    format: MarkdownDocumentExportFormat,
    capabilities: MarkdownDocumentExportCapabilities = .allAvailable
  ) -> MarkdownDocumentExportAvailability {
    var issues: [MarkdownDocumentExportAvailabilityIssue] = []
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      issues.append(.emptyDocument)
    }

    switch format {
    case .markdown, .html:
      if !capabilities.canWriteFiles {
        issues.append(.fileWritingUnavailable)
      }
    case .pdf:
      if !capabilities.canWriteFiles {
        issues.append(.fileWritingUnavailable)
      }
      if !capabilities.canRenderPDF {
        issues.append(.pdfRenderingUnavailable)
      }
    case .print:
      if !capabilities.canPrint {
        issues.append(.printingUnavailable)
      }
    case .share:
      if !capabilities.canShare {
        issues.append(.sharingUnavailable)
      }
    }
    return MarkdownDocumentExportAvailability(issues: issues)
  }

  public func plan(
    title: String,
    markdown: String,
    format: MarkdownDocumentExportFormat,
    preferredFilename: String? = nil,
    capabilities: MarkdownDocumentExportCapabilities = .allAvailable
  ) throws -> MarkdownDocumentExportPlan {
    let availability = availability(
      title: title,
      markdown: markdown,
      format: format,
      capabilities: capabilities
    )
    guard availability.isAvailable else {
      throw MarkdownDocumentExportPlanningError.unavailable(availability.issues)
    }

    let displayTitle =
      title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? CoreL10n.text("未命名文章")
      : title.trimmingCharacters(in: .whitespacesAndNewlines)
    let html = completeHTMLDocument(title: displayTitle, markdown: markdown)

    switch format {
    case .markdown:
      return MarkdownDocumentExportPlan(
        format: format,
        operation: .writeUTF8File,
        title: displayTitle,
        suggestedFilename: safeFilename(
          preferredFilename ?? displayTitle,
          fileExtension: "md"
        ),
        mimeType: "text/markdown",
        payload: .text(markdown)
      )
    case .html:
      return MarkdownDocumentExportPlan(
        format: format,
        operation: .writeUTF8File,
        title: displayTitle,
        suggestedFilename: safeFilename(
          preferredFilename ?? displayTitle,
          fileExtension: "html"
        ),
        mimeType: "text/html",
        payload: .html(html)
      )
    case .pdf:
      return MarkdownDocumentExportPlan(
        format: format,
        operation: .renderHTMLToPDF,
        title: displayTitle,
        suggestedFilename: safeFilename(
          preferredFilename ?? displayTitle,
          fileExtension: "pdf"
        ),
        mimeType: "application/pdf",
        payload: .html(html)
      )
    case .print:
      return MarkdownDocumentExportPlan(
        format: format,
        operation: .printHTML,
        title: displayTitle,
        suggestedFilename: nil,
        mimeType: "text/html",
        payload: .html(html)
      )
    case .share:
      return MarkdownDocumentExportPlan(
        format: format,
        operation: .shareMarkdown,
        title: displayTitle,
        suggestedFilename: safeFilename(
          preferredFilename ?? displayTitle,
          fileExtension: "md"
        ),
        mimeType: "text/markdown",
        payload: .text(markdown)
      )
    }
  }

  public func safeFilename(
    _ proposedName: String,
    fileExtension proposedExtension: String
  ) -> String {
    let safeExtension =
      proposedExtension
      .lowercased()
      .unicodeScalars
      .filter(CharacterSet.alphanumerics.contains)
      .map(String.init)
      .joined()
    let fallbackExtension = safeExtension.isEmpty ? "txt" : safeExtension
    var basename = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    let extensionSuffix = ".\(fallbackExtension)"
    if basename.lowercased().hasSuffix(extensionSuffix) {
      basename.removeLast(extensionSuffix.count)
    }

    let forbidden = CharacterSet.controlCharacters.union(
      CharacterSet(charactersIn: #"/\:*?"<>|"#)
    )
    basename =
      basename
      .components(separatedBy: forbidden)
      .joined(separator: "-")
      .replacingOccurrences(
        of: #"[\s-]+"#,
        with: "-",
        options: .regularExpression
      )
      .trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
    if basename.isEmpty || basename == "." || basename == ".." {
      basename = "untitled"
    }
    if Self.reservedBasenames.contains(basename.uppercased()) {
      basename += "-document"
    }
    if basename.count > Self.maximumBasenameLength {
      basename = String(basename.prefix(Self.maximumBasenameLength))
        .trimmingCharacters(in: CharacterSet(charactersIn: ".- "))
    }
    if basename.isEmpty {
      basename = "untitled"
    }
    return "\(basename).\(fallbackExtension)"
  }

  private func completeHTMLDocument(title: String, markdown: String) -> String {
    let body = MarkdownHTMLRenderingService.renderPreviewBodyAllowingSanitizedHTML(markdown)
    return """
      <!doctype html>
      <html lang="zh-Hans">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapedHTML(title))</title>
      </head>
      <body>
      \(body)
      </body>
      </html>
      """
  }

  private func escapedHTML(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }

  private static let maximumBasenameLength = 96
  private static let reservedBasenames: Set<String> = [
    "CON", "PRN", "AUX", "NUL",
    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
  ]
}
