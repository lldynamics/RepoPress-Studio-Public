import AppKit
import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  @ViewBuilder
  var changedFiles: some View {
    if let report = store.repositoryReport {
      let summary = repositoryChangeSummary(for: report)
      let importableArticleCount = importableChangedArticleCount(for: report)

      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("差异摘要")
            .font(.headline)
          Spacer()
          Button {
            Task {
              await store.importChangedArticleDraftsFromLocalRepository()
            }
          } label: {
            Label("导入文章变更", systemImage: "tray.and.arrow.down")
          }
          .disabled(importableArticleCount == 0)
          .accessibilityLabel("导入本地文章变更")
          .accessibilityValue("\(importableArticleCount) 篇可导入")
          Text("\(summary.publishRelevantCount) 个发布相关变更")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("发布相关本地变更")
            .accessibilityValue("\(summary.publishRelevantCount) 个")
        }

        if summary.totalCount > 0 {
          LazyVGrid(columns: repositoryMetricGridColumns, spacing: 8) {
            MetricTile(title: "文章", value: "\(summary.articleCount)", systemImage: "doc.text")
            MetricTile(title: "图片", value: "\(summary.imageCount)", systemImage: "photo")
            MetricTile(title: "配置", value: "\(summary.configurationCount)", systemImage: "gearshape")
            MetricTile(title: "其他", value: "\(summary.otherCount)", systemImage: "ellipsis")
          }
        }

        if report.changedFiles.isEmpty {
          Text("当前工作树没有变更。")
            .foregroundStyle(.secondary)
        } else {
          ForEach(RepositoryChangedFileRole.allCases, id: \.self) { role in
            let files = report.changedFiles(
              role: role,
              contentRoot: store.activeProfile.contentRoot,
              assetRoot: store.activeProfile.assetRoot
            )

            if !files.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                Text("\(role.localizedDisplayName)变更")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)

                ForEach(files) { file in
                  VStack(alignment: .leading, spacing: 8) {
                    HStack {
                      Text(file.kind.localizedDisplayName)
                        .font(.caption)
                        .frame(width: 58, alignment: .leading)
                        .foregroundStyle(.secondary)
                      WorkbenchPathIdentity(path: file.path)
                      Spacer()
                      if file.kind != .deleted,
                         ["html", "htm"].contains(
                           URL(fileURLWithPath: file.displayPath).pathExtension.lowercased()
                         ) {
                        Button {
                          sourceSession.requestOpen(repositoryPath: file.displayPath)
                          stage = .source
                          store.setInspectorPresented(true)
                        } label: {
                          Label("源码编辑", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        .controlSize(.small)
                        .help("在高级源码编辑器中打开 \(file.displayPath)")
                      }
                      Text(file.status)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("本地文件状态")
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
                        .accessibilityLabel("本地 diff 预览")
                        .accessibilityValue(file.path)
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

  func repositoryChangeSummary(for report: RepositoryScanReport) -> RepositoryChangeSummary {
    report.changeSummary(
      contentRoot: store.activeProfile.contentRoot,
      assetRoot: store.activeProfile.assetRoot
    )
  }

  func importableChangedArticleCount(for report: RepositoryScanReport) -> Int {
    report.changedFiles(
      role: .article,
      contentRoot: store.activeProfile.contentRoot,
      assetRoot: store.activeProfile.assetRoot
    )
    .filter { $0.kind != .deleted }
    .count
  }

}
