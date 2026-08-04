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
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            localChangesHeading
            Spacer(minLength: 12)
            localChangesHeaderActions(
              importableArticleCount: importableArticleCount,
              publishRelevantCount: summary.publishRelevantCount
            )
          }

          VStack(alignment: .leading, spacing: 10) {
            localChangesHeading
            localChangesHeaderActions(
              importableArticleCount: importableArticleCount,
              publishRelevantCount: summary.publishRelevantCount
            )
          }
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
                    ViewThatFits(in: .horizontal) {
                      HStack(spacing: 10) {
                        localChangedFileIdentity(file)
                        Spacer(minLength: 12)
                        localChangedFileActions(file)
                      }

                      VStack(alignment: .leading, spacing: 8) {
                        localChangedFileIdentity(file)
                        localChangedFileActions(file)
                      }
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
                        .accessibilityIdentifier("repository-local-file-\(file.accessibilityIdentifierToken)-diff")
                    }
                  }
                  .accessibilityElement(children: .contain)
                  .accessibilityIdentifier("repository-local-file-\(file.accessibilityIdentifierToken)")
                  Divider()
                }
              }
            }
          }
        }
      }
      .padding(14)
      .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("repository-section-local-changes")
    }
  }

  private var localChangesHeading: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("本地文件变更")
        .font(.headline)
      Text("检查这台 Mac 上尚未发布的文章、图片和配置修改。")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private func localChangesHeaderActions(
    importableArticleCount: Int,
    publishRelevantCount: Int
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        localArticleImportButton(importableArticleCount: importableArticleCount)
        localPublishRelevantCount(publishRelevantCount)
      }

      VStack(alignment: .leading, spacing: 7) {
        localArticleImportButton(importableArticleCount: importableArticleCount)
        localPublishRelevantCount(publishRelevantCount)
      }
    }
  }

  private func localArticleImportButton(importableArticleCount: Int) -> some View {
    Button {
      Task {
        await store.importChangedArticleDraftsFromLocalRepository()
      }
    } label: {
      Label("导入文章变更", systemImage: "tray.and.arrow.down")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.bordered)
    .disabled(importableArticleCount == 0)
    .accessibilityLabel("导入本地文章变更")
    .accessibilityValue(String(localized: "\(importableArticleCount) 篇可导入"))
    .accessibilityIdentifier("repository-local-import-articles")
  }

  private func localPublishRelevantCount(_ count: Int) -> some View {
    Text("\(count) 个发布相关变更")
      .font(.callout)
      .foregroundStyle(.secondary)
      .accessibilityLabel("发布相关本地变更")
      .accessibilityValue(String(localized: "\(count) 个"))
      .accessibilityIdentifier("repository-local-publish-relevant-count")
  }

  private func localChangedFileIdentity(_ file: RepositoryChangedFile) -> some View {
    HStack(spacing: 10) {
      Text(file.kind.localizedDisplayName)
        .font(.caption)
        .frame(width: 58, alignment: .leading)
        .foregroundStyle(.secondary)
      WorkbenchPathIdentity(path: file.path)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-local-file-\(file.accessibilityIdentifierToken)-identity")
  }

  private func localChangedFileActions(_ file: RepositoryChangedFile) -> some View {
    HStack(spacing: 8) {
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
        .buttonStyle(.bordered)
        .help("在高级源码编辑器中打开 \(file.displayPath)")
        .accessibilityIdentifier("repository-local-file-\(file.accessibilityIdentifierToken)-open-source")
      }

      Text(file.status)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .accessibilityLabel("本地文件状态")
        .accessibilityValue(file.status)
        .accessibilityIdentifier("repository-local-file-\(file.accessibilityIdentifierToken)-status")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-local-file-\(file.accessibilityIdentifierToken)-actions")
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
