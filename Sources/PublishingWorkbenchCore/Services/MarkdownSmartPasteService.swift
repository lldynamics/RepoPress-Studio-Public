import Foundation

public struct MarkdownSmartPasteService: Sendable {
  public init() {}

  public func linkEdit(
    in markdown: String,
    selectedRange: NSRange,
    pastedText: String
  ) -> MarkdownSmartEdit? {
    let source = markdown as NSString
    guard selectedRange.length > 0,
          selectedRange.location >= 0,
          NSMaxRange(selectedRange) <= source.length,
          let normalizedURL = normalizedWebURL(from: pastedText) else {
      return nil
    }

    let selectedText = source.substring(with: selectedRange)
    guard !selectedText.trimmedForPublishing.isEmpty else { return nil }
    let label = selectedText
      .replacingOccurrences(of: #"\"#, with: #"\\"#)
      .replacingOccurrences(of: "]", with: #"\]"#)
    let destination = normalizedURL.contains("(") || normalizedURL.contains(")")
      ? "<\(normalizedURL)>"
      : normalizedURL
    let replacement = "[\(label)](\(destination))"

    return MarkdownSmartEdit(
      replacedRange: selectedRange,
      replacement: replacement,
      selectedRange: NSRange(
        location: selectedRange.location + (replacement as NSString).length,
        length: 0
      )
    )
  }

  private func normalizedWebURL(from pastedText: String) -> String? {
    MarkdownPastedURLSanitizer.webURL(from: pastedText)
  }
}

public enum PastedImageFileStoreError: LocalizedError, Equatable, Sendable {
  case emptyImageData

  public var errorDescription: String? {
    switch self {
    case .emptyImageData:
      return "剪贴板图片数据为空。"
    }
  }
}

public struct PastedImageFileStore: Sendable {
  public let rootDirectoryURL: URL

  public init(rootDirectoryURL: URL? = nil) {
    if let rootDirectoryURL {
      self.rootDirectoryURL = rootDirectoryURL
    } else {
      let supportURL = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
      self.rootDirectoryURL = supportURL
        .appendingPathComponent("PersonalSitePublisherMac", isDirectory: true)
        .appendingPathComponent("PastedImages", isDirectory: true)
    }
  }

  public func storePNG(
    _ data: Data,
    id: UUID = UUID()
  ) throws -> URL {
    guard !data.isEmpty else {
      throw PastedImageFileStoreError.emptyImageData
    }

    try FileManager.default.createDirectory(
      at: rootDirectoryURL,
      withIntermediateDirectories: true
    )
    let destinationURL = rootDirectoryURL.appendingPathComponent(
      "pasted-image-\(id.uuidString.lowercased()).png"
    )
    try data.write(to: destinationURL, options: .atomic)
    return destinationURL
  }
}
