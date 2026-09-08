import Foundation

public enum SiteDraftFileFailureReason: String, Codable, Hashable, Sendable {
  case volumeUnavailable, directoryMissing, accessDenied, notRepository, noRepository
  case externalChange, other

  public var title: String {
    switch self {
    case .volumeUnavailable: return CoreL10n.text("项目磁盘不可用")
    case .directoryMissing: return CoreL10n.text("项目目录不存在")
    case .accessDenied: return CoreL10n.text("项目目录访问被拒绝")
    case .notRepository: return CoreL10n.text("所选目录不是 Git 仓库根目录")
    case .noRepository: return CoreL10n.text("尚未选择项目目录")
    case .externalChange: return CoreL10n.text("项目文件已被其他软件或 Git 修改")
    case .other: return CoreL10n.text("项目文件写入失败")
    }
  }

  public var recoverySuggestion: String {
    switch self {
    case .volumeUnavailable:
      return CoreL10n.text("请连接项目磁盘后重新检查，或更改项目目录。")
    case .directoryMissing, .notRepository, .noRepository:
      return CoreL10n.text("请选择包含 .git 的项目根目录后重试。")
    case .accessDenied:
      return CoreL10n.text("请检查目录的访问权限和磁盘是否只读，再重新检查。")
    case .externalChange:
      return CoreL10n.text("请先核对项目文件中的外部修改；重试不会强制覆盖。")
    case .other:
      return CoreL10n.text("请查看详情，修复保存位置或权限后重新检查。")
    }
  }

  init(error: Error) {
    switch error {
    case LocalPublishPreviewError.repositoryVolumeUnavailable: self = .volumeUnavailable
    case LocalPublishPreviewError.repositoryDirectoryMissing: self = .directoryMissing
    case LocalPublishPreviewError.repositoryAccessDenied: self = .accessDenied
    case LocalPublishPreviewError.notGitRepositoryRoot: self = .notRepository
    case LocalPublishPreviewError.missingRepositoryRoot: self = .noRepository
    case SiteDraftFileStoreError.projectFileChangedExternally,
      LocalPublishPreviewError.previewOutdated, LocalPublishPreviewError.sourcePreviewOutdated:
      self = .externalChange
    default:
      let nsError = error as NSError
      if (nsError.domain == NSCocoaErrorDomain
        && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code))
        || (nsError.domain == NSPOSIXErrorDomain
          && [EACCES, EPERM, EROFS].contains(Int32(nsError.code)))
      {
        self = .accessDenied
      } else {
        self = .other
      }
    }
  }
}

/// The profile and root are captured at the failed write, rather than inferred
/// later from whichever site happens to be selected in the UI.
public struct SiteDraftFileSaveFailure: Codable, Equatable, Sendable {
  public let draftID: UUID
  public let profileID: UUID
  public let siteName: String
  public let rootPath: String?
  public let repositoryPath: String
  public let reason: SiteDraftFileFailureReason
  public let message: String

  init(draftID: UUID, profile: SiteProfile, repositoryPath: String, error: Error) {
    self.draftID = draftID
    profileID = profile.id
    siteName = profile.name
    rootPath = profile.localRepositoryRootURL?.path
    self.repositoryPath = repositoryPath
    reason = SiteDraftFileFailureReason(error: error)
    message = error.localizedDescription
  }
}

public struct SiteDraftFileSaveFailureGroup: Equatable, Sendable {
  public let profileID: UUID
  public let siteName: String
  public let rootPath: String?
  public let reason: SiteDraftFileFailureReason
  public let failures: [SiteDraftFileSaveFailure]

  public var summary: String {
    let heading = CoreL10n.format("%@：%d 篇草稿等待写入项目", siteName, failures.count)
    return [
      heading, reason.title, rootPath,
      reason == .other ? failures.first?.message : nil, reason.recoverySuggestion,
    ]
    .compactMap { $0 }.joined(separator: "\n")
  }

  public var details: String {
    summary + "\n\n"
      + failures.map { "\($0.repositoryPath)\n\($0.message)" }
      .joined(separator: "\n\n")
  }

  static func grouped(_ failures: [SiteDraftFileSaveFailure]) -> [Self] {
    struct Key: Hashable {
      let profileID: UUID
      let rootPath: String?
      let reason: SiteDraftFileFailureReason
      let otherMessage: String?
    }
    return Dictionary(grouping: failures) {
      Key(
        profileID: $0.profileID, rootPath: $0.rootPath, reason: $0.reason,
        otherMessage: $0.reason == .other ? $0.message : nil)
    }.values.compactMap { entries in
      guard let first = entries.first else { return nil }
      return Self(
        profileID: first.profileID, siteName: first.siteName,
        rootPath: first.rootPath, reason: first.reason,
        failures: entries.sorted {
          ($0.repositoryPath, $0.draftID.uuidString) < ($1.repositoryPath, $1.draftID.uuidString)
        })
    }.sorted {
      ($0.siteName, $0.profileID.uuidString, $0.rootPath ?? "", $0.reason.rawValue)
        < ($1.siteName, $1.profileID.uuidString, $1.rootPath ?? "", $1.reason.rawValue)
    }
  }
}
