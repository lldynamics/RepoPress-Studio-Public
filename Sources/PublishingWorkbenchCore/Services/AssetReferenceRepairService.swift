import Foundation

public struct AssetReferenceRepairPreview: Hashable, Sendable, Identifiable {
  public let id: UUID
  public let draftID: UUID
  public let profileID: UUID
  public let repositoryRootPath: String
  public let assetRootPath: String
  public let sourcePath: String
  public let lineNumber: Int
  public let oldPath: String
  public let newPath: String
  public let replacementRepositoryPath: String
  public let expectedBodyMarkdown: String
  public let expectedDraftUpdatedAt: Date
  /// Disk baseline captured from the draft's last successful autosave. The
  /// SiteDraftFileStore revalidates this baseline immediately before writing.
  public let expectedProjectFileContentDigest: String
  public let tokenUTF16Location: Int
  public let tokenUTF16Length: Int

  public init(
    id: UUID = UUID(), draft: ArticleDraft, reference: AssetResourceBrokenReference,
    replacementPath: String,
    replacementRepositoryPath: String,
    report: AssetResourceScanReport
  ) {
    self.id = id
    draftID = draft.id
    profileID = report.profileID
    repositoryRootPath = report.repositoryRootPath
    assetRootPath = report.assetRootPath
    sourcePath = reference.sourceMarkdownPath
    lineNumber = reference.lineNumber
    oldPath = reference.rawPath
    newPath = replacementPath
    self.replacementRepositoryPath = replacementRepositoryPath
    expectedBodyMarkdown = draft.bodyMarkdown
    expectedDraftUpdatedAt = draft.updatedAt
    expectedProjectFileContentDigest = draft.repositoryBinding?.projectFileContentDigest ?? ""
    tokenUTF16Location = reference.tokenUTF16Location
    tokenUTF16Length = reference.tokenUTF16Length
  }
}

/// An exact body-token selection for a repository-backed draft. This is used
/// only for navigation; the repair path still revalidates its own preview.
public struct AssetReferenceRepairEditorLocation: Hashable, Sendable {
  public let draftID: UUID
  public let tokenUTF16Location: Int
  public let tokenUTF16Length: Int

  public init(draftID: UUID, tokenUTF16Location: Int, tokenUTF16Length: Int) {
    self.draftID = draftID
    self.tokenUTF16Location = tokenUTF16Location
    self.tokenUTF16Length = tokenUTF16Length
  }

  public var selectedRange: NSRange {
    NSRange(location: tokenUTF16Location, length: tokenUTF16Length)
  }
}

public enum AssetReferenceRepairError: LocalizedError, Equatable {
  case unavailableDraft
  case stalePreview
  case invalidToken
  case unsafeReplacement
  case recoveryUnavailable

  public var errorDescription: String? {
    switch self {
    case .recoveryUnavailable: CoreL10n.text("恢复版本尚未完整保存，未应用替换；请减少选择数量或检查存储。")
    case .unavailableDraft: CoreL10n.text("该引用未对应到可安全修改的工作区草稿。")
    case .stalePreview: CoreL10n.text("文章或编辑缓冲已变化，请重新扫描并预览。")
    case .invalidToken: CoreL10n.text("原引用位置已变化，已拒绝替换。")
    case .unsafeReplacement: CoreL10n.text("替换资源不再位于当前站点资源目录中。")
    }
  }
}

public struct AssetReferenceRepairService: Sendable {
  public init() {}

  public func makePreview(
    reference: AssetResourceBrokenReference,
    replacement: AssetResourceItem,
    report: AssetResourceScanReport,
    drafts: [ArticleDraft]
  ) throws -> AssetReferenceRepairPreview {
    guard
      let draft = drafts.first(where: {
        $0.siteProfileID == report.profileID
          && $0.repositoryPath?.normalizedRelativePath()
            == reference.sourceMarkdownPath.normalizedRelativePath()
          && !$0.isGeneralDraft
      }), let baseline = draft.repositoryBinding?.projectFileContentDigest?.nilIfEmpty
    else { throw AssetReferenceRepairError.unavailableDraft }
    let sourceURL = try sourceURL(for: reference.sourceMarkdownPath, report: report)
    let sourceText = try String(contentsOf: sourceURL, encoding: .utf8)
    guard ArticleDraft.repositoryDocumentDigest(sourceText) == baseline else {
      throw AssetReferenceRepairError.stalePreview
    }
    let bodyRange = (sourceText as NSString).range(of: draft.bodyMarkdown, options: .backwards)
    guard bodyRange.location != NSNotFound,
      reference.tokenUTF16Location >= bodyRange.location,
      NSMaxRange(
        NSRange(location: reference.tokenUTF16Location, length: reference.tokenUTF16Length))
        <= NSMaxRange(bodyRange)
    else { throw AssetReferenceRepairError.invalidToken }
    try validate(replacement: replacement, report: report)
    let replacementPath = try renderedPath(
      replacement.repositoryPath, oldPath: reference.rawPath,
      sourcePath: reference.sourceMarkdownPath,
      assetRoot: report.assetRootPath
    )
    let preview = AssetReferenceRepairPreview(
      draft: draft,
      reference: AssetResourceBrokenReference(
        sourceMarkdownPath: reference.sourceMarkdownPath, lineNumber: reference.lineNumber,
        rawPath: reference.rawPath,
        tokenUTF16Location: reference.tokenUTF16Location - bodyRange.location,
        tokenUTF16Length: reference.tokenUTF16Length, kind: reference.kind,
        message: reference.message
      ), replacementPath: replacementPath,
      replacementRepositoryPath: replacement.repositoryPath.normalizedRelativePath(),
      report: report
    )
    _ = try applying(preview, to: draft)
    return preview
  }

  /// Resolves a scan token to the matching imported draft and its body range.
  /// It rejects a stale disk baseline so navigation cannot select an unrelated
  /// occurrence after an external edit or a site switch.
  public func editorLocation(
    for reference: AssetResourceBrokenReference,
    report: AssetResourceScanReport,
    drafts: [ArticleDraft]
  ) throws -> AssetReferenceRepairEditorLocation {
    guard let draft = matchingDraft(for: reference, report: report, drafts: drafts),
      let baseline = draft.repositoryBinding?.projectFileContentDigest?.nilIfEmpty
    else { throw AssetReferenceRepairError.unavailableDraft }
    let sourceText = try String(
      contentsOf: sourceURL(for: reference.sourceMarkdownPath, report: report), encoding: .utf8)
    guard ArticleDraft.repositoryDocumentDigest(sourceText) == baseline else {
      throw AssetReferenceRepairError.stalePreview
    }
    let bodyRange = (sourceText as NSString).range(of: draft.bodyMarkdown, options: .backwards)
    let fullRange = NSRange(
      location: reference.tokenUTF16Location, length: reference.tokenUTF16Length)
    guard bodyRange.location != NSNotFound,
      fullRange.location >= bodyRange.location,
      NSMaxRange(fullRange) <= NSMaxRange(bodyRange)
    else { throw AssetReferenceRepairError.invalidToken }
    let bodyRangeToken = NSRange(
      location: fullRange.location - bodyRange.location,
      length: fullRange.length
    )
    let body = draft.bodyMarkdown as NSString
    guard NSMaxRange(bodyRangeToken) <= body.length,
      body.substring(with: bodyRangeToken) == reference.rawPath,
      !MarkdownCodeRangeScanner.scan(draft.bodyMarkdown).allRanges.contains(where: {
        NSIntersectionRange($0, bodyRangeToken).length > 0
      })
    else { throw AssetReferenceRepairError.invalidToken }
    return AssetReferenceRepairEditorLocation(
      draftID: draft.id,
      tokenUTF16Location: bodyRangeToken.location,
      tokenUTF16Length: bodyRangeToken.length
    )
  }

  /// Returns a regular, non-symlink source file that remains inside the
  /// scanned repository. Callers may use it only for a user-triggered open or
  /// Finder reveal when the file is not an imported draft.
  public func sourceURL(for path: String, report: AssetResourceScanReport) throws -> URL {
    let root = URL(fileURLWithPath: report.repositoryRootPath).resolvingSymlinksInPath()
    let source = root.appendingPathComponent(path).resolvingSymlinksInPath()
    let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard source.path.hasPrefix(root.path + "/"), values?.isRegularFile == true,
      values?.isSymbolicLink != true
    else { throw AssetReferenceRepairError.stalePreview }
    return source
  }

  public func applying(_ preview: AssetReferenceRepairPreview, to draft: ArticleDraft) throws
    -> ArticleDraft
  {
    guard draft.id == preview.draftID, draft.siteProfileID == preview.profileID,
      !draft.isGeneralDraft,
      draft.repositoryPath?.normalizedRelativePath() == preview.sourcePath.normalizedRelativePath(),
      draft.repositoryBinding?.projectFileContentDigest == preview.expectedProjectFileContentDigest,
      draft.updatedAt == preview.expectedDraftUpdatedAt,
      draft.bodyMarkdown == preview.expectedBodyMarkdown
    else { throw AssetReferenceRepairError.stalePreview }
    let range = NSRange(location: preview.tokenUTF16Location, length: preview.tokenUTF16Length)
    let source = draft.bodyMarkdown as NSString
    guard range.location != NSNotFound, NSMaxRange(range) <= source.length,
      source.substring(with: range) == preview.oldPath,
      !MarkdownCodeRangeScanner.scan(draft.bodyMarkdown).allRanges.contains(where: {
        NSIntersectionRange($0, range).length > 0
      })
    else { throw AssetReferenceRepairError.invalidToken }
    var updated = draft
    updated.bodyMarkdown = source.replacingCharacters(in: range, with: preview.newPath)
    return updated
  }

  public func validate(replacement: AssetResourceItem, report: AssetResourceScanReport) throws {
    let root = URL(fileURLWithPath: report.repositoryRootPath).resolvingSymlinksInPath()
    let assetRoot = root.appendingPathComponent(report.assetRootPath).resolvingSymlinksInPath()
    let item = URL(fileURLWithPath: replacement.absoluteFilePath).resolvingSymlinksInPath()
    let expected = root.appendingPathComponent(replacement.repositoryPath).resolvingSymlinksInPath()
    let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard item.path == expected.path, values?.isRegularFile == true, values?.isSymbolicLink != true,
      item.path.hasPrefix(root.path + "/"), item.path.hasPrefix(assetRoot.path + "/"),
      replacement.repositoryPath.normalizedRelativePath().hasPrefix(
        report.assetRootPath.normalizedRelativePath() + "/")
    else { throw AssetReferenceRepairError.unsafeReplacement }
  }

  public func validatePreviewDiskBaseline(
    _ preview: AssetReferenceRepairPreview, report: AssetResourceScanReport
  ) throws {
    guard preview.profileID == report.profileID,
      preview.repositoryRootPath == report.repositoryRootPath,
      preview.assetRootPath == report.assetRootPath
    else { throw AssetReferenceRepairError.stalePreview }
    let source = try sourceURL(for: preview.sourcePath, report: report)
    let text = try String(contentsOf: source, encoding: .utf8)
    guard ArticleDraft.repositoryDocumentDigest(text) == preview.expectedProjectFileContentDigest
    else {
      throw AssetReferenceRepairError.stalePreview
    }
  }

  private func matchingDraft(
    for reference: AssetResourceBrokenReference,
    report: AssetResourceScanReport,
    drafts: [ArticleDraft]
  ) -> ArticleDraft? {
    drafts.first {
      $0.siteProfileID == report.profileID
        && $0.repositoryPath?.normalizedRelativePath()
          == reference.sourceMarkdownPath.normalizedRelativePath()
        && !$0.isGeneralDraft
    }
  }

  private func renderedPath(
    _ replacement: String, oldPath: String, sourcePath: String, assetRoot: String
  ) throws -> String {
    let normalized = replacement.normalizedRelativePath()
    let suffix =
      oldPath.firstIndex(where: { $0 == "?" || $0 == "#" }).map { String(oldPath[$0...]) } ?? ""
    guard !oldPath.hasPrefix("/") else {
      let root = assetRoot.normalizedRelativePath() + "/"
      let path = normalized.hasPrefix(root) ? "/" + normalized.dropFirst(root.count) : normalized
      return try encodedReferencePath(String(path)) + suffix
    }
    let sourceDirectory = (sourcePath as NSString).deletingLastPathComponent
    let from = sourceDirectory.split(separator: "/").map(String.init)
    let to = normalized.split(separator: "/").map(String.init)
    var shared = 0
    while shared < min(from.count, to.count), from[shared] == to[shared] { shared += 1 }
    let components =
      Array(repeating: "..", count: from.count - shared) + Array(to.dropFirst(shared))
    return try encodedReferencePath(components.joined(separator: "/")) + suffix
  }

  private func encodedReferencePath(_ path: String) throws -> String {
    // Encode filesystem names once, keeping only path separators and URL
    // unreserved characters. This is safe in bare/angle Markdown destinations
    // and quoted HTML attributes without losing literal %, #, ?, or brackets.
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
    guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else {
      throw AssetReferenceRepairError.unsafeReplacement
    }
    return encoded
  }
}
