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

enum ContentMigrationLayout {
  static let metricMinimumWidth: CGFloat = 132
  static let emptyStateMinimumHeight: CGFloat = 220
}

struct ContentMigrationAssistantView: View {
  @ObservedObject var store: WorkbenchStore
  @Environment(\.dismiss) private var dismiss
  @State private var plan: ContentMigrationPlan?
  @State private var notice: ContentMigrationNotice?
  @State private var isAnalyzing = false
  @State private var isApplying = false
  @State private var selectedDraftIDs = Set<UUID>()

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      ScrollView(.vertical) {
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
            .frame(maxWidth: .infinity, minHeight: ContentMigrationLayout.emptyStateMinimumHeight)
          }
        }
        .padding(WorkbenchSpacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      footer
    }
    .workbenchSheetSize(.wide)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("data-management-migration-task")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("内容迁移助手")
        .font(.title2.weight(.semibold))
      Text("导入 WordPress、RSS、Markdown 和通用博客导出包，先生成可审阅的转换计划。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(WorkbenchSpacing.page)
  }

  private var sourceSection: some View {
    GroupBox("1. 选择来源") {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 12) {
          sourceDescription
          Spacer(minLength: 0)
          sourceButton
        }

        VStack(alignment: .leading, spacing: 8) {
          sourceDescription
          sourceButton
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let notice {
        AccessibleStatusMessage(
          message: migrationNoticeMessage(notice),
          severity: notice.isError ? .error : .info
        )
          .font(.caption)
          .padding(.top, 6)
      }
    }
  }

  private var sourceDescription: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("支持 WXR、RSS/Atom、JSON 导出、单篇 Markdown 与 Markdown 文件夹。")
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Text("预览会转换文章头信息（Front Matter）、Slug、图片目标路径和重定向候选，但不会复制文件或访问网络。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var sourceButton: some View {
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

  private func planSummary(_ plan: ContentMigrationPlan) -> some View {
    let insertCount = plan.reviewItems.count { $0.disposition == .insert }
    let updateCount = plan.reviewItems.count { $0.disposition == .update }
    let unchangedCount = plan.reviewItems.count { $0.disposition == .unchanged }
    let conflictCount = plan.reviewItems.count { $0.disposition == .conflict }
    return VStack(alignment: .leading, spacing: 10) {
      Text("2. 转换概览")
        .font(.headline)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          migrationMetric("新增", value: "\(insertCount)", image: "doc.badge.plus")
          migrationMetric("更新", value: "\(updateCount)", image: "arrow.triangle.2.circlepath.doc.on.clipboard")
          migrationMetric("无需变更", value: "\(unchangedCount)", image: "equal.circle")
          migrationMetric("冲突", value: "\(conflictCount)", image: "exclamationmark.triangle")
        }

        LazyVGrid(
          columns: [
            GridItem(
              .adaptive(minimum: ContentMigrationLayout.metricMinimumWidth),
              spacing: WorkbenchSpacing.card,
              alignment: .topLeading
            )
          ],
          alignment: .leading,
          spacing: WorkbenchSpacing.card
        ) {
          migrationMetric("新增", value: "\(insertCount)", image: "doc.badge.plus")
          migrationMetric("更新", value: "\(updateCount)", image: "arrow.triangle.2.circlepath.doc.on.clipboard")
          migrationMetric("无需变更", value: "\(unchangedCount)", image: "equal.circle")
          migrationMetric("冲突", value: "\(conflictCount)", image: "exclamationmark.triangle")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text("来源：\(plan.sourceName)（\(plan.sourceKind.localizedDisplayName)） · 将导入到「\(store.activeProfile.name)」 · \(plan.imageMappings.count) 条图片路径 · \(plan.redirects.count) 条重定向")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
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
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func draftPreview(_ plan: ContentMigrationPlan) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack {
          Text("3. 逐篇审阅")
            .font(.headline)
          Spacer(minLength: 0)
          draftPreviewActions(for: plan)
        }

        VStack(alignment: .leading, spacing: 8) {
          Text("3. 逐篇审阅")
            .font(.headline)
          draftPreviewActions(for: plan)
        }
      }

      Text("只有勾选的「新增」和「更新」项会被应用；相同文章和冲突项不会改写本地草稿。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      LazyVStack(alignment: .leading, spacing: 8) {
        ForEach(plan.reviewItems) { item in
          migrationDraftRow(item)
        }
      }
    }
  }

  private func draftPreviewActions(for plan: ContentMigrationPlan) -> some View {
    HStack(spacing: 8) {
      Button("清空选择") {
        selectedDraftIDs.removeAll()
      }
      .controlSize(.small)
      .disabled(selectedDraftIDs.isEmpty)
      Button("全选可导入") {
        selectedDraftIDs = selectableDraftIDs(in: plan)
      }
      .controlSize(.small)
      .disabled(selectableDraftIDs(in: plan).isEmpty)
    }
  }

  private func migrationDraftRow(_ item: ContentMigrationDraftReviewItem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 10) {
          migrationSelectionControl(for: item)
          migrationDraftIdentity(for: item)
          Spacer(minLength: 0)
          migrationDraftState(for: item)
        }

        VStack(alignment: .leading, spacing: 6) {
          HStack(alignment: .top, spacing: 10) {
            migrationSelectionControl(for: item)
            migrationDraftIdentity(for: item)
          }
          migrationDraftState(for: item)
        }
      }

      let destination = "/\(item.importedDraft.slug)  →  \(item.repositoryPath)"
      Text(destination)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .workbenchTruncatedIdentity(destination)
      if !item.importedDraft.summary.isEmpty {
        Text(item.importedDraft.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }

      if item.disposition == .conflict {
        Text("目标路径重复、无效，或本地草稿在生成预览后已变化。请检查源文件并重新生成预览。")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.risk)
      } else if item.disposition == .unchanged {
        Text("与当前本地草稿相同，将自动跳过。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if item.disposition == .update, let comparison = item.comparison {
        DisclosureGroup("查看更新差异") {
          migrationComparison(comparison)
            .padding(.top, 6)
        }
        .font(.caption)
      }
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func migrationSelectionControl(for item: ContentMigrationDraftReviewItem) -> some View {
    if item.disposition.isSelectable {
      Toggle(
        "选择\(item.importedDraft.title)",
        isOn: Binding(
          get: { selectedDraftIDs.contains(item.id) },
          set: { isSelected in
            if isSelected {
              selectedDraftIDs.insert(item.id)
            } else {
              selectedDraftIDs.remove(item.id)
            }
          }
        )
      )
      .labelsHidden()
      .toggleStyle(.checkbox)
    } else {
      Image(systemName: item.disposition == .conflict ? "exclamationmark.triangle.fill" : "equal.circle.fill")
        .foregroundStyle(migrationDispositionColor(item.disposition))
        .frame(width: 16, height: 18)
        .accessibilityHidden(true)
    }
  }

  private func migrationDraftIdentity(for item: ContentMigrationDraftReviewItem) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(item.importedDraft.title)
        .font(.callout.weight(.medium))
        .workbenchTruncatedIdentity(item.importedDraft.title, lineLimit: 2)
      migrationDispositionBadge(item.disposition)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func migrationDraftState(for item: ContentMigrationDraftReviewItem) -> some View {
    Text(item.importedDraft.draft ? "草稿" : "已发布")
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func migrationDispositionBadge(_ disposition: ContentMigrationDraftDisposition) -> some View {
    Text(migrationDispositionTitle(disposition))
      .font(.caption.weight(.semibold))
      .foregroundStyle(migrationDispositionColor(disposition))
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(migrationDispositionColor(disposition).opacity(0.1), in: Capsule())
  }

  private func migrationComparison(_ comparison: DraftVersionComparison) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("元数据 \(comparison.fieldChanges.count) 项")
        Text("+\(comparison.addedLineCount) 行")
          .foregroundStyle(WorkbenchTheme.success)
        Text("−\(comparison.removedLineCount) 行")
          .foregroundStyle(WorkbenchTheme.risk)
      }
      .font(.caption.monospacedDigit())

      ForEach(comparison.fieldChanges, id: \.field) { change in
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 8) {
            Text(migrationFieldTitle(change.field))
              .fontWeight(.semibold)
              .frame(width: 72, alignment: .leading)
            migrationComparisonValue(change.previousValue, color: WorkbenchTheme.risk)
            Image(systemName: "arrow.right")
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            migrationComparisonValue(change.currentValue, color: WorkbenchTheme.success)
          }

          VStack(alignment: .leading, spacing: 4) {
            Text(migrationFieldTitle(change.field))
              .fontWeight(.semibold)
            comparisonValueLabel("原值", value: change.previousValue, color: WorkbenchTheme.risk)
            Image(systemName: "arrow.down")
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            comparisonValueLabel("新值", value: change.currentValue, color: WorkbenchTheme.success)
          }
        }
      }

      if !comparison.bodyLineDiffs.isEmpty {
        VStack(alignment: .leading, spacing: 1) {
          ForEach(Array(comparison.bodyLineDiffs.prefix(80))) { line in
            Text(migrationDiffText(line))
              .font(.caption.monospaced())
              .foregroundStyle(migrationDiffColor(line.kind))
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
          }
        }
        .textSelection(.enabled)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        if comparison.bodyLineDiffs.count > 80 {
          Text("差异较大，此处显示前 80 行；已完整统计新增和删除行数。")
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func migrationComparisonValue(_ value: String, color: Color) -> some View {
    Text(value)
      .foregroundStyle(color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .workbenchTruncatedIdentity(value, lineLimit: 3)
  }

  private func comparisonValueLabel(_ label: String, value: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.workbenchMetadata)
        .foregroundStyle(.secondary)
      migrationComparisonValue(value, color: color)
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
          let pathMapping = "\(mapping.sourcePath)  →  \(mapping.targetPath)"
          Text(pathMapping)
            .font(.caption.monospaced())
            .workbenchTruncatedIdentity(pathMapping)
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
        ViewThatFits(in: .horizontal) {
          HStack {
            Text("重定向候选")
              .font(.headline)
            Spacer(minLength: 0)
            redirectActions(for: plan)
          }

          VStack(alignment: .leading, spacing: 8) {
            Text("重定向候选")
              .font(.headline)
            redirectActions(for: plan)
          }
        }
        ForEach(Array(plan.redirects.prefix(5))) { redirect in
          let redirectMapping = "\(redirect.sourcePath)  →  \(redirect.targetPath)"
          Text(redirectMapping)
            .font(.caption.monospaced())
            .workbenchTruncatedIdentity(redirectMapping)
        }
        if plan.redirects.count > 5 {
          Text("另有 \(plan.redirects.count - 5) 条重定向候选。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func redirectActions(for plan: ContentMigrationPlan) -> some View {
    HStack(spacing: 8) {
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
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var footer: some View {
    ViewThatFits(in: .horizontal) {
      horizontalFooter
      verticalFooter
    }
    .padding(WorkbenchSpacing.content)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var horizontalFooter: some View {
    HStack(alignment: .center, spacing: 12) {
      cancelButton

      if let plan {
        Spacer(minLength: 0)
        footerMessage
        migrationImportButton(for: plan)
      } else {
        Spacer(minLength: 0)
      }
    }
  }

  private var verticalFooter: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let plan {
        footerMessage
        HStack {
          cancelButton
          Spacer(minLength: 0)
          migrationImportButton(for: plan)
        }
      } else {
        HStack {
          cancelButton
          Spacer(minLength: 0)
        }
      }
    }
  }

  private var cancelButton: some View {
    Button("取消") { dismiss() }
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("data-management-migration-task-cancel")
  }

  private var footerMessage: some View {
    Text("应用前会再次校验本地草稿；如已变化将停止改写，也不会自动写入仓库。")
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func migrationImportButton(for plan: ContentMigrationPlan) -> some View {
    let selectedCount = selectedImportCount(in: plan)
    return Button {
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
          Text("确认导入 \(selectedCount) 篇")
        } icon: {
          Image(systemName: "tray.and.arrow.down.fill")
        }
      }
    }
    .workbenchProminentActionStyle()
    .disabled(isApplying || selectedCount == 0)
    .keyboardShortcut(.defaultAction)
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
        let generatedPlan = try await store.makeContentMigrationPlan(sourceURL: url)
        plan = generatedPlan
        selectedDraftIDs = selectableDraftIDs(in: generatedPlan)
        notice = .ready
      } catch {
        plan = nil
        selectedDraftIDs.removeAll()
        notice = migrationErrorNotice(error)
      }
    }
  }

  private func apply(_ plan: ContentMigrationPlan) {
    isApplying = true
    defer { isApplying = false }
    do {
      let summary = try store.applyContentMigration(plan, selectedDraftIDs: selectedDraftIDs)
      notice = .completed(inserted: summary.insertedCount, updated: summary.updatedCount)
      self.plan = nil
      selectedDraftIDs.removeAll()
    } catch {
      if let migrationError = error as? ContentMigrationError,
         case .draftsChanged = migrationError {
        let refreshedPlan = store.refreshContentMigrationPlanReview(plan)
        self.plan = refreshedPlan
        selectedDraftIDs.formIntersection(selectableDraftIDs(in: refreshedPlan))
      }
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
    case .draftsChanged:
      return .failure(migrationError.localizedDescription)
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

  private func migrationNoticeMessage(_ notice: ContentMigrationNotice) -> String {
    switch notice {
    case .analyzing:
      return String(localized: "正在分析导出内容…")
    case .ready:
      return String(localized: "已生成转换预览，可检查文章、图片路径和重定向后再导入。")
    case let .completed(inserted, updated):
      return String(localized: "导入完成：新增 \(inserted) 篇，更新 \(updated) 篇。")
    case .unsupportedSource:
      return String(localized: "请选择 WordPress WXR、RSS/Atom、JSON 导出文件或 Markdown 文件夹。")
    case let .unreadableSource(path):
      return String(localized: "无法读取导入来源：\(path)")
    case let .invalidExport(details):
      return String(localized: "无法识别导出内容：\(details)")
    case .profileChanged:
      return String(localized: "迁移计划属于另一个站点配置，请重新生成预览后再导入。")
    case .fileTooLarge:
      return String(localized: "导出文件超过 100 MB，请拆分后分批导入。")
    case .tooManyMarkdownFiles:
      return String(localized: "Markdown 文件超过 10,000 个，请拆分文件夹后分批导入。")
    case .copiedRedirectCSV:
      return String(localized: "已复制重定向 CSV。")
    case let .exportedRedirectCSV(filename):
      return String(localized: "已导出重定向 CSV：\(filename)")
    case .copyFailed:
      return String(localized: "复制失败，请重试。")
    case let .exportFailed(details):
      return String(localized: "无法导出重定向 CSV：\(details)")
    case let .failure(details):
      return String(localized: "操作失败：\(details)")
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

  private func selectableDraftIDs(in plan: ContentMigrationPlan) -> Set<UUID> {
    Set(plan.reviewItems.filter { $0.disposition.isSelectable }.map(\.id))
  }

  private func selectedImportCount(in plan: ContentMigrationPlan) -> Int {
    plan.reviewItems.count {
      $0.disposition.isSelectable && selectedDraftIDs.contains($0.id)
    }
  }

  private func migrationDispositionTitle(_ disposition: ContentMigrationDraftDisposition) -> String {
    switch disposition {
    case .insert: "新增"
    case .update: "更新"
    case .unchanged: "相同"
    case .conflict: "冲突"
    }
  }

  private func migrationDispositionColor(_ disposition: ContentMigrationDraftDisposition) -> Color {
    switch disposition {
    case .insert: WorkbenchTheme.success
    case .update: WorkbenchTheme.primary
    case .unchanged: .secondary
    case .conflict: WorkbenchTheme.risk
    }
  }

  private func migrationDiffText(_ line: DraftVersionLineDiff) -> String {
    switch line.kind {
    case .added: "+ \(line.text)"
    case .removed: "− \(line.text)"
    case .unchanged: "  \(line.text)"
    case .skipped: "… 省略 \(line.skippedLineCount) 行 …"
    }
  }

  private func migrationFieldTitle(_ field: DraftVersionEditableField) -> String {
    switch field {
    case .title: "标题"
    case .date: "日期"
    case .slug: "Slug"
    case .tags: "标签"
    case .categories: "分类"
    case .authors: "作者"
    case .draftState: "草稿状态"
    case .visibility: "可见性"
    case .summary: "摘要"
    case .cover: "封面"
    case .attachments: "附件"
    }
  }

  private func migrationDiffColor(_ kind: DraftVersionLineDiffKind) -> Color {
    switch kind {
    case .added: WorkbenchTheme.success
    case .removed: WorkbenchTheme.risk
    case .unchanged, .skipped: .secondary
    }
  }
}
