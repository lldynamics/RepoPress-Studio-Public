import Foundation

public enum RepositoryTextEncoding: String, CaseIterable, Hashable, Sendable {
  case utf8
  case utf8WithBOM
  case utf16LittleEndian
  case utf16BigEndian

  public var displayName: String {
    switch self {
    case .utf8:
      CoreL10n.text("UTF-8")
    case .utf8WithBOM:
      CoreL10n.text("UTF-8 BOM")
    case .utf16LittleEndian:
      CoreL10n.text("UTF-16 LE")
    case .utf16BigEndian:
      CoreL10n.text("UTF-16 BE")
    }
  }
}

public enum RepositoryLineEnding: String, CaseIterable, Hashable, Sendable {
  case lf
  case crlf
  case cr

  public var displayName: String {
    switch self {
    case .lf:
      CoreL10n.text("LF")
    case .crlf:
      CoreL10n.text("CRLF")
    case .cr:
      CoreL10n.text("CR")
    }
  }

  var sequence: String {
    switch self {
    case .lf: "\n"
    case .crlf: "\r\n"
    case .cr: "\r"
    }
  }
}

public enum HTMLSourceDialect: String, CaseIterable, Hashable, Sendable {
  case html
  case liquid
  case tera
  case goTemplate
  case astro

  public var displayName: String {
    switch self {
    case .html:
      CoreL10n.text("HTML")
    case .liquid:
      CoreL10n.text("Liquid")
    case .tera:
      CoreL10n.text("Tera")
    case .goTemplate:
      CoreL10n.text("Go Template")
    case .astro:
      CoreL10n.text("Astro")
    }
  }
}

public struct RepositoryHTMLFileDescriptor: Identifiable, Hashable, Sendable {
  public var id: String { repositoryPath }
  public var repositoryPath: String
  public var byteSize: Int
  public var modificationDate: Date?
  public var isEditable: Bool

  public init(
    repositoryPath: String,
    byteSize: Int,
    modificationDate: Date?,
    isEditable: Bool
  ) {
    self.repositoryPath = repositoryPath
    self.byteSize = byteSize
    self.modificationDate = modificationDate
    self.isEditable = isEditable
  }
}

/// A repository-backed source-editing session.
///
/// `text` is normalized to LF while it is edited. The editing service keeps
/// the original encoding, newline convention, and byte digest in the session
/// so a successful save can preserve the file format and reject stale writes.
public struct RepositoryTextDocument: Identifiable, Hashable, Sendable {
  public var id: String { repositoryRootPath + "\n" + repositoryPath }

  public private(set) var repositoryRootPath: String
  public private(set) var repositoryPath: String
  public var text: String
  public private(set) var encoding: RepositoryTextEncoding
  public private(set) var lineEnding: RepositoryLineEnding
  public private(set) var dialect: HTMLSourceDialect
  public private(set) var byteSize: Int
  public private(set) var modificationDate: Date?
  public private(set) var hasMixedLineEndings: Bool

  let baselineText: String
  let baselineSHA256: Data
  let repositoryRootDevice: UInt64
  let repositoryRootInode: UInt64

  init(
    repositoryRootPath: String,
    repositoryPath: String,
    text: String,
    encoding: RepositoryTextEncoding,
    lineEnding: RepositoryLineEnding,
    dialect: HTMLSourceDialect,
    byteSize: Int,
    modificationDate: Date?,
    baselineSHA256: Data,
    hasMixedLineEndings: Bool,
    repositoryRootDevice: UInt64,
    repositoryRootInode: UInt64
  ) {
    self.repositoryRootPath = repositoryRootPath
    self.repositoryPath = repositoryPath
    self.text = text
    self.encoding = encoding
    self.lineEnding = lineEnding
    self.dialect = dialect
    self.byteSize = byteSize
    self.modificationDate = modificationDate
    self.hasMixedLineEndings = hasMixedLineEndings
    baselineText = text
    self.baselineSHA256 = baselineSHA256
    self.repositoryRootDevice = repositoryRootDevice
    self.repositoryRootInode = repositoryRootInode
  }

  public var hasUnsavedChanges: Bool {
    text != baselineText
  }
}
