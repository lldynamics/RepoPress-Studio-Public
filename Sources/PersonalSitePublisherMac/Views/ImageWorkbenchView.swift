import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct ImageWorkbenchView: View {
  let store: WorkbenchStore
  @Binding private var stage: ImageWorkbenchContextStage
  @ObservedObject private var imageWorkbench: WorkbenchImageWorkbenchFeatureFacade

  @State private var pendingBatchPreview: ImageBatchOperationPreview?
  @State private var selectedImageDraftID: UUID?
  @State private var issueQuery = ""
  @State private var issueFilter: ImageIssueArticleFilter = .all
  @State private var repositoryInventory: RepositoryImageInventory?
  @State private var repositoryInventoryErrorMessage: String?
  @State private var isRepositoryInventoryLoading = false
  @State private var selectedRepositoryPath: String?
  @State private var repositoryTargetDraftID: UUID?
  @State private var repositoryRefreshRequestID = UUID()
  @State private var activeRepositoryInventoryTaskID: UUID?

  init(store: WorkbenchStore, stage: Binding<ImageWorkbenchContextStage>) {
    self.store = store
    _stage = stage
    _imageWorkbench = ObservedObject(wrappedValue: store.imageWorkbench)
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          header
          batchStatus
          stageContent(availableWidth: geometry.size.width)
        }
        .workbenchOperationalPageLayout()
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片工作台")
    .accessibilityIdentifier("image-workbench")
    .onAppear {
      normalizeRepositoryTargetDraft()
    }
    .onChange(of: store.activeProfile.id) { _, _ in
      repositoryInventory = nil
      selectedRepositoryPath = nil
      normalizeRepositoryTargetDraft()
    }
    .onChange(of: store.visibleDrafts.map(\.id)) { _, _ in
      normalizeRepositoryTargetDraft()
    }
    .task(id: refreshInput) {
      await store.refreshImageWorkbenchSiteSummaryInBackground()
    }
    .task(id: repositoryInventoryRefreshInput) {
      await refreshRepositoryInventory()
    }
    .sheet(item: $pendingBatchPreview) { preview in
      ImageBatchOperationPreviewView(
        preview: preview,
        cancel: { pendingBatchPreview = nil },
        confirm: { selection in
          pendingBatchPreview = nil
          runBatchOperation(preview.action, selection: selection)
        }
      )
    }
  }

  @ViewBuilder
  private func stageContent(availableWidth: CGFloat) -> some View {
    switch stage {
    case .overview:
      VStack(alignment: .leading, spacing: 16) {
        if let summary = store.cachedImageWorkbenchSiteSummary {
          overview(summary)
          batchActions(summary)
        } else {
          siteSummaryState
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("image-workbench-overview")

    case .issues:
      if let summary = store.cachedImageWorkbenchSiteSummary {
        issueWorkspace(
          summary,
          usesSplitLayout: WorkbenchPageMetrics.usesOperationalSplit(for: availableWidth)
        )
      } else {
        siteSummaryState
      }

    case .repository:
      RepositoryImageBrowserView(
        inventory: repositoryInventory,
        isLoading: isRepositoryInventoryLoading,
        errorMessage: repositoryInventoryErrorMessage,
        targetDrafts: store.visibleDrafts,
        targetDraftID: $repositoryTargetDraftID,
        selectedRepositoryPath: $selectedRepositoryPath,
        onAttachToSelectedDraft: attachRepositoryImage,
        onOpenReferencedDraft: openDraft,
        onOpenRepositorySettings: { store.selectSection(.sync) }
      )
    }
  }

  @ViewBuilder
  private var siteSummaryState: some View {
    if let errorMessage = imageWorkbench.siteSummaryErrorMessage,
       !imageWorkbench.isSiteSummaryLoading {
      failureCard(errorMessage)
    } else {
      loadingCard
    }
  }

  private var header: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 16) {
        headerIntroduction
        Spacer(minLength: 12)
        headerActions
      }
      VStack(alignment: .leading, spacing: 12) {
        headerIntroduction
        headerActions
      }
    }
  }

  private var headerIntroduction: some View {
      VStack(alignment: .leading, spacing: 5) {
        Text("图片工作台")
          .font(.workbenchPageTitle)
        Text(stageDescription)
          .font(.workbenchPageSubtitle)
          .foregroundStyle(.secondary)
      }
  }

  private var stageDescription: LocalizedStringKey {
    switch stage {
    case .overview:
      return "查看站点图片状态，并在预览影响范围后执行批量处理。"
    case .issues:
      return "选择问题文章，查看图片详情并直接跳转到正文定位。"
    case .repository:
      return "浏览仓库中的图片、查看引用关系，并把图片加入目标文章。"
    }
  }

  private var headerActions: some View {
    HStack(spacing: 8) {
        Button {
          openRepositoryImageDirectory()
        } label: {
          Label("打开图片目录", systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .disabled(repositoryInventory == nil)
        .accessibilityIdentifier("image-workbench-open-folder")

        Button {
          openWritingForImageInsertion()
        } label: {
          Label(
            store.visibleDrafts.isEmpty
              ? String(localized: "新建文章")
              : String(localized: "前往写作"),
            systemImage: store.visibleDrafts.isEmpty ? "plus" : "square.and.pencil"
          )
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("image-workbench-open-writing")

        Button(action: refreshAll) {
          Label("重新扫描", systemImage: "arrow.clockwise")
        }
        .workbenchProminentActionStyle()
        .disabled(imageWorkbench.isSiteSummaryLoading || isRepositoryInventoryLoading)
        .accessibilityLabel("重新扫描文章图片和仓库图片")
        .accessibilityIdentifier("image-workbench-refresh")
      }
      .controlSize(.regular)
  }

  @ViewBuilder
  private var batchStatus: some View {
    if let message = imageWorkbench.actionMessage {
      Label(message, systemImage: "info.circle")
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    if let progress = imageWorkbench.batchProgress {
      HStack(spacing: 10) {
        ProgressView(value: progress.fractionCompleted)
          .frame(maxWidth: 260)
        Text(progress.operation.progressTitle)
        Text("\(progress.completedDraftCount)/\(progress.totalDraftCount)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        Button("取消") {
          imageWorkbench.cancelBatchProcessing()
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("全站图片处理进度")
      .accessibilityValue("\(progress.completedDraftCount)/\(progress.totalDraftCount)")
    }
  }

  private func overview(_ summary: ImageWorkbenchSiteSummary) -> some View {
    let affectedDraftCount = summary.draftSummaries.filter { $0.issueCount > 0 }.count
    return VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("当前站点")
            .font(.headline)
          Text(store.activeProfile.name)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(ByteCountFormatter.string(fromByteCount: summary.totalByteSize, countStyle: .file))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
        MetricTile(title: "文章图片", value: "\(summary.imageCount)", systemImage: "photo.on.rectangle")
        MetricTile(title: "待处理文章", value: "\(affectedDraftCount)", systemImage: "doc.badge.ellipsis")
        MetricTile(title: "错误", value: "\(summary.errorCount)", systemImage: "xmark.octagon")
        MetricTile(title: "警告", value: "\(summary.warningCount)", systemImage: "exclamationmark.triangle")
      }

      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "lightbulb")
          .foregroundStyle(WorkbenchTheme.navigationSelection)
          .accessibilityHidden(true)
        Text("新手建议：先在“需要处理”中选文章，点“在文章中查看”定位问题；确认后再使用批量操作。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片工作台概览")
  }

  private func batchActions(_ summary: ImageWorkbenchSiteSummary) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("批量处理")
          .font(.workbenchSectionTitle)
        Text("所有操作始终显示；点击后会先预览影响的文章和图片，不会直接改动文件。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
        ForEach(ImageWorkbenchBatchAction.allActions) { action in
          batchActionButton(action, summary: summary)
        }
      }
    }
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片批量处理")
    .accessibilityIdentifier("image-workbench-actions")
  }

  private func batchActionButton(
    _ action: ImageWorkbenchBatchAction,
    summary: ImageWorkbenchSiteSummary
  ) -> some View {
    let count = action.targetCount(in: summary)
    return Button {
      presentBatchPreview(action, summary: summary)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: action.systemImage)
          .font(.title3)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 3) {
          Text(action.title)
            .font(.workbenchCardTitle)
          Text(action.shortDescription)
            .font(.workbenchSupporting)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        Spacer(minLength: 6)
        Text("\(count)")
          .font(.callout.monospacedDigit().weight(.semibold))
      }
      .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
    }
    .buttonStyle(.bordered)
    .disabled(count == 0 || imageWorkbench.isProcessingBatch)
    .help(count == 0 ? String(localized: "当前没有符合此操作的图片。") : action.shortDescription)
    .accessibilityLabel(action.title)
    .accessibilityValue(String(format: String(localized: "%d 张图片"), count))
    .accessibilityIdentifier(action.accessibilityIdentifier)
  }

  private func issueWorkspace(
    _ summary: ImageWorkbenchSiteSummary,
    usesSplitLayout: Bool
  ) -> some View {
    let affectedDrafts = filteredAffectedDrafts(in: summary)
    let selectedDraft = selectedImageDraftSummary(candidates: affectedDrafts)

    return VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("需要处理")
          .font(.workbenchSectionTitle)
        Text("选择文章后可查看真实图片和问题，并直接跳到正文或图片检查器。")
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          issueSearchField
          issueFilterPicker
        }
        VStack(alignment: .leading, spacing: 8) {
          issueSearchField
          issueFilterPicker
        }
      }

      if affectedDrafts.isEmpty {
        EmptyStateView(
          title: issueQuery.trimmedForPublishing.isEmpty ? "没有需要处理的图片问题" : "没有匹配的问题文章",
          message: issueQuery.trimmedForPublishing.isEmpty
            ? "当前已载入文章的图片检查已通过。"
            : "请尝试其他文章标题或问题级别。",
          systemImage: "checkmark.circle",
          density: .compactPane
        )
      } else if usesSplitLayout {
        HStack(alignment: .top, spacing: 14) {
          issueArticleList(affectedDrafts, selectedID: selectedDraft?.draftID)
            .frame(width: 350)
          selectedDraftDetail(selectedDraft)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      } else {
        VStack(alignment: .leading, spacing: 14) {
          issueArticleList(affectedDrafts, selectedID: selectedDraft?.draftID)
          selectedDraftDetail(selectedDraft)
        }
      }
    }
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .onAppear { normalizeSelectedDraft(candidates: affectedDrafts) }
    .onChange(of: issueQuery) { _, _ in
      normalizeSelectedDraft(candidates: filteredAffectedDrafts(in: summary))
    }
    .onChange(of: issueFilter) { _, _ in
      normalizeSelectedDraft(candidates: filteredAffectedDrafts(in: summary))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片问题文章")
    .accessibilityIdentifier("image-issue-workspace")
  }

  private func issueArticleList(
    _ drafts: [ImageWorkbenchDraftSummary],
    selectedID: UUID?
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("文章")
          .font(.callout.weight(.semibold))
        Spacer()
        Text("\(drafts.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      ScrollView {
        LazyVStack(spacing: 7) {
          ForEach(drafts) { draft in
            issueArticleRow(draft, isSelected: selectedID == draft.draftID)
          }
        }
      }
      .frame(minHeight: 260, idealHeight: 390, maxHeight: 460)
      .accessibilityIdentifier("image-issue-article-list")
    }
    .padding(10)
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
  }

  private func issueArticleRow(
    _ draft: ImageWorkbenchDraftSummary,
    isSelected: Bool
  ) -> some View {
    HStack(spacing: 8) {
      Button {
        selectedImageDraftID = draft.draftID
        repositoryTargetDraftID = draft.draftID
        store.selectDraft(draft.draftID)
      } label: {
        HStack(spacing: 9) {
          Image(systemName: severitySystemImage(for: draft))
            .foregroundStyle(severityColor(for: draft))
            .frame(width: 17)
          VStack(alignment: .leading, spacing: 2) {
            Text(draft.draftTitle.nilIfEmpty ?? String(localized: "未命名文章"))
              .lineLimit(1)
            Text(issueSummary(for: draft))
              .font(.workbenchSupporting)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 6)
          Text("\(draft.issueCount)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(String(format: String(localized: "选择%@查看图片问题"), draft.draftTitle))
      .accessibilityAddTraits(isSelected ? .isSelected : [])

      Button {
        openDraft(draft.draftID)
      } label: {
        Label("打开文章", systemImage: "arrow.right.circle")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
      .help("打开文章")
      .accessibilityLabel(String(format: String(localized: "打开文章%@"), draft.draftTitle))
      .accessibilityIdentifier("image-issue-open-article-\(draft.draftID.uuidString)")
    }
    .padding(8)
    .background(
      isSelected
        ? AnyShapeStyle(WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.selectionBackground))
        : WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .stroke(WorkbenchTheme.navigationSelection.opacity(0.35), lineWidth: 1)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("image-issue-article-row-\(draft.draftID.uuidString)")
  }

  @ViewBuilder
  private func selectedDraftDetail(_ summary: ImageWorkbenchDraftSummary?) -> some View {
    if let summary {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(summary.draftTitle.nilIfEmpty ?? String(localized: "未命名文章"))
              .font(.headline)
              .workbenchTruncatedIdentity(summary.draftTitle, lineLimit: 2)
            Text(issueSummary(for: summary))
              .font(.workbenchSupporting)
              .foregroundStyle(.secondary)
          }
          Spacer()
          HStack(spacing: 8) {
            Button {
              openDraft(summary.draftID)
            } label: {
              Label("编辑文章", systemImage: "square.and.pencil")
            }
            .workbenchProminentActionStyle()
            .accessibilityIdentifier("image-issue-edit-article")

            Button {
              openFirstImageInspector(summary)
            } label: {
              Label("图片详情", systemImage: "sidebar.right")
            }
            .buttonStyle(.bordered)
            .disabled(summary.items.isEmpty)
            .accessibilityIdentifier("image-issue-open-inspector")
          }
          .controlSize(.regular)
        }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 8)], spacing: 8) {
          MetricTile(title: "图片", value: "\(summary.imageCount)", systemImage: "photo")
          MetricTile(title: "错误", value: "\(summary.errorCount)", systemImage: "xmark.octagon")
          MetricTile(title: "警告", value: "\(summary.warningCount)", systemImage: "exclamationmark.triangle")
          MetricTile(title: "全部问题", value: "\(summary.issueCount)", systemImage: "checklist")
        }

        if summary.issues.isEmpty {
          Label("该文章的图片检查已通过。", systemImage: "checkmark.circle")
            .foregroundStyle(WorkbenchTheme.success)
        } else {
          Text("具体问题")
            .font(.callout.weight(.semibold))
          ForEach(summary.issues) { issue in
            imageIssueRow(issue, summary: summary)
          }
        }

        if !summary.items.isEmpty {
          Divider()
          Text("文章图片")
            .font(.callout.weight(.semibold))
          ForEach(summary.items) { item in
            articleImageRow(item, draftID: summary.draftID)
          }
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        WorkbenchBackgroundStyle.control,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
      .accessibilityElement(children: .contain)
      .accessibilityLabel("选中文章的图片问题")
      .accessibilityIdentifier("image-issue-detail")
    }
  }

  private func imageIssueRow(
    _ issue: ImageWorkbenchIssue,
    summary: ImageWorkbenchDraftSummary
  ) -> some View {
    let item = issue.attachmentID.flatMap { attachmentID in
      summary.items.first { $0.attachmentID == attachmentID }
    }
    return HStack(alignment: .top, spacing: 9) {
      SeverityBadge(severity: issue.severity)
      VStack(alignment: .leading, spacing: 3) {
        Text(issue.title)
          .font(.workbenchItemTitle)
        Text(issue.message)
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button {
        openDraft(summary.draftID, locating: item)
      } label: {
        Label("在文章中查看", systemImage: "text.magnifyingglass")
      }
      .buttonStyle(.borderless)
      .controlSize(.regular)
      .accessibilityIdentifier("image-issue-locate-\(issue.id.uuidString)")
      if let item {
        Button {
          _ = store.focusImageInspector(draftID: summary.draftID, attachmentID: item.attachmentID)
        } label: {
          Label("图片详情", systemImage: "sidebar.right")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .accessibilityLabel("在图片检查器中查看")
        .accessibilityIdentifier("image-issue-inspector-\(issue.id.uuidString)")
      }
    }
    .padding(8)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .accessibilityElement(children: .contain)
  }

  private func articleImageRow(_ item: ImageWorkbenchItem, draftID: UUID) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: item.fileExists ? "photo" : "photo.badge.exclamationmark")
        .foregroundStyle(item.fileExists ? Color.secondary : WorkbenchTheme.risk)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(item.originalFilename)
            .font(.callout.weight(.medium))
            .lineLimit(1)
          if item.isCover {
            Label("封面", systemImage: "star.fill")
              .font(.workbenchMetadata)
              .foregroundStyle(.secondary)
          }
        }
        Text(item.relativePublishPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(imageItemDetail(item))
          .font(.workbenchMetadata)
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 8)
      Button {
        openDraft(draftID, locating: item)
      } label: {
        Label("在文章中查看", systemImage: "text.magnifyingglass")
      }
      .buttonStyle(.borderless)
      .controlSize(.regular)
      .accessibilityIdentifier("image-item-locate-\(item.attachmentID.uuidString)")
      Button {
        _ = store.focusImageInspector(draftID: draftID, attachmentID: item.attachmentID)
      } label: {
        Label("编辑信息", systemImage: "slider.horizontal.3")
      }
      .buttonStyle(.borderless)
      .controlSize(.regular)
      .accessibilityIdentifier("image-item-inspector-\(item.attachmentID.uuidString)")
    }
    .padding(8)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(item.originalFilename)
    .accessibilityValue(imageItemDetail(item))
  }

  private var loadingCard: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text("正在检查文章图片…")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private func failureCard(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("图片扫描失败", systemImage: "exclamationmark.triangle")
        .font(.headline)
        .foregroundStyle(WorkbenchTheme.risk)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      Button(action: refreshAll) {
        Label("重新扫描", systemImage: "arrow.clockwise")
      }
      .workbenchProminentActionStyle()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private var refreshInput: UInt64 {
    store.imageWorkbenchInputRevision
  }

  private var issueSearchField: some View {
    TextField("搜索问题文章", text: $issueQuery)
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel("搜索有图片问题的文章")
      .accessibilityIdentifier("image-issue-search")
  }

  private var issueFilterPicker: some View {
    Picker("问题级别", selection: $issueFilter) {
      ForEach(ImageIssueArticleFilter.allCases) { filter in
        Text(filter.title).tag(filter)
      }
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: 250)
    .accessibilityIdentifier("image-issue-filter")
  }

  private var repositoryInventoryRefreshInput: RepositoryInventoryRefreshInput {
    RepositoryInventoryRefreshInput(
      requestID: repositoryRefreshRequestID,
      imageRevision: store.imageWorkbenchInputRevision,
      profileID: store.activeProfile.id,
      repositoryRootPath: store.activeProfile.localRepositoryRootPath,
      assetRoot: store.activeProfile.assetRoot
    )
  }

  private func filteredAffectedDrafts(
    in summary: ImageWorkbenchSiteSummary
  ) -> [ImageWorkbenchDraftSummary] {
    let query = issueQuery.trimmedForPublishing
    return summary.draftSummaries.filter { draft in
      draft.issueCount > 0
        && issueFilter.includes(draft)
        && (query.isEmpty
          || draft.draftTitle.localizedStandardContains(query)
          || draft.issues.contains { issue in
            issue.title.localizedStandardContains(query)
              || issue.message.localizedStandardContains(query)
          })
    }
  }

  private func selectedImageDraftSummary(
    candidates: [ImageWorkbenchDraftSummary]
  ) -> ImageWorkbenchDraftSummary? {
    if let selectedImageDraftID,
       let selected = candidates.first(where: { $0.draftID == selectedImageDraftID }) {
      return selected
    }
    if let selectedDraftID = store.selectedDraftID,
       let selected = candidates.first(where: { $0.draftID == selectedDraftID }) {
      return selected
    }
    return candidates.first
  }

  private func normalizeSelectedDraft(candidates: [ImageWorkbenchDraftSummary]) {
    if let selectedImageDraftID,
       candidates.contains(where: { $0.draftID == selectedImageDraftID }) {
      return
    }
    selectedImageDraftID = candidates.first?.draftID
  }

  private func severitySystemImage(for summary: ImageWorkbenchDraftSummary) -> String {
    if summary.errorCount > 0 { return "xmark.octagon" }
    if summary.warningCount > 0 { return "exclamationmark.triangle" }
    return "info.circle"
  }

  private func severityColor(for summary: ImageWorkbenchDraftSummary) -> Color {
    if summary.errorCount > 0 { return WorkbenchTheme.risk }
    if summary.warningCount > 0 { return WorkbenchTheme.warning }
    return .secondary
  }

  private func issueSummary(for summary: ImageWorkbenchDraftSummary) -> String {
    var parts: [String] = []
    if summary.errorCount > 0 {
      parts.append(String(format: String(localized: "错误 %d"), summary.errorCount))
    }
    if summary.warningCount > 0 {
      parts.append(String(format: String(localized: "警告 %d"), summary.warningCount))
    }
    if summary.missingAltTextCount > 0 {
      parts.append(String(format: String(localized: "缺 alt %d"), summary.missingAltTextCount))
    }
    if summary.missingCaptionCount > 0 {
      parts.append(String(format: String(localized: "缺 caption %d"), summary.missingCaptionCount))
    }
    if summary.missingSourceCount > 0 {
      parts.append(String(format: String(localized: "源图缺失 %d"), summary.missingSourceCount))
    }
    if summary.duplicateImageCount > 0 {
      parts.append(String(format: String(localized: "重复 %d"), summary.duplicateImageCount))
    }
    if parts.isEmpty {
      parts.append(String(format: String(localized: "建议 %d"), summary.issueCount))
    }
    return parts.joined(separator: " · ")
  }

  private func imageItemDetail(_ item: ImageWorkbenchItem) -> String {
    var parts: [String] = []
    if item.byteSize > 0 {
      parts.append(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
    }
    if let dimensions = item.dimensions {
      parts.append("\(dimensions.width)×\(dimensions.height)")
    }
    if item.missingAltText { parts.append(String(localized: "缺 alt")) }
    if item.missingCaption { parts.append(String(localized: "缺 caption")) }
    if !item.fileExists { parts.append(String(localized: "源图缺失")) }
    return parts.joined(separator: " · ")
  }

  private func presentBatchPreview(
    _ action: ImageWorkbenchBatchAction,
    summary: ImageWorkbenchSiteSummary
  ) {
    let affectedItems: [ImageBatchAffectedItem] = summary.draftSummaries.flatMap { draftSummary in
      draftSummary.items.compactMap { item -> ImageBatchAffectedItem? in
        guard action.includes(item) else { return nil }
        return ImageBatchAffectedItem(
          draftID: draftSummary.draftID,
          draftTitle: draftSummary.draftTitle.nilIfEmpty ?? String(localized: "未命名文章"),
          item: item
        )
      }
    }
    pendingBatchPreview = ImageBatchOperationPreview(
      action: action,
      affectedItems: affectedItems
    )
  }

  private func runBatchOperation(
    _ action: ImageWorkbenchBatchAction,
    selection: [UUID: Set<UUID>]
  ) {
    switch action {
    case .fillMetadata:
      imageWorkbench.fillMissingMetadataForVisibleDrafts(
        includedAttachmentIDsByDraftID: selection
      )
    case .file(let operation):
      switch operation {
      case .optimizeJPEG:
        imageWorkbench.optimizeVisibleDraftJPEGImages(
          includedAttachmentIDsByDraftID: selection
        )
      case .convertWebP:
        imageWorkbench.convertVisibleDraftImagesToWebP(
          includedAttachmentIDsByDraftID: selection
        )
      case .optimizeSVG:
        imageWorkbench.optimizeVisibleDraftSVGImages(
          includedAttachmentIDsByDraftID: selection
        )
      case .resizeLargeImages:
        imageWorkbench.resizeVisibleDraftLargeImages(
          includedAttachmentIDsByDraftID: selection
        )
      case .cropCover16By9:
        break
      }
    }
  }

  private func refreshAll() {
    repositoryInventory = nil
    selectedRepositoryPath = nil
    repositoryRefreshRequestID = UUID()
    Task { @MainActor in
      await store.refreshImageWorkbenchSiteSummaryInBackground(force: true)
    }
  }

  private func refreshRepositoryInventory() async {
    let profile = store.activeProfile
    let drafts = store.visibleDrafts
    let taskID = UUID()
    activeRepositoryInventoryTaskID = taskID
    isRepositoryInventoryLoading = true
    repositoryInventoryErrorMessage = nil
    repositoryInventory = nil
    selectedRepositoryPath = nil
    defer {
      if activeRepositoryInventoryTaskID == taskID {
        isRepositoryInventoryLoading = false
      }
    }
    do {
      let inventory = try await RepositoryImageInventoryService().inventoryAsync(
        drafts: drafts,
        profile: profile
      )
      try Task.checkCancellation()
      guard profile.id == store.activeProfile.id else { return }
      repositoryInventory = inventory
      repositoryInventoryErrorMessage = nil
      if let selectedRepositoryPath,
         !inventory.assets.contains(where: { $0.repositoryPath == selectedRepositoryPath }) {
        self.selectedRepositoryPath = inventory.assets.first?.repositoryPath
      } else if selectedRepositoryPath == nil {
        selectedRepositoryPath = inventory.assets.first?.repositoryPath
      }
    } catch is CancellationError {
      return
    } catch {
      guard profile.id == store.activeProfile.id else { return }
      repositoryInventory = nil
      repositoryInventoryErrorMessage = error.localizedDescription
    }
  }

  private func attachRepositoryImage(_ asset: RepositoryImageAsset) {
    guard let inventory = repositoryInventory,
          inventory.profileID == store.activeProfile.id,
          inventory.assets.contains(where: { $0.repositoryPath == asset.repositoryPath }),
          let repositoryTargetDraftID,
          store.visibleDrafts.contains(where: { $0.id == repositoryTargetDraftID }) else {
      imageWorkbench.setActionMessage(String(localized: "请选择当前站点中的目标文章。"))
      return
    }
    imageWorkbench.attachRepositoryImage(
      repositoryPath: asset.repositoryPath,
      toDraftID: repositoryTargetDraftID
    )
    repositoryRefreshRequestID = UUID()
  }

  private func openRepositoryImageDirectory() {
    guard let inventory = repositoryInventory,
          inventory.profileID == store.activeProfile.id else { return }
    let directoryURL = URL(fileURLWithPath: inventory.repositoryRootPath, isDirectory: true)
      .appendingPathComponent(inventory.assetRootPath, isDirectory: true)
    NSWorkspace.shared.open(directoryURL)
  }

  private func openWritingForImageInsertion() {
    if store.visibleDrafts.isEmpty {
      store.createDraft()
      return
    }
    store.setDraftListContentScope(.currentSite)
    if let repositoryTargetDraftID {
      _ = store.focusDraft(repositoryTargetDraftID, section: .writing)
    } else {
      store.selectSection(.writing)
    }
  }

  private func normalizeRepositoryTargetDraft() {
    let drafts = store.visibleDrafts
    if let repositoryTargetDraftID,
       drafts.contains(where: { $0.id == repositoryTargetDraftID }) {
      return
    }
    if let selectedDraftID = store.selectedDraftID,
       drafts.contains(where: { $0.id == selectedDraftID }) {
      repositoryTargetDraftID = selectedDraftID
    } else {
      repositoryTargetDraftID = drafts.first?.id
    }
  }

  private func openDraft(_ draftID: UUID) {
    _ = store.focusDraft(draftID, section: .writing)
  }

  private func openDraft(_ draftID: UUID, locating item: ImageWorkbenchItem?) {
    guard store.focusDraft(draftID, section: .writing) else { return }
    let query = item?.relativePublishPath.nilIfEmpty ?? item?.originalFilename.nilIfEmpty
    store.requestEditorFocus(draftID: draftID, field: "body", query: query)
  }

  private func openFirstImageInspector(_ summary: ImageWorkbenchDraftSummary) {
    let issueAttachmentID = summary.issues.compactMap(\.attachmentID).first
    guard let attachmentID = issueAttachmentID ?? summary.items.first?.attachmentID else { return }
    _ = store.focusImageInspector(draftID: summary.draftID, attachmentID: attachmentID)
  }
}

enum ImageIssueArticleFilter: String, CaseIterable, Identifiable {
  case all
  case errors
  case warnings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: String(localized: "全部")
    case .errors: String(localized: "有错误")
    case .warnings: String(localized: "有警告")
    }
  }

  func includes(_ summary: ImageWorkbenchDraftSummary) -> Bool {
    switch self {
    case .all: summary.issueCount > 0
    case .errors: summary.errorCount > 0
    case .warnings: summary.warningCount > 0
    }
  }
}

private struct RepositoryInventoryRefreshInput: Hashable {
  let requestID: UUID
  let imageRevision: UInt64
  let profileID: UUID
  let repositoryRootPath: String
  let assetRoot: String
}
