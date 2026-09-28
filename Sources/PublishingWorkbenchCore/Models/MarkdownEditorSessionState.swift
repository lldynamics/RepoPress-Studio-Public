import Foundation

public struct MarkdownInvalidFrontMatterRecovery: Codable, Equatable, Sendable {
  public var document: String
  public var baseBodyMarkdown: String?
  public var baseBodyRevision: UInt64?
  public var baseMetadataRevision: UInt64?
  public var version: UInt64

  public init(
    document: String,
    baseBodyMarkdown: String? = nil,
    baseBodyRevision: UInt64? = nil,
    baseMetadataRevision: UInt64? = nil,
    version: UInt64 = 1
  ) {
    self.document = document
    self.baseBodyMarkdown = baseBodyMarkdown
    self.baseBodyRevision = baseBodyRevision
    self.baseMetadataRevision = baseMetadataRevision
    self.version = max(1, version)
  }
}

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
  public var invalidFrontMatterBaseMetadataRevision: UInt64?
  /// Recovery text is a window-owned transient document. Keeping its owner
  /// and version alongside the payload prevents another window's ordinary
  /// session save from erasing it.
  public var invalidFrontMatterRecoveryOwnerWindowID: UUID?
  public var invalidFrontMatterRecoveryVersion: UInt64?
  /// New sessions keep every window's recovery independently. The older
  /// scalar fields remain for decoding historical snapshots.
  public var invalidFrontMatterRecoveryRecords: [UUID: MarkdownInvalidFrontMatterRecovery]?

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
    invalidFrontMatterBaseBodyRevision: UInt64? = nil,
    invalidFrontMatterBaseMetadataRevision: UInt64? = nil,
    invalidFrontMatterRecoveryOwnerWindowID: UUID? = nil,
    invalidFrontMatterRecoveryVersion: UInt64? = nil,
    invalidFrontMatterRecoveryRecords: [UUID: MarkdownInvalidFrontMatterRecovery]? = nil
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
    self.invalidFrontMatterBaseMetadataRevision = invalidFrontMatterBaseMetadataRevision
    self.invalidFrontMatterRecoveryOwnerWindowID = invalidFrontMatterRecoveryOwnerWindowID
    self.invalidFrontMatterRecoveryVersion = invalidFrontMatterRecoveryVersion
    self.invalidFrontMatterRecoveryRecords = invalidFrontMatterRecoveryRecords
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
      invalidFrontMatterBaseBodyRevision: invalidFrontMatterBaseBodyRevision,
      invalidFrontMatterBaseMetadataRevision: invalidFrontMatterBaseMetadataRevision,
      invalidFrontMatterRecoveryOwnerWindowID: invalidFrontMatterRecoveryOwnerWindowID,
      invalidFrontMatterRecoveryVersion: invalidFrontMatterRecoveryVersion,
      invalidFrontMatterRecoveryRecords: invalidFrontMatterRecoveryRecords
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
