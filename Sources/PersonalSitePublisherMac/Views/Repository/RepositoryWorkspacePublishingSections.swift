import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct RepositoryPermissionActionPresentation: Equatable {
  let title: String
  let help: String
  let isEnabled: Bool

  static func make(
    configuredOwner: String,
    configuredRepository: String,
    detectedOrigin: RepositoryRemote?
  ) -> Self {
    let owner = configuredOwner.trimmedForPublishing
    let repository = configuredRepository.trimmedForPublishing
    if !owner.isEmpty && !repository.isEmpty {
      return Self(
        title: String(localized: "检查权限"),
        help: String(localized: "检查当前配置仓库的写入权限"),
        isEnabled: true
      )
    }
    if let detectedOrigin,
       !detectedOrigin.owner.trimmedForPublishing.isEmpty,
       !detectedOrigin.name.trimmedForPublishing.isEmpty {
      let detectedOwner = detectedOrigin.owner.trimmedForPublishing
      let detectedRepository = detectedOrigin.name.trimmedForPublishing
      let ownerMatches = owner.isEmpty || owner == detectedOwner
      let repositoryMatches = repository.isEmpty || repository == detectedRepository
      guard ownerMatches && repositoryMatches else {
        return Self(
          title: String(localized: "检查权限"),
          help: String(
            localized: "当前仓库配置与扫描到的 origin 不一致，请完成或修正 Owner/Namespace 和 Repo/Project。"
          ),
          isEnabled: false
        )
      }
      let originName = "\(detectedOwner)/\(detectedRepository)"
      return Self(
        title: String(format: String(localized: "使用 %@ 并检查权限"), originName),
        help: String(
          format: String(localized: "使用扫描到的 origin %@ 写入当前站点配置，然后检查仓库写入权限。"),
          originName
        ),
        isEnabled: true
      )
    }
    return Self(
      title: String(localized: "检查权限"),
      help: String(localized: "请先配置仓库 Owner/Namespace 和 Repo/Project，或扫描包含 origin 的站点仓库。"),
      isEnabled: false
    )
  }
}

extension RepositoryWorkspaceView {
  var onlinePublishCenterSection: some View {
    let latestEntry = store.activeProfileReleaseLedger.entries.first
    let permissionAction = repositoryPermissionActionPresentation

    return VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("发布状态")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        Text("此处只显示站点连接和最近结果；发布确认、文件清单与差异审阅统一在“打开发布流程”中完成。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      if let preview = store.remotePublishPreviewSnapshot {
        Label(
          "当前发布状态：\(preview.readiness.localizedDisplayName)",
          systemImage: preview.readiness.systemImage
        )
        .font(.callout)
        .foregroundStyle(preview.readiness == .blocked ? WorkbenchTheme.risk : Color.secondary)

        if !preview.remoteConflictPaths.isEmpty {
          remoteConflictPreview(
            paths: preview.remoteConflictPaths,
            isDirectCommit: preview.mode == .directCommit
          )
        }
      } else {
        Label(
          store.selectedDraft == nil
            ? String(localized: "选择文章后可打开统一发布流程。")
            : String(localized: "打开统一发布流程后会生成最新发布检查。"),
          systemImage: store.selectedDraft == nil ? "doc.badge.questionmark" : "paperplane"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)],
        alignment: .leading,
        spacing: 10
      ) {
        Button {
          checkRepositoryPermission()
        } label: {
          Label(permissionAction.title, systemImage: "person.badge.key")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(
          !permissionAction.isEnabled
            || store.isRemoteRepositoryChecking
            || store.isRemoteRepositoryPublishing
        )
        .help(permissionAction.help)
        .accessibilityIdentifier("repository-action-check-permission")
        .accessibilityLabel(permissionAction.title)
        .accessibilityHint(permissionAction.help)

        Button {
          createsPrivateRepository = true
          repositoryCreationFailureMessage = nil
          isRepositoryCreationConfirmationPresented = true
        } label: {
          Label("创建仓库", systemImage: "plus.circle")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(store.isRemoteRepositoryChecking || store.isRemoteRepositoryPublishing)
        .accessibilityIdentifier("repository-action-create-remote")

      }
      .controlSize(.regular)

      if store.isRemoteRepositoryChecking || store.isRemoteRepositoryPublishing {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(
            store.isRemoteRepositoryPublishing
              ? String(localized: "正在执行线上发布...")
              : String(localized: "正在检查仓库权限...")
          )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      if let result = store.remoteRepositoryPublishResult {
        remotePublishResultCard(result)
      }

      if let creation = store.remoteRepositoryCreationResult {
        remoteRepositoryCreationResultCard(creation)
      }

      if let latestEntry {
        Label("最近记录：\(latestEntry.status.localizedDisplayName)", systemImage: latestEntry.status.systemImage)
          .font(.callout)
          .foregroundStyle(ledgerStatusForeground(latestEntry.status))
      }
    }
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-section-online-publish")
  }

  private var repositoryPermissionActionPresentation: RepositoryPermissionActionPresentation {
    RepositoryPermissionActionPresentation.make(
      configuredOwner: store.activeProfile.repoOwner,
      configuredRepository: store.activeProfile.repoName,
      detectedOrigin: store.repositoryReport?.originRemote
    )
  }

  private func checkRepositoryPermission() {
    Task {
      await store.checkRepositoryTokenAccess()
    }
  }

  @ViewBuilder
  var repositorySyncPlan: some View {
    if let plan = store.repositorySyncCommandPlan {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text("同步建议")
              .font(.headline)
              .accessibilityAddTraits(.isHeader)
            Text(plan.title)
              .font(.callout.weight(.medium))
          }
          Spacer()
          Button {
            copy(plan.commandText, message: "已复制同步建议命令。")
          } label: {
            Label("复制命令", systemImage: "terminal")
          }
        }

        Text(plan.summary)
          .font(.callout)
          .foregroundStyle(.secondary)

        Text(plan.commandText)
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .lineLimit(8)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))

        ForEach(plan.notes, id: \.self) { note in
          Label(note, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("repository-section-sync-plan")
    }
  }

  var pathRules: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("路径规则")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      repositoryPathRule(title: "内容目录", value: store.activeProfile.contentRoot)
      repositoryPathRule(title: "图片目录", value: store.activeProfile.assetRoot)
      repositoryPathRule(
        title: "文章路径",
        value: store.selectedDraft.map { store.activeProfile.markdownPath(for: $0) } ?? "-"
      )
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-section-path-rules")
  }

  private func repositoryPathRule(title: LocalizedStringKey, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .workbenchTruncatedIdentity(value, lineLimit: 2)
    }
  }

  func remotePublishResultCard(_ result: RemoteRepositoryPublishResult) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Label("线上发布结果", systemImage: "checkmark.seal")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          copy(result.clipboardSummary, message: "已复制线上发布结果。")
        } label: {
          Label("复制结果", systemImage: "doc.on.doc")
        }
        if let reviewURL = result.reviewURL, let url = URL(string: reviewURL) {
          Button {
            ExternalURLOpener.open(url)
          } label: {
            Label("打开 PR/MR", systemImage: "arrow.up.right.square")
          }
        }
      }

      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
        GridRow {
          Text("方式").foregroundStyle(.secondary)
          Text(result.displayTitle)
        }
        GridRow {
          Text("分支").foregroundStyle(.secondary)
          Text(result.branchSummary)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        if let repositoryName = result.repositoryName {
          GridRow {
            Text("仓库").foregroundStyle(.secondary)
            Text(repositoryName)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        }
        if let commitSHA = result.commitSHA {
          GridRow {
            Text("Commit").foregroundStyle(.secondary)
            HStack(spacing: 8) {
              Text(result.shortCommitSHA ?? commitSHA)
                .font(.caption.monospaced())
                .textSelection(.enabled)
              Button {
                copy(commitSHA, message: "已复制 commit SHA。")
              } label: {
                Image(systemName: "doc.on.doc")
              }
              .buttonStyle(.borderless)
              .help("复制 commit SHA")
              .accessibilityLabel("复制 Commit SHA")
              .accessibilityValue(commitSHA)
            }
          }
        }
        if let reviewURL = result.reviewURL {
          GridRow {
            Text("PR/MR").foregroundStyle(.secondary)
            Text(reviewURL)
              .font(.caption.monospaced())
              .workbenchTruncatedIdentity(reviewURL)
          }
        }
      }
      .font(.caption)

      if !result.changedPaths.isEmpty {
        let changedPaths = result.changedPaths.prefix(6).joined(separator: "\n")
        Text(changedPaths)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(changedPaths, lineLimit: 6)
      }
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  func remoteRepositoryCreationResultCard(_ result: RemoteRepositoryCreationResult) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Label("远端仓库已创建", systemImage: "checkmark.circle")
          .font(.caption.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.success)
        Spacer()
        if let urlText = result.htmlURL ?? result.cloneURL, let url = URL(string: urlText) {
          Button {
            ExternalURLOpener.open(url)
          } label: {
            Label("打开仓库", systemImage: "arrow.up.right.square")
          }
        }
      }

      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
        GridRow {
          Text("仓库").foregroundStyle(.secondary)
          Text(result.repositoryName)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        if let defaultBranch = result.defaultBranch {
          GridRow {
            Text("默认分支").foregroundStyle(.secondary)
            Text(defaultBranch)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        }
        GridRow {
          Text("可见性").foregroundStyle(.secondary)
          Text(result.privateRepository ? String(localized: "私有") : String(localized: "公开"))
        }
        if let htmlURL = result.htmlURL ?? result.cloneURL {
          GridRow {
            Text("URL").foregroundStyle(.secondary)
            Text(htmlURL)
              .font(.caption.monospaced())
              .workbenchTruncatedIdentity(htmlURL)
          }
        }
      }
      .font(.caption)
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  func remoteConflictPreview(paths: [String], isDirectCommit: Bool) -> some View {
    let title: LocalizedStringKey = isDirectCommit
      ? "远端冲突会阻断直接提交"
      : "远端冲突预览"
    let detail: LocalizedStringKey = isDirectCommit
      ? "先同步这些 upstream 变更，或切换为 PR/MR 发布。"
      : "这些路径在 upstream 也有变更，合并前需要审阅远端 diff。"

    return VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: "arrow.triangle.2.circlepath")
        .font(.workbenchCardTitle)
        .foregroundStyle(isDirectCommit ? WorkbenchTheme.risk : WorkbenchTheme.warning)

      Text(detail)
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .lineSpacing(1)

      ForEach(paths.prefix(6), id: \.self) { path in
        WorkbenchPathIdentity(path: path)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background((isDirectCommit ? WorkbenchTheme.risk : WorkbenchTheme.warning).opacity(WorkbenchOpacity.warningBackground), in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

}
