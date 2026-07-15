import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  @ViewBuilder
  var remoteChangedFiles: some View {
    if let report = store.repositoryReport {
      let summary = remoteRepositoryChangeSummary(for: report)
      let importableArticleCount = importableRemoteChangedArticleCount(for: report)

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("远端 diff 审阅")
              .font(.headline)
            Text(report.branchStatus?.upstreamName ?? "当前分支未设置 upstream")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer()
          Button {
            store.importRemoteChangedArticleDraftsFromRepository()
          } label: {
            Label("导入远端文章", systemImage: "tray.and.arrow.down")
          }
          .disabled(importableArticleCount == 0)
          .accessibilityLabel("导入远端文章")
          .accessibilityValue("\(importableArticleCount) 篇可导入")
          Text("\(summary.publishRelevantCount) 个发布相关远端变更")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("发布相关远端变更")
            .accessibilityValue("\(summary.publishRelevantCount) 个")
        }

        if summary.totalCount > 0 {
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            MetricTile(title: "文章", value: "\(summary.articleCount)", systemImage: "doc.text")
            MetricTile(title: "图片", value: "\(summary.imageCount)", systemImage: "photo")
            MetricTile(title: "配置", value: "\(summary.configurationCount)", systemImage: "gearshape")
            MetricTile(title: "其他", value: "\(summary.otherCount)", systemImage: "ellipsis")
          }
        }

        if report.branchStatus?.upstreamName == nil {
          Text("设置 upstream 后，这里会审阅远端待拉取的文章、图片和配置变化。")
            .foregroundStyle(.secondary)
        } else if report.remoteChangedFiles.isEmpty {
          Text("当前 upstream 没有待拉取的文件变化。")
            .foregroundStyle(.secondary)
        } else {
          ForEach(RepositoryChangedFileRole.allCases, id: \.self) { role in
            let files = report.remoteChangedFilesForRole(
              role: role,
              contentRoot: store.activeProfile.contentRoot,
              assetRoot: store.activeProfile.assetRoot
            )

            if !files.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                Text("远端\(role.localizedDisplayName)变更")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)

                ForEach(files, id: \.id) { (file: RepositoryChangedFile) in
                  VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                      Text(file.kind.localizedDisplayName)
                        .font(.caption)
                        .frame(width: 58, alignment: .leading)
                        .foregroundStyle(.secondary)
                      Text(file.displayPath)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                      Spacer()

                      if role == .article, file.kind != .deleted {
                        Button {
                          store.importRemoteDraftFromRepository(repositoryPath: file.displayPath)
                        } label: {
                          Label("导入", systemImage: "tray.and.arrow.down")
                        }
                        .labelStyle(.iconOnly)
                        .help("导入远端文章草稿")
                        .accessibilityLabel("导入远端文章草稿")
                        .accessibilityValue(file.displayPath)
                      }

                      Button {
                        copy(file.displayPath, message: "已复制远端路径。")
                      } label: {
                        Label("复制路径", systemImage: "doc.on.doc")
                      }
                      .labelStyle(.iconOnly)
                      .help("复制远端路径")
                      .accessibilityLabel("复制远端路径")
                      .accessibilityValue(file.displayPath)

                      Text(file.status)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("远端文件状态")
                        .accessibilityValue(file.status)
                    }

                    if let lineDiff = file.lineDiff {
                      Text(lineDiff)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(16)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WorkbenchBackgroundStyle.codeBlock, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
                        .accessibilityLabel("远端 diff 预览")
                        .accessibilityValue(file.displayPath)

                      Button {
                        copy(lineDiff, message: "已复制远端 diff。")
                      } label: {
                        Label("复制远端 diff", systemImage: "doc.text.magnifyingglass")
                      }
                      .buttonStyle(.link)
                      .accessibilityLabel("复制远端 diff")
                      .accessibilityValue(file.displayPath)
                    }
                  }
                  Divider()
                }
              }
            }
          }
        }
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    }
  }

  private func remoteRepositoryChangeSummary(for report: RepositoryScanReport) -> RepositoryChangeSummary {
    report.remoteChangeSummary(
      contentRoot: store.activeProfile.contentRoot,
      assetRoot: store.activeProfile.assetRoot
    )
  }

  private func importableRemoteChangedArticleCount(for report: RepositoryScanReport) -> Int {
    report.remoteChangedFilesForRole(
      role: .article,
      contentRoot: store.activeProfile.contentRoot,
      assetRoot: store.activeProfile.assetRoot
    )
    .filter { $0.kind != .deleted }
    .count
  }
}
