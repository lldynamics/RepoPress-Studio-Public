import PublishingWorkbenchCore
import SwiftUI

extension RepositoryWorkspaceView {
  @ViewBuilder
  var remoteChangedFiles: some View {
    if let report = store.repositoryReport {
      let summary = remoteRepositoryChangeSummary(for: report)
      let importableArticleFiles = importableRemoteChangedArticleFiles(for: report)
      let importableArticleCount = importableArticleFiles.count

      VStack(alignment: .leading, spacing: 10) {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            remoteChangesHeading(report)
            Spacer(minLength: 12)
            remoteChangesHeaderActions(
              files: importableArticleFiles,
              importableArticleCount: importableArticleCount,
              publishRelevantCount: summary.publishRelevantCount
            )
          }

          VStack(alignment: .leading, spacing: 10) {
            remoteChangesHeading(report)
            remoteChangesHeaderActions(
              files: importableArticleFiles,
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
                  RepositoryChangedFileDisclosureRow(
                    file: file,
                    source: .remote,
                    selection: $changedFileSelection
                  ) {
                    remoteChangedFileIdentity(file)
                  } actions: {
                    remoteChangedFileActions(file, role: role)
                  } diffActions: {
                    if let lineDiff = file.lineDiff {
                      Button {
                        changedFileSelection = RepositoryChangedFileSelection(
                          source: .remote,
                          file: file
                        )
                        copy(lineDiff, message: "已复制远端 diff。")
                      } label: {
                        Label("复制远端 diff", systemImage: "doc.text.magnifyingglass")
                      }
                      .buttonStyle(.link)
                      .accessibilityLabel("复制远端 diff")
                      .accessibilityValue(file.displayPath)
                      .accessibilityIdentifier(
                        "repository-remote-file-\(file.accessibilityIdentifierToken)-copy-diff"
                      )
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
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("repository-section-remote-changes")
    }
  }

  private func remoteChangesHeading(_ report: RepositoryScanReport) -> some View {
    let upstreamName = report.branchStatus?.upstreamName ?? String(localized: "当前分支未设置 upstream")
    return VStack(alignment: .leading, spacing: 3) {
      Text("远端文件变更")
        .font(.headline)
      Text("发布前先审阅网站或其他设备的更新，避免覆盖新内容。")
        .font(.callout)
        .foregroundStyle(.secondary)
      Text(upstreamName)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .workbenchTruncatedIdentity(upstreamName)
    }
  }

  private func remoteChangesHeaderActions(
    files: [RepositoryChangedFile],
    importableArticleCount: Int,
    publishRelevantCount: Int
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        remoteArticleImportButton(files: files, importableArticleCount: importableArticleCount)
        remotePublishRelevantCount(publishRelevantCount)
      }

      VStack(alignment: .leading, spacing: 7) {
        remoteArticleImportButton(files: files, importableArticleCount: importableArticleCount)
        remotePublishRelevantCount(publishRelevantCount)
      }
    }
  }

  private func remoteArticleImportButton(
    files: [RepositoryChangedFile],
    importableArticleCount: Int
  ) -> some View {
    Button {
      presentRemoteArticleImportPreview(files)
    } label: {
      Label("导入远端文章", systemImage: "tray.and.arrow.down")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.bordered)
    .disabled(importableArticleCount == 0)
    .accessibilityLabel("导入远端文章")
    .accessibilityValue(String(localized: "\(importableArticleCount) 篇可导入"))
    .accessibilityIdentifier("repository-remote-import-articles")
  }

  private func remotePublishRelevantCount(_ count: Int) -> some View {
    Text("\(count) 个发布相关远端变更")
      .font(.callout)
      .foregroundStyle(.secondary)
      .accessibilityLabel("发布相关远端变更")
      .accessibilityValue(String(localized: "\(count) 个"))
      .accessibilityIdentifier("repository-remote-publish-relevant-count")
  }

  private func remoteChangedFileIdentity(_ file: RepositoryChangedFile) -> some View {
    HStack(spacing: 10) {
      Text(file.kind.localizedDisplayName)
        .font(.caption)
        .frame(width: 58, alignment: .leading)
        .foregroundStyle(.secondary)
      WorkbenchPathIdentity(path: file.displayPath)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-remote-file-\(file.accessibilityIdentifierToken)-identity")
  }

  private func remoteChangedFileActions(
    _ file: RepositoryChangedFile,
    role: RepositoryChangedFileRole
  ) -> some View {
    HStack(spacing: 8) {
      if role == .article, file.kind != .deleted {
        Button {
          changedFileSelection = RepositoryChangedFileSelection(source: .remote, file: file)
          presentRemoteArticleImportPreview([file])
        } label: {
          Label("导入", systemImage: "tray.and.arrow.down")
        }
        .buttonStyle(.bordered)
        .help("导入远端文章草稿")
        .accessibilityLabel("导入远端文章草稿")
        .accessibilityValue(file.displayPath)
        .accessibilityIdentifier("repository-remote-file-\(file.accessibilityIdentifierToken)-import")
      }

      Button {
        changedFileSelection = RepositoryChangedFileSelection(source: .remote, file: file)
        copy(file.displayPath, message: "已复制远端路径。")
      } label: {
        Label("复制路径", systemImage: "doc.on.doc")
      }
      .buttonStyle(.bordered)
      .help("复制远端路径")
      .accessibilityLabel("复制远端路径")
      .accessibilityValue(file.displayPath)
      .accessibilityIdentifier("repository-remote-file-\(file.accessibilityIdentifierToken)-copy-path")

      Text(file.status)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .accessibilityLabel("远端文件状态")
        .accessibilityValue(file.status)
        .accessibilityIdentifier("repository-remote-file-\(file.accessibilityIdentifierToken)-status")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-remote-file-\(file.accessibilityIdentifierToken)-actions")
  }

  private func remoteRepositoryChangeSummary(for report: RepositoryScanReport) -> RepositoryChangeSummary {
    report.remoteChangeSummary(
      contentRoot: store.activeProfile.contentRoot,
      assetRoot: store.activeProfile.assetRoot
    )
  }

  private func importableRemoteChangedArticleFiles(for report: RepositoryScanReport) -> [RepositoryChangedFile] {
    report.remoteChangedFilesForRole(
      role: .article,
      contentRoot: store.activeProfile.contentRoot,
      assetRoot: store.activeProfile.assetRoot
    )
    .filter { $0.kind != .deleted }
  }
}
