import PublishingWorkbenchCore
import SwiftUI

private enum ContentMigrationNotice {
  case analyzing
  case ready
  case completed(inserted: Int, updated: Int)
  case unsupportedSource
  case unreadableSource(String)
  case invalidExport(String)
  case profileChanged
  case fileTooLarge
  case tooManyMarkdownFiles
  case copiedRedirectCSV
  case exportedRedirectCSV(String)
  case copyFailed
  case exportFailed(String)
  case failure(String)

  var isError: Bool {
    switch self {
    case .unsupportedSource, .unreadableSource, .invalidExport, .profileChanged,
         .fileTooLarge, .tooManyMarkdownFiles, .copyFailed, .exportFailed, .failure:
      true
    default:
      false
    }
  }
}

struct ContentMigrationAssistantView: View {
  @ObservedObject var store: WorkbenchStore
  @Environment(\.dismiss) private var dismiss
  @State private var plan: ContentMigrationPlan?
  @State private var notice: ContentMigrationNotice?
  @State private var isAnalyzing = false
  @State private var isApplying = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          sourceSection
          if let plan {
            planSummary(plan)
            draftPreview(plan)
            imageMappings(plan)
            redirects(plan)
            warnings(plan)
          } else {
            ContentUnavailableView(
              "选择导出来源",
              systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard",
              description: Text("先分析内容，再确认导入。原始文件、图片与仓库都不会在预览阶段被改写。")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
          }
        }
        .padding(20)
      }
      Divider()
      footer
    }
    .frame(minWidth: 760, idealWidth: 900, minHeight: 580, idealHeight: 700)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("内容迁移助手")
          .font(.title2.weight(.semibold))
        Text("导入 WordPress、RSS、Markdown 和通用博客导出包，先生成可审阅的转换计划。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("关闭") { dismiss() }
    }
    .padding(20)
  }

  private var sourceSection: some View {
    GroupBox("1. 选择来源") {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("支持 WXR、RSS/Atom、JSON 导出、单篇 Markdown 与 Markdown 文件夹。")
            .font(.callout)
          Text("预览会转换 Front Matter、Slug、图片目标路径和重定向候选，但不会复制文件或访问网络。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          selectSource()
        } label: {
          if isAnalyzing {
            Label {
              Text("正在分析")
            } icon: {
              Image(systemName: "hourglass")
            }
          } else {
            Label {
              Text("选择导出来源")
            } icon: {
              Image(systemName: "folder.badge.plus")
            }
          }
        }
        .disabled(isAnalyzing || isApplying)
      }
      if let notice {
        migrationNoticeText(notice)
          .font(.caption)
          .foregroundStyle(notice.isError ? .red : .secondary)
          .padding(.top, 6)
      }
    }
  }

  private func planSummary(_ plan: ContentMigrationPlan) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("2. 转换概览")
        .font(.headline)
      HStack(spacing: 12) {
        migrationMetric("文章", value: "\(plan.drafts.count)", image: "doc.text")
        migrationMetric("图片路径", value: "\(plan.imageMappings.count)", image: "photo")
        migrationMetric("重定向", value: "\(plan.redirects.count)", image: "arrow.triangle.branch")
        migrationMetric("来源", value: plan.sourceKind.localizedDisplayName, image: "archivebox")
      }
      Text("来源：\(plan.sourceName) · 将导入到「\(store.activeProfile.name)」。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func migrationMetric(_ title: String, value: String, image: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: image)
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 1) {
        Text(value)
          .font(.headline)
          .lineLimit(1)
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func draftPreview(_ plan: ContentMigrationPlan) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("3. 文章预览")
        .font(.headline)
      ForEach(Array(plan.drafts.prefix(8))) { draft in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(draft.title)
              .font(.callout.weight(.medium))
              .lineLimit(1)
            Spacer()
            Text(draft.draft ? "草稿" : "已发布")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Text("/\(draft.slug)  →  \(draft.repositoryPath ?? "")")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
          if !draft.summary.isEmpty {
            Text(draft.summary)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        .padding(10)
        .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
      }
      if plan.drafts.count > 8 {
        Text("另有 \(plan.drafts.count - 8) 篇文章会在确认后导入。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func imageMappings(_ plan: ContentMigrationPlan) -> some View {
    if !plan.imageMappings.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("图片路径映射")
          .font(.headline)
        Text("迁移计划只改写文章中的引用；图片本体仍需复制或下载到目标目录。")
          .font(.caption)
          .foregroundStyle(.secondary)
        ForEach(Array(plan.imageMappings.prefix(5))) { mapping in
          Text("\(mapping.sourcePath)  →  \(mapping.targetPath)")
            .font(.caption.monospaced())
            .lineLimit(1)
        }
        if plan.imageMappings.count > 5 {
          Text("另有 \(plan.imageMappings.count - 5) 条图片路径映射。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private func redirects(_ plan: ContentMigrationPlan) -> some View {
    if !plan.redirects.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("重定向候选")
            .font(.headline)
          Spacer()
          Button("复制 CSV") {
            let didCopy = ClipboardWriter.copy(
              plan.redirectTableCSV,
              successMessage: "已复制重定向 CSV。",
              setMessage: { _ in }
            )
            notice = didCopy ? .copiedRedirectCSV : .copyFailed
          }
          .controlSize(.small)
          Button("导出 CSV") {
            exportRedirects(plan)
          }
          .controlSize(.small)
        }
        ForEach(Array(plan.redirects.prefix(5))) { redirect in
          Text("\(redirect.sourcePath)  →  \(redirect.targetPath)")
            .font(.caption.monospaced())
            .lineLimit(1)
        }
        if plan.redirects.count > 5 {
          Text("另有 \(plan.redirects.count - 5) 条重定向候选。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private func warnings(_ plan: ContentMigrationPlan) -> some View {
    if !plan.warnings.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("注意")
          .font(.headline)
        ForEach(plan.warnings, id: \.self) { warning in
          Label(warning, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.warning)
        }
      }
    }
  }

  private var footer: some View {
    HStack {
      if let plan {
        Text("确认后会新增或更新本地草稿；不会自动写入仓库。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          apply(plan)
        } label: {
          if isApplying {
            Label {
              Text("正在导入")
            } icon: {
              Image(systemName: "hourglass")
            }
          } else {
            Label {
              Text("确认导入 \(plan.drafts.count) 篇")
            } icon: {
              Image(systemName: "tray.and.arrow.down.fill")
            }
          }
        }
        .disabled(isApplying || plan.drafts.isEmpty)
        .keyboardShortcut(.defaultAction)
      } else {
        Spacer()
      }
    }
    .padding(16)
  }

  private func selectSource() {
    guard let url = ContentMigrationSelectionPanel.chooseSource() else { return }
    isAnalyzing = true
    notice = .analyzing
    Task {
      let accessed = url.startAccessingSecurityScopedResource()
      defer {
        if accessed { url.stopAccessingSecurityScopedResource() }
        isAnalyzing = false
      }
      do {
        plan = try await store.makeContentMigrationPlan(sourceURL: url)
        notice = .ready
      } catch {
        plan = nil
        notice = migrationErrorNotice(error)
      }
    }
  }

  private func apply(_ plan: ContentMigrationPlan) {
    isApplying = true
    defer { isApplying = false }
    do {
      let summary = try store.applyContentMigration(plan)
      notice = .completed(inserted: summary.insertedCount, updated: summary.updatedCount)
    } catch {
      notice = migrationErrorNotice(error)
    }
  }

  private func migrationErrorNotice(_ error: Error) -> ContentMigrationNotice {
    guard let migrationError = error as? ContentMigrationError else {
      return .failure(error.localizedDescription)
    }
    switch migrationError {
    case .unsupportedSource:
      return .unsupportedSource
    case let .unreadableSource(path):
      return .unreadableSource(path)
    case let .invalidExport(details):
      return .invalidExport(details)
    case .profileChanged:
      return .profileChanged
    case .sourceOutsideSelectedDirectory:
      return .failure(migrationError.localizedDescription)
    case let .sourceLimitExceeded(details):
      if details == "导出文件超过 100 MB，请拆分后分批导入。" {
        return .fileTooLarge
      }
      if details == "Markdown 文件超过 10,000 个，请拆分文件夹后分批导入。" {
        return .tooManyMarkdownFiles
      }
      return .failure(details)
    }
  }

  @ViewBuilder
  private func migrationNoticeText(_ notice: ContentMigrationNotice) -> some View {
    switch notice {
    case .analyzing:
      Text("正在分析导出内容…")
    case .ready:
      Text("已生成转换预览，可检查文章、图片路径和重定向后再导入。")
    case let .completed(inserted, updated):
      Text("导入完成：新增 \(inserted) 篇，更新 \(updated) 篇。")
    case .unsupportedSource:
      Text("请选择 WordPress WXR、RSS/Atom、JSON 导出文件或 Markdown 文件夹。")
    case let .unreadableSource(path):
      Text("无法读取导入来源：\(path)")
    case let .invalidExport(details):
      Text("无法识别导出内容：\(details)")
    case .profileChanged:
      Text("迁移计划属于另一个站点配置，请重新生成预览后再导入。")
    case .fileTooLarge:
      Text("导出文件超过 100 MB，请拆分后分批导入。")
    case .tooManyMarkdownFiles:
      Text("Markdown 文件超过 10,000 个，请拆分文件夹后分批导入。")
    case .copiedRedirectCSV:
      Text("已复制重定向 CSV。")
    case let .exportedRedirectCSV(filename):
      Text("已导出重定向 CSV：\(filename)")
    case .copyFailed:
      Text("复制失败，请重试。")
    case let .exportFailed(details):
      Text("无法导出重定向 CSV：\(details)")
    case let .failure(details):
      Text("操作失败：\(details)")
    }
  }

  private func exportRedirects(_ plan: ContentMigrationPlan) {
    guard let url = ContentMigrationSelectionPanel.chooseRedirectTableDestination() else { return }
    do {
      try plan.redirectTableCSV.write(to: url, atomically: true, encoding: .utf8)
      notice = .exportedRedirectCSV(url.lastPathComponent)
    } catch {
      notice = .exportFailed(error.localizedDescription)
    }
  }
}
