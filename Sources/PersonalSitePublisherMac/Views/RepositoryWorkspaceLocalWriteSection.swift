import Foundation
import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  @ViewBuilder
  var publishPackageSummary: some View {
    if let package = store.publishPackage {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("发布包")
              .font(.headline)
            Text(package.markdownPath)
              .font(.callout.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          Spacer()
          Button {
            Task {
              await store.commitSelectedDraftUsingPreferredStrategy()
            }
          } label: {
            Label(preferredPublishActionTitle, systemImage: preferredPublishActionSystemImage)
          }
          .disabled(store.localPublishReadiness?.canCommit != true || store.isLocalRepositoryMutationRunning)
          Button {
            Task {
              await store.writeSelectedDraftToLocalRepository()
            }
          } label: {
            Label("写入仓库", systemImage: "square.and.arrow.down")
          }
          .disabled(store.localPublishReadiness?.canWrite != true || store.isLocalRepositoryMutationRunning)
          Button {
            Task {
              await store.commitSelectedDraftDirectly()
            }
          } label: {
            Label("直接提交", systemImage: "checkmark.seal")
          }
          .disabled(store.localPublishReadiness?.canCommit != true || store.isLocalRepositoryMutationRunning)
          Button {
            copyCommitCommand()
          } label: {
            Label("复制提交命令", systemImage: "terminal")
          }
          .disabled(store.localPublishReadiness?.canCommit != true)
        }

        preferredPublishStrategyNote
        singlePublishReadiness

        if let message = store.publishActionMessage {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let result = store.localGitPublishResult {
          HStack(spacing: 10) {
            Label(result.mode.localizedDisplayName, systemImage: "checkmark.circle")
            Text(result.branchName)
              .font(.caption.monospaced())
            Text(result.commitSHA.prefix(8))
              .font(.caption.monospaced())
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        ForEach(package.files) { file in
          HStack {
            Text(
              file.operation == .delete
                ? file.operation.localizedDisplayName
                : file.kind.localizedDisplayName
            )
              .font(.caption)
              .frame(width: 70, alignment: .leading)
              .foregroundStyle(.secondary)
            Text(file.repositoryPath)
              .font(.callout.monospaced())
              .lineLimit(1)
            Spacer()
            if file.byteSize > 0 {
              Text(ByteCountFormatter.string(fromByteCount: file.byteSize, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    }
  }

  @ViewBuilder
  var publishDiffPreview: some View {
    if let preview = store.localPublishPreview {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("发布 diff 预览")
            .font(.headline)
          Spacer()
          Text("\(preview.changedFileDiffs.count) 个变化")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if preview.issues.isEmpty == false {
          ForEach(preview.issues) { issue in
            Label(issue.title, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(WorkbenchTheme.warning)
          }
        }

        ForEach(preview.fileDiffs) { diff in
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(diff.status.localizedDisplayName)
                .font(.caption)
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(diff.status == .unchanged ? .secondary : .primary)
              Text(diff.path)
                .font(.callout.monospaced())
                .lineLimit(1)
              Spacer()
              Text(diff.kind.localizedDisplayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let lineDiff = diff.lineDiff {
              Text(lineDiff)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(18)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkbenchBackgroundStyle.codeBlock, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
            }
          }
          Divider()
        }
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    }
  }

  private var preferredPublishActionTitle: String {
    switch store.activeProfile.repositoryPublishStrategy {
    case .direct:
      return "按策略直接提交"
    case .reviewRequest:
      return "按策略建分支"
    }
  }

  private var preferredPublishActionSystemImage: String {
    switch store.activeProfile.repositoryPublishStrategy {
    case .direct:
      return "checkmark.seal"
    case .reviewRequest:
      return "arrow.triangle.branch"
    }
  }

  private var preferredPublishStrategyNote: some View {
    Label(
      "当前策略：\(store.activeProfile.repositoryPublishStrategy.localizedDisplayName)。\(store.activeProfile.repositoryPublishStrategy.detail)",
      systemImage: "slider.horizontal.3"
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var singlePublishReadiness: some View {
    if let readiness = store.localPublishReadiness {
      VStack(alignment: .leading, spacing: 10) {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
          PublishReadinessTile(title: "写入", readiness: readiness.writeReadiness)
          PublishReadinessTile(title: "提交", readiness: readiness.commitReadiness)
          MetricTile(title: "变化", value: "\(readiness.changedFileCount)", systemImage: "doc.on.doc")
          MetricTile(title: "文件", value: "\(readiness.fileCount)", systemImage: "shippingbox")
        }

        let blockingIssues = visibleReadinessIssues(readiness)
        if !blockingIssues.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(blockingIssues.prefix(3)) { issue in
              HStack(alignment: .top, spacing: 8) {
                SeverityBadge(severity: issue.severity)
                  .frame(width: 70, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                  Text(issue.title)
                    .font(.caption.weight(.semibold))
                  Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
              }
            }
          }
        } else if !readiness.warningIssues.isEmpty {
          Label("\(readiness.warningIssues.count) 项警告，执行前建议确认。", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.warning)
        }
      }
      .padding(10)
      .background(WorkbenchBackgroundStyle.codeBlock, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    }
  }

  private func visibleReadinessIssues(_ readiness: LocalPublishReadiness) -> [PreflightIssue] {
    var seenKeys: Set<String> = []
    return (readiness.writeBlockingIssues + readiness.commitBlockingIssues).filter { issue in
      let key = [issue.severity.rawValue, issue.title, issue.message, issue.field ?? ""].joined(separator: "|")
      return seenKeys.insert(key).inserted
    }
  }

  private func copyCommitCommand() {
    guard let command = store.localCommitCommandForSelectedDraft() else {
      store.setPublishActionMessage("选择本地仓库后才能生成提交命令。")
      return
    }
    copy(command, message: "已复制 git 提交命令。")
  }
}
