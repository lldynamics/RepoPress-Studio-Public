import Foundation

/// The kind of repository file represented by a publishing package.
public enum PublishFileKind: String, Codable, Hashable, Sendable {
  case markdown
  case image
  case video
}

/// The operation a publishing package should perform for a repository file.
public enum PublishFileOperation: String, Codable, Hashable, Sendable {
  case upsert
  case delete
}

/// One repository file in a publishing package.
public struct PublishPackageFile: Identifiable, Codable, Hashable, Sendable {
  public var id: String { repositoryPath }
  public var kind: PublishFileKind
  public var operation: PublishFileOperation
  public var repositoryPath: String
  public var content: String?
  public var sourceFilePath: String?
  public var byteSize: Int64
  public var expectedRemoteSHA: String?
  /// Optional exact-content evidence used only to adopt a legacy delete when
  /// the draft has no recorded provider version. These digests never weaken a
  /// known-version comparison.
  public var expectedContentSHA256: String?
  public var expectedGitBlobSHA: String?

  public init(
    kind: PublishFileKind,
    operation: PublishFileOperation = .upsert,
    repositoryPath: String,
    content: String? = nil,
    sourceFilePath: String? = nil,
    byteSize: Int64 = 0,
    expectedRemoteSHA: String? = nil,
    expectedContentSHA256: String? = nil,
    expectedGitBlobSHA: String? = nil
  ) {
    self.kind = kind
    self.operation = operation
    self.repositoryPath = repositoryPath
    self.content = content
    self.sourceFilePath = sourceFilePath
    self.byteSize = byteSize
    self.expectedRemoteSHA = expectedRemoteSHA
    self.expectedContentSHA256 = expectedContentSHA256
    self.expectedGitBlobSHA = expectedGitBlobSHA
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case operation
    case repositoryPath
    case content
    case sourceFilePath
    case byteSize
    case expectedRemoteSHA
    case expectedContentSHA256
    case expectedGitBlobSHA
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(PublishFileKind.self, forKey: .kind)
    // Payloads written before delete operations existed omitted this key.
    operation = try container.decodeIfPresent(PublishFileOperation.self, forKey: .operation)
      ?? .upsert
    repositoryPath = try container.decode(String.self, forKey: .repositoryPath)
    content = try container.decodeIfPresent(String.self, forKey: .content)
    sourceFilePath = try container.decodeIfPresent(String.self, forKey: .sourceFilePath)
    byteSize = try container.decodeIfPresent(Int64.self, forKey: .byteSize) ?? 0
    expectedRemoteSHA = try container.decodeIfPresent(String.self, forKey: .expectedRemoteSHA)
    expectedContentSHA256 = try container.decodeIfPresent(
      String.self,
      forKey: .expectedContentSHA256
    )
    expectedGitBlobSHA = try container.decodeIfPresent(String.self, forKey: .expectedGitBlobSHA)
  }
}

/// The complete, serializable output of the publishing package builder.
public struct PublishPackage: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var draftID: UUID
  public var title: String
  public var draftSummary: String?
  public var draftCoverAltText: String?
  public var markdownPath: String
  public var files: [PublishPackageFile]
  public var commitMessage: String
  public var reviewBranchName: String
  public var reviewTitle: String
  public var reviewChecklist: [String]
  public var builtAt: Date

  public init(
    id: UUID = UUID(),
    draftID: UUID,
    title: String,
    draftSummary: String? = nil,
    draftCoverAltText: String? = nil,
    markdownPath: String,
    files: [PublishPackageFile],
    commitMessage: String,
    reviewBranchName: String,
    reviewTitle: String,
    reviewChecklist: [String],
    builtAt: Date = Date()
  ) {
    self.id = id
    self.draftID = draftID
    self.title = title
    self.draftSummary = draftSummary
    self.draftCoverAltText = draftCoverAltText
    self.markdownPath = markdownPath
    self.files = files
    self.commitMessage = commitMessage
    self.reviewBranchName = reviewBranchName
    self.reviewTitle = reviewTitle
    self.reviewChecklist = reviewChecklist
    self.builtAt = builtAt
  }

  public var markdownFile: PublishPackageFile? {
    files.first(where: { $0.kind == .markdown })
  }
}

/// Foundation-only input for assembling a publishing package.
///
/// The workbench facade converts editor and site state into this value.
/// Keeping those models out of the input lets GitCore assemble package data
/// without importing the workbench target.
public struct PublishPackageBuildInput: Hashable, Sendable {
  public struct Markdown: Hashable, Sendable {
    public let repositoryPath: String
    public let content: String
    public let expectedRemoteSHA: String?
    public let expectedContentSHA256: String?
    public let expectedGitBlobSHA: String?

    public init(
      repositoryPath: String,
      content: String,
      expectedRemoteSHA: String? = nil,
      expectedContentSHA256: String? = nil,
      expectedGitBlobSHA: String? = nil
    ) {
      self.repositoryPath = repositoryPath
      self.content = content
      self.expectedRemoteSHA = expectedRemoteSHA
      self.expectedContentSHA256 = expectedContentSHA256
      self.expectedGitBlobSHA = expectedGitBlobSHA
    }
  }

  public struct Attachment: Hashable, Sendable {
    public let kind: PublishFileKind
    public let repositoryPath: String
    public let sourceFilePath: String?
    public let byteSize: Int64
    public let expectedRemoteSHA: String?
    public let expectedContentSHA256: String?
    public let expectedGitBlobSHA: String?

    public init(
      kind: PublishFileKind,
      repositoryPath: String,
      sourceFilePath: String? = nil,
      byteSize: Int64 = 0,
      expectedRemoteSHA: String? = nil,
      expectedContentSHA256: String? = nil,
      expectedGitBlobSHA: String? = nil
    ) {
      self.kind = kind
      self.repositoryPath = repositoryPath
      self.sourceFilePath = sourceFilePath
      self.byteSize = byteSize
      self.expectedRemoteSHA = expectedRemoteSHA
      self.expectedContentSHA256 = expectedContentSHA256
      self.expectedGitBlobSHA = expectedGitBlobSHA
    }
  }

  public struct PreviousMarkdownDeletion: Hashable, Sendable {
    public let repositoryPath: String
    public let expectedRemoteSHA: String?
    public let expectedContentSHA256: String?
    public let expectedGitBlobSHA: String?

    public init(
      repositoryPath: String,
      expectedRemoteSHA: String? = nil,
      expectedContentSHA256: String? = nil,
      expectedGitBlobSHA: String? = nil
    ) {
      self.repositoryPath = repositoryPath
      self.expectedRemoteSHA = expectedRemoteSHA
      self.expectedContentSHA256 = expectedContentSHA256
      self.expectedGitBlobSHA = expectedGitBlobSHA
    }
  }

  public let draftID: UUID
  public let title: String
  public let draftSummary: String?
  public let draftCoverAltText: String?
  public let markdown: Markdown
  public let attachments: [Attachment]
  public let previousMarkdownDeletion: PreviousMarkdownDeletion?
  public let publicationDate: Date
  public let reviewSlug: String
  public let builtAt: Date

  public init(
    draftID: UUID,
    title: String,
    draftSummary: String? = nil,
    draftCoverAltText: String? = nil,
    markdown: Markdown,
    attachments: [Attachment] = [],
    previousMarkdownDeletion: PreviousMarkdownDeletion? = nil,
    publicationDate: Date,
    reviewSlug: String,
    builtAt: Date = Date()
  ) {
    self.draftID = draftID
    self.title = title
    self.draftSummary = draftSummary
    self.draftCoverAltText = draftCoverAltText
    self.markdown = markdown
    self.attachments = attachments
    self.previousMarkdownDeletion = previousMarkdownDeletion
    self.publicationDate = publicationDate
    self.reviewSlug = reviewSlug
    self.builtAt = builtAt
  }
}
