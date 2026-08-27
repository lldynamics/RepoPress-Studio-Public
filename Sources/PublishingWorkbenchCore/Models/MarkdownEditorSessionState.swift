import Foundation

public struct MarkdownEditorSessionState: Codable, Equatable, Sendable {
  public var selectionLocation: Int
  public var selectionLength: Int
  public var editorScrollProgress: Double
  public var isFindReplacePresented: Bool
  public var findQuery: String
  public var replacementText: String
  public var isFindCaseSensitive: Bool
  public var isFindWholeWord: Bool
  public var isFindRegularExpression: Bool
  public var invalidFrontMatterDocument: String?
  public var invalidFrontMatterBaseBodyMarkdown: String?
  public var invalidFrontMatterBaseBodyRevision: UInt64?

  public init(
    selectedRange: NSRange = NSRange(location: 0, length: 0),
    editorScrollProgress: Double = 0,
    isFindReplacePresented: Bool = false,
    findQuery: String = "",
    replacementText: String = "",
    isFindCaseSensitive: Bool = false,
    isFindWholeWord: Bool = false,
    isFindRegularExpression: Bool = false,
    invalidFrontMatterDocument: String? = nil,
    invalidFrontMatterBaseBodyMarkdown: String? = nil,
    invalidFrontMatterBaseBodyRevision: UInt64? = nil
  ) {
    selectionLocation = max(0, selectedRange.location)
    selectionLength = max(0, selectedRange.length)
    self.editorScrollProgress = Self.normalizedProgress(editorScrollProgress)
    self.isFindReplacePresented = isFindReplacePresented
    self.findQuery = findQuery
    self.replacementText = replacementText
    self.isFindCaseSensitive = isFindCaseSensitive
    self.isFindWholeWord = isFindWholeWord
    self.isFindRegularExpression = isFindRegularExpression
    self.invalidFrontMatterDocument = invalidFrontMatterDocument
    self.invalidFrontMatterBaseBodyMarkdown = invalidFrontMatterBaseBodyMarkdown
    self.invalidFrontMatterBaseBodyRevision = invalidFrontMatterBaseBodyRevision
  }

  public static let empty = MarkdownEditorSessionState()

  public func normalized(bodyUTF16Count: Int) -> MarkdownEditorSessionState {
    let bodyLength = max(0, bodyUTF16Count)
    let location = min(max(selectionLocation, 0), bodyLength)
    let length = min(max(selectionLength, 0), bodyLength - location)
    return MarkdownEditorSessionState(
      selectedRange: NSRange(location: location, length: length),
      editorScrollProgress: editorScrollProgress,
      isFindReplacePresented: isFindReplacePresented,
      findQuery: findQuery,
      replacementText: replacementText,
      isFindCaseSensitive: isFindCaseSensitive,
      isFindWholeWord: isFindWholeWord,
      isFindRegularExpression: isFindRegularExpression,
      invalidFrontMatterDocument: invalidFrontMatterDocument,
      invalidFrontMatterBaseBodyMarkdown: invalidFrontMatterBaseBodyMarkdown,
      invalidFrontMatterBaseBodyRevision: invalidFrontMatterBaseBodyRevision
    )
  }

  public func selectedRange(bodyUTF16Count: Int) -> NSRange {
    let normalized = normalized(bodyUTF16Count: bodyUTF16Count)
    return NSRange(
      location: normalized.selectionLocation,
      length: normalized.selectionLength
    )
  }

  private static func normalizedProgress(_ value: Double) -> Double {
    min(max(value.isFinite ? value : 0, 0), 1)
  }
}
