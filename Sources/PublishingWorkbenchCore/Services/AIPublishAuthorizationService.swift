import CryptoKit
import Foundation

@MainActor
public enum AIPublishAuthorizationService {
  public static let defaultValidityInterval: TimeInterval = 10 * 60

  public static func prepare(
    in store: WorkbenchStore,
    now: Date = Date(),
    validityInterval: TimeInterval = defaultValidityInterval
  ) async throws -> AIPublishAuthorizationSnapshot {
    await store.refreshBatchPublishPlanAsync()
    guard let plan = store.batchPublishPlan else {
      throw AIPublishAuthorizationError.unavailable(
        CoreL10n.text("没有可生成授权快照的批量发布计划。")
      )
    }
    let profile = store.activeProfile
    guard plan.profileID == profile.id,
      let package = store.remotePublishPackage(for: plan)
    else {
      throw AIPublishAuthorizationError.unavailable(
        CoreL10n.text("当前站点没有可线上发布的文件。")
      )
    }
    let mode = store.preferredRemoteRepositoryPublishMode(for: profile)
    let preview = store.remoteRepositoryPublishPreview(
      package: package,
      profile: profile,
      mode: mode,
      extraWarningIssues: store.batchRemoteRepositoryPublishWarningIssues(for: plan)
    )
    let scope = try makeScope(
      package: package,
      preview: preview,
      profile: profile,
      repositoryReport: store.repositoryReport(for: profile)
    )
    guard !scope.changedPaths.isEmpty, !scope.files.isEmpty else {
      throw AIPublishAuthorizationError.unavailable(
        CoreL10n.text("当前发布预览没有可授权的文件变化。")
      )
    }
    let boundedValidity = max(1, validityInterval)
    return AIPublishAuthorizationSnapshot(
      generatedAt: now,
      expiresAt: now.addingTimeInterval(boundedValidity),
      scope: scope
    )
  }

  public static func validate(
    _ authorization: AIPublishAuthorizationSnapshot,
    package: PublishPackage,
    preview: RemoteRepositoryPublishPreview,
    profile: SiteProfile,
    repositoryReport: RepositoryScanReport?,
    now: Date = Date()
  ) throws {
    guard authorization.schemaVersion == AIPublishAuthorizationSnapshot.currentSchemaVersion else {
      throw AIPublishAuthorizationError.invalidVersion
    }
    guard now >= authorization.generatedAt,
      now < authorization.expiresAt
    else {
      throw AIPublishAuthorizationError.expired
    }
    let current: AIPublishAuthorizationScope
    do {
      current = try makeScope(
        package: package,
        preview: preview,
        profile: profile,
        repositoryReport: repositoryReport
      )
    } catch {
      throw AIPublishAuthorizationError.changed(
        CoreL10n.format("执行前无法重新读取完整发布范围（%@）", error.localizedDescription)
      )
    }
    if let reason = changeReason(authorized: authorization.scope, current: current) {
      throw AIPublishAuthorizationError.changed(reason)
    }
  }

  public static func validateTarget(
    _ authorization: AIPublishAuthorizationSnapshot,
    profile: SiteProfile,
    now: Date = Date()
  ) throws {
    guard authorization.schemaVersion == AIPublishAuthorizationSnapshot.currentSchemaVersion else {
      throw AIPublishAuthorizationError.invalidVersion
    }
    guard now >= authorization.generatedAt,
      now < authorization.expiresAt
    else {
      throw AIPublishAuthorizationError.expired
    }
    let scope = authorization.scope
    guard scope.profileID == profile.id,
      scope.siteName == profile.name.trimmedForPublishing
    else {
      throw AIPublishAuthorizationError.changed(CoreL10n.text("发布站点已变化"))
    }
    let currentRepositoryIdentity = identityDigest(
      components: [
        profile.repositoryProvider.rawValue,
        profile.repositoryBaseURL.trimmedForPublishing,
        profile.repoOwner.trimmedForPublishing,
        profile.repoName.trimmedForPublishing,
      ]
    )
    guard scope.repositoryProvider == profile.repositoryProvider.rawValue,
      scope.repositoryDisplayName == profile.repositoryDisplayName,
      scope.repositoryIdentitySHA256 == currentRepositoryIdentity
    else {
      throw AIPublishAuthorizationError.changed(CoreL10n.text("发布目的地已变化"))
    }
    let currentMode =
      profile.repositoryPublishStrategy == .direct
      ? RemoteRepositoryPublishMode.directCommit
      : RemoteRepositoryPublishMode.reviewRequest
    guard scope.targetBranch == profile.branch.trimmedForPublishing else {
      throw AIPublishAuthorizationError.changed(CoreL10n.text("发布分支已变化"))
    }
    guard scope.publishStrategy == profile.repositoryPublishStrategy.rawValue,
      scope.publishMode == currentMode.rawValue
    else {
      throw AIPublishAuthorizationError.changed(CoreL10n.text("发布模式或策略已变化"))
    }
  }

  public static func makeScope(
    package: PublishPackage,
    preview: RemoteRepositoryPublishPreview,
    profile: SiteProfile,
    repositoryReport: RepositoryScanReport?
  ) throws -> AIPublishAuthorizationScope {
    let files = try fileSnapshots(for: package.files)
    let gitIdentity = try localGitIdentity(
      profile: profile,
      repositoryReport: repositoryReport
    )
    return AIPublishAuthorizationScope(
      profileID: profile.id,
      siteName: profile.name.trimmedForPublishing,
      repositoryProvider: profile.repositoryProvider.rawValue,
      repositoryDisplayName: profile.repositoryDisplayName,
      repositoryIdentitySHA256: identityDigest(
        components: [
          profile.repositoryProvider.rawValue,
          profile.repositoryBaseURL.trimmedForPublishing,
          profile.repoOwner.trimmedForPublishing,
          profile.repoName.trimmedForPublishing,
        ]
      ),
      targetBranch: profile.branch.trimmedForPublishing,
      publishMode: preview.mode.rawValue,
      publishStrategy: profile.repositoryPublishStrategy.rawValue,
      localRepositoryIdentitySHA256: gitIdentity.rootPath.map {
        identityDigest(components: [$0])
      },
      localBranchName: gitIdentity.branchName,
      localUpstreamName: gitIdentity.upstreamName,
      localIsDetached: gitIdentity.isDetached,
      localGitHeadSHA: gitIdentity.headSHA,
      changedPaths: stablePaths(preview.changedPaths),
      files: files
    )
  }

  private static func fileSnapshots(
    for files: [PublishPackageFile]
  ) throws -> [AIPublishAuthorizationFileSnapshot] {
    var result: [AIPublishAuthorizationFileSnapshot] = []
    var seenPaths = Set<String>()
    for file in files {
      let path = file.repositoryPath.normalizedRelativePath()
      guard !path.isEmpty, seenPaths.insert(path).inserted else {
        throw AIPublishAuthorizationError.unavailable(
          CoreL10n.format("发布文件路径为空或重复：%@。", file.repositoryPath)
        )
      }
      let digest = try contentDigest(for: file)
      result.append(
        AIPublishAuthorizationFileSnapshot(
          path: path,
          kind: file.kind.rawValue,
          operation: file.operation.rawValue,
          contentSHA256: digest,
          expectedRemoteSHA: file.expectedRemoteSHA?.trimmedForPublishing.nilIfEmpty
        )
      )
    }
    return result.sorted { $0.path < $1.path }
  }

  private static func contentDigest(for file: PublishPackageFile) throws -> String {
    let digest: Data
    if file.operation == .delete {
      digest = Data(SHA256.hash(data: Data()))
    } else {
      switch file.kind {
      case .markdown:
        guard let content = file.content,
          let data = content.data(using: .utf8)
        else {
          throw AIPublishAuthorizationError.unavailable(
            CoreL10n.format("无法读取发布文件内容：%@。", file.repositoryPath)
          )
        }
        digest = Data(SHA256.hash(data: data))
      case .image, .video:
        guard let sourcePath = file.sourceFilePath?.trimmedForPublishing.nilIfEmpty else {
          throw AIPublishAuthorizationError.unavailable(
            CoreL10n.format("发布文件缺少可读取的源文件：%@。", file.repositoryPath)
          )
        }
        do {
          digest = try BoundedFileReader.sha256(
            at: URL(fileURLWithPath: sourcePath),
            maximumByteCount: WorkbenchFileReadLimits.maximumRemoteMediaUploadByteCount
          )
        } catch {
          throw AIPublishAuthorizationError.unavailable(
            CoreL10n.format(
              "无法为发布文件生成内容摘要：%@（%@）。", file.repositoryPath, error.localizedDescription)
          )
        }
      }
    }
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func localGitIdentity(
    profile: SiteProfile,
    repositoryReport: RepositoryScanReport?
  ) throws -> LocalGitIdentity {
    guard
      let identity = try profile.withLocalRepositoryRootAccess({ rootURL -> LocalGitIdentity in
        let standardizedRoot = rootURL.standardizedFileURL.path
        let runner = GitCommandRunner()
        let headResult = runner.run(["rev-parse", "--verify", "HEAD"], rootURL: rootURL)
        let branchResult = runner.run(
          ["symbolic-ref", "--quiet", "--short", "HEAD"], rootURL: rootURL)
        let upstreamResult = runner.run(
          ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
          rootURL: rootURL
        )
        let headSHA =
          headResult.terminationStatus == 0
          ? headResult.standardOutput.trimmedForPublishing.nilIfEmpty
          : nil
        let branchName =
          branchResult.terminationStatus == 0
          ? branchResult.standardOutput.trimmedForPublishing.nilIfEmpty
          : nil
        let upstreamName =
          upstreamResult.terminationStatus == 0
          ? upstreamResult.standardOutput.trimmedForPublishing.nilIfEmpty
          : nil
        let matchingReport = repositoryReport?.rootPath == standardizedRoot ? repositoryReport : nil
        if matchingReport?.hasGitDirectory == true, headSHA == nil {
          throw AIPublishAuthorizationError.unavailable(
            CoreL10n.text("无法读取当前 Git 基线，未生成线上发布授权。")
          )
        }
        return LocalGitIdentity(
          rootPath: standardizedRoot,
          branchName: branchName ?? matchingReport?.branchStatus?.branchName,
          upstreamName: upstreamName ?? matchingReport?.branchStatus?.upstreamName,
          isDetached: branchName == nil && headSHA != nil
            ? true
            : (matchingReport?.branchStatus?.isDetached ?? false),
          headSHA: headSHA
        )
      })
    else {
      return LocalGitIdentity(
        rootPath: nil,
        branchName: repositoryReport?.branchStatus?.branchName,
        upstreamName: repositoryReport?.branchStatus?.upstreamName,
        isDetached: repositoryReport?.branchStatus?.isDetached ?? false,
        headSHA: nil
      )
    }
    return identity
  }

  private static func stablePaths(_ paths: [String]) -> [String] {
    Array(Set(paths.map { $0.normalizedRelativePath() }.filter { !$0.isEmpty })).sorted()
  }

  private static func identityDigest(components: [String]) -> String {
    let data = components.joined(separator: "\u{0}").data(using: .utf8) ?? Data()
    return Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
  }

  private static func changeReason(
    authorized: AIPublishAuthorizationScope,
    current: AIPublishAuthorizationScope
  ) -> String? {
    guard authorized.profileID == current.profileID,
      authorized.siteName == current.siteName
    else {
      return CoreL10n.text("发布站点已变化")
    }
    guard authorized.repositoryProvider == current.repositoryProvider,
      authorized.repositoryDisplayName == current.repositoryDisplayName,
      authorized.repositoryIdentitySHA256 == current.repositoryIdentitySHA256
    else {
      return CoreL10n.text("发布目的地已变化")
    }
    guard authorized.targetBranch == current.targetBranch else {
      return CoreL10n.text("发布分支已变化")
    }
    guard authorized.publishMode == current.publishMode,
      authorized.publishStrategy == current.publishStrategy
    else {
      return CoreL10n.text("发布模式或策略已变化")
    }
    guard authorized.localRepositoryIdentitySHA256 == current.localRepositoryIdentitySHA256,
      authorized.localBranchName == current.localBranchName,
      authorized.localUpstreamName == current.localUpstreamName,
      authorized.localIsDetached == current.localIsDetached,
      authorized.localGitHeadSHA == current.localGitHeadSHA
    else {
      return CoreL10n.text("当前 Git 分支或基线已变化")
    }
    guard authorized.changedPaths == current.changedPaths else {
      return CoreL10n.text("待发布变化路径集合已变化")
    }
    guard authorized.files.map(\.path) == current.files.map(\.path) else {
      return CoreL10n.text("发布文件范围已变化")
    }
    guard authorized.files == current.files else {
      return CoreL10n.text("发布文件内容或远程基线已变化")
    }
    return nil
  }

  private struct LocalGitIdentity {
    var rootPath: String?
    var branchName: String?
    var upstreamName: String?
    var isDetached: Bool
    var headSHA: String?
  }
}
