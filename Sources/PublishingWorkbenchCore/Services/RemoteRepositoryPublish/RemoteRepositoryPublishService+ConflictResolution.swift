import CryptoKit
import Foundation
import PublishingGitCore

extension RemoteRepositoryPublishService {
  public func conflictResolutionSession(
    package: PublishPackage,
    profile: SiteProfile,
    token: String?
  ) async throws -> RemoteRepositoryConflictSession {
    let inspection = try await preflightInspection(
      package: package,
      profile: profile,
      token: token
    )
    return try await conflictResolutionSession(
      inspection: inspection,
      profile: profile,
      token: token
    )
  }

  func conflictResolutionSession(
    inspection: RemoteRepositoryPreflightInspection,
    profile: SiteProfile,
    token: String?
  ) async throws -> RemoteRepositoryConflictSession {
    let resolvedToken = try requiredToken(token)
    let repository = try remoteRepository(from: profile)
    let filesByPath = Dictionary(
      inspection.package.files.map {
        ($0.repositoryPath.normalizedRelativePath(), $0)
      },
      uniquingKeysWith: { first, _ in first }
    )
    var items: [RemoteRepositoryConflictItem] = []

    for conflict in inspection.result.conflicts.prefix(
      RepositoryMergeConflictPolicy.maximumConflictCount
    ) {
      guard let file = filesByPath[conflict.repositoryPath] else { continue }
      let snapshot = inspection.snapshotsByPath[conflict.repositoryPath]
      let observedVersion = snapshot?.version?.trimmedForPublishing.nilIfEmpty
      guard observedVersion == conflict.actualSHA?.trimmedForPublishing.nilIfEmpty else {
        continue
      }

      let base: RepositoryMergeConflictContent
      if let expectedSHA = conflict.expectedSHA {
        do {
          switch profile.repositoryProvider {
          case .github:
            let data = try await githubBlobContent(
              repository: repository,
              sha: expectedSHA,
              token: resolvedToken
            )
            base = boundedConflictContent(
              data,
              exists: data != nil,
              fileKind: file.kind,
              missingMessage: CoreL10n.text("远端基线文件已不存在。")
            )
          case .gitlab:
            let state = try await gitLabFileState(
              repository: repository,
              path: conflict.repositoryPath,
              ref: expectedSHA,
              token: resolvedToken
            )
            base = boundedConflictContent(
              state.content,
              exists: state.exists,
              fileKind: file.kind,
              missingMessage: CoreL10n.text("远端基线文件已不存在。")
            )
          }
        } catch {
          base = .diagnostic(
            .unavailable,
            message: CoreL10n.format("无法读取远端基线：%@", error.localizedDescription)
          )
        }
      } else {
        base = .missing(CoreL10n.text("本地草稿没有记录远端基线。"))
      }

      items.append(
        RemoteRepositoryConflictItem(
          repositoryPath: conflict.repositoryPath,
          fileKind: file.kind,
          operation: file.operation,
          expectedSHA: conflict.expectedSHA,
          actualSHA: conflict.actualSHA,
          base: base,
          local: localConflictContent(for: file),
          remote: boundedConflictContent(
            snapshot?.content,
            exists: snapshot?.exists == true,
            fileKind: file.kind,
            missingMessage: CoreL10n.text("远端当前版本不存在此文件。")
          )
        )
      )
    }

    return RemoteRepositoryConflictSession(
      profileID: profile.id,
      repositoryIdentity: DraftRepositoryIdentity(profile: profile),
      packageFingerprint: conflictPackageFingerprint(
        package: inspection.package,
        profile: profile
      ),
      conflicts: items
    )
  }

  func conflictPackageFingerprint(
    package: PublishPackage,
    profile: SiteProfile
  ) -> String {
    var records = [
      profile.id.uuidString,
      profile.repositoryProvider.rawValue,
      profile.repositoryBaseURL.trimmedForPublishing.lowercased(),
      profile.repositoryDisplayName,
      profile.branch.trimmedForPublishing,
    ]
    records.append(
      contentsOf: package.files
        .map { file in
          let contentDigest =
            file.content.map { value in
              SHA256.hash(data: Data(value.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            } ?? ""
          return [
            file.repositoryPath.normalizedRelativePath(),
            file.kind.rawValue,
            file.operation.rawValue,
            file.expectedRemoteSHA ?? "",
            contentDigest,
            file.sourceFilePath ?? "",
            String(file.byteSize),
          ].joined(separator: "\u{1f}")
        }
        .sorted()
    )
    let payload = records.joined(separator: "\u{1e}")
    return SHA256.hash(data: Data(payload.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private func localConflictContent(
    for file: PublishPackageFile
  ) -> RepositoryMergeConflictContent {
    guard file.operation == .upsert else {
      return .missing(CoreL10n.text("本次发布计划将删除此文件。"))
    }
    guard file.kind == .markdown else {
      return .diagnostic(
        .binary,
        byteCount: Int(clamping: file.byteSize),
        message: CoreL10n.text("媒体文件不能在文本冲突面板中合并。")
      )
    }
    return boundedConflictContent(
      file.content.map { Data($0.utf8) },
      exists: file.content != nil,
      fileKind: file.kind,
      missingMessage: CoreL10n.text("本地发布包没有可编辑文本。")
    )
  }

  private func boundedConflictContent(
    _ data: Data?,
    exists: Bool,
    fileKind: PublishFileKind,
    missingMessage: String
  ) -> RepositoryMergeConflictContent {
    guard exists else { return .missing(missingMessage) }
    guard fileKind == .markdown else {
      return .diagnostic(
        .binary,
        byteCount: data?.count ?? 0,
        message: CoreL10n.text("媒体文件不能在文本冲突面板中合并。")
      )
    }
    guard let data else {
      return .diagnostic(
        .unavailable,
        message: CoreL10n.text("提供商没有返回可读取的文件正文。")
      )
    }
    guard data.count <= RepositoryMergeConflictPolicy.maximumTextByteCount else {
      return .diagnostic(
        .tooLarge,
        byteCount: data.count,
        message: CoreL10n.format(
          "文件超过可视化合并上限（%lld KB）。",
          RepositoryMergeConflictPolicy.maximumTextByteCount / 1_024
        )
      )
    }
    guard !data.contains(0) else {
      return .diagnostic(
        .binary,
        byteCount: data.count,
        message: CoreL10n.text("文件包含二进制数据，不能作为文本合并。")
      )
    }
    guard let text = String(data: data, encoding: .utf8) else {
      return .diagnostic(
        .undecodable,
        byteCount: data.count,
        message: CoreL10n.text("文件不是有效的 UTF-8 文本。")
      )
    }
    return .text(text, byteCount: data.count)
  }
}
