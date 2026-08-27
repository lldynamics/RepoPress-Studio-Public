import PublishingMarkdownCore
import PublishingWorkbenchCore
import SwiftUI

struct MarkdownBatchFindReplacePanel: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var publishing: WorkbenchPublishingFeatureFacade

  let store: WorkbenchStore
  let siteProfileID: UUID?

  @State private var query = ""
  @State private var replacement = ""
  @State private var isCaseSensitive = false
  @State private var isWholeWord = false
  @State private var usesRegularExpression = false
  @State private var plan: MarkdownBatchReplacePlan?
  @State private var selectedDocumentIDs: Set<UUID> = []
  @State private var appliedPlan: MarkdownBatchReplacePlan?
  @State private var message = ""
  @State private var isFailure = false
  @State private var planningTask: Task<Void, Never>?
  @State private var planningRequestID = UUID()
  @State private var isPlanning = false
  @State private var isApplyingWrites = false
  @State private var appliedWriteCount = 0
  @State private var totalWriteCount = 0
  @FocusState private var isQueryFocused: Bool

  private let planningService = MarkdownBatchFindReplacePlanningService()

  init(store: WorkbenchStore, siteProfileID: UUID?) {
    self.store = store
    self.siteProfileID = siteProfileID
    _publishing = ObservedObject(wrappedValue: store.publishing)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        controls
        Divider()
        previewContent
        Divider()
        actionBar
      }
      .navigationTitle("跨文章批量查找替换")
    }
    .frame(minWidth: 760, idealWidth: 880, minHeight: 560, idealHeight: 680)
    .onAppear {
      isQueryFocused = true
    }
    .onDisappear {
      cancelPlanning(showsMessage: false)
    }
    .onChange(of: query) { _, _ in markPreviewStale() }
    .onChange(of: replacement) { _, _ in markPreviewStale() }
    .onChange(of: isCaseSensitive) { _, _ in markPreviewStale() }
    .onChange(of: isWholeWord) { _, _ in markPreviewStale() }
    .onChange(of: usesRegularExpression) { _, _ in markPreviewStale() }
    .onExitCommand {
      dismiss()
    }
    .accessibilityIdentifier("markdown-batch-find-replace-panel")
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        TextField("查找正文", text: $query)
          .textFieldStyle(.roundedBorder)
          .focused($isQueryFocused)
          .accessibilityLabel("查找正文")
          .accessibilityIdentifier("markdown-batch-find-query")
          .disabled(isBusy)
        Image(systemName: "arrow.right")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField("替换为", text: $replacement)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("替换正文")
          .accessibilityIdentifier("markdown-batch-replacement")
          .disabled(isBusy)
        if isPlanning {
          Button("取消计算") {
            cancelPlanning(showsMessage: true)
          }
          .accessibilityIdentifier("markdown-batch-cancel-planning-button")
        } else {
          Button("生成预览", action: generatePreview)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(query.isEmpty || isApplyingWrites)
            .accessibilityIdentifier("markdown-batch-preview-button")
        }
      }

      HStack(spacing: 14) {
        Toggle("区分大小写", isOn: $isCaseSensitive)
        Toggle("全词匹配", isOn: $isWholeWord)
        Toggle("正则表达式", isOn: $usesRegularExpression)
          .disabled(isBusy)

        Spacer()

        Label(
          siteProfileID == nil ? "全部站点" : "当前站点",
          systemImage: siteProfileID == nil ? "rectangle.3.group" : "doc.text"
        )
        .foregroundStyle(.secondary)
      }
      .toggleStyle(.checkbox)
      .font(.caption)
      .disabled(isBusy)

      if !message.isEmpty {
        if isBusy {
          Label(message, systemImage: "hourglass")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("markdown-batch-status")
        } else {
          Label(
            message,
            systemImage: isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
          )
          .font(.caption)
          .foregroundStyle(isFailure ? WorkbenchTheme.warning : WorkbenchTheme.success)
          .accessibilityIdentifier("markdown-batch-status")
        }
      }
      if isApplyingWrites {
        ProgressView(
          value: Double(appliedWriteCount),
          total: Double(max(totalWriteCount, 1))
        ) {
          Text("正在写入 \(appliedWriteCount) / \(totalWriteCount) 篇")
            .font(.caption)
        }
        .accessibilityIdentifier("markdown-batch-write-progress")
      }
    }
    .padding(16)
  }

  @ViewBuilder
  private var previewContent: some View {
    if let plan {
      if plan.previews.isEmpty {
        ContentUnavailableView(
          "没有可检查的文章",
          systemImage: "doc.text.magnifyingglass",
          description: Text("当前范围内没有站点文章。")
        )
      } else {
        List {
          Section {
            ForEach(plan.previews, id: \.documentID) { preview in
              previewRow(preview)
            }
          } header: {
            HStack {
              Text("\(plan.applicablePreviews.count) 篇可替换，共 \(plan.totalMatchCount) 处")
              Spacer()
              Button(selectedAllApplicable ? "取消全选" : "选择全部") {
                toggleAllApplicable()
              }
              .buttonStyle(.borderless)
              .disabled(plan.applicablePreviews.isEmpty)
            }
          }
        }
        .listStyle(.inset)
      }
    } else {
      ContentUnavailableView {
        Label("先生成替换预览", systemImage: "doc.text.magnifyingglass")
      } description: {
        Text("正文不会立即修改。预览会记录每篇文章的内容快照，执行前再次检查冲突。")
      }
    }
  }

  private func previewRow(_ preview: MarkdownBatchReplacePreview) -> some View {
    let presentation = MarkdownBatchReplacePreviewPresentation(preview: preview)
    return HStack(alignment: .top, spacing: 10) {
      Toggle(
        "",
        isOn: Binding(
          get: { selectedDocumentIDs.contains(preview.documentID) },
          set: { isSelected in
            if isSelected {
              selectedDocumentIDs.insert(preview.documentID)
            } else {
              selectedDocumentIDs.remove(preview.documentID)
            }
          }
        )
      )
      .labelsHidden()
      .toggleStyle(.checkbox)
      .disabled(!preview.canApply)
      .accessibilityLabel("选择\(preview.title)")

      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(preview.title.nilIfEmpty ?? String(localized: "未命名文章"))
            .fontWeight(.semibold)
          Spacer()
          Text(presentation.statusText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(preview.canApply ? WorkbenchTheme.primary : Color.secondary)
        }

        if let sourceExcerpt = presentation.sourceExcerpt {
          Text(sourceExcerpt)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        if preview.canApply {
          Label(
            replacement.isEmpty ? "匹配内容将被删除" : "替换为：\(replacement)",
            systemImage: "arrow.turn.down.right"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        }
      }
    }
    .padding(.vertical, 5)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("markdown-batch-preview-\(preview.documentID.uuidString)")
  }

  private var actionBar: some View {
    HStack {
      Button("关闭") { dismiss() }
        .keyboardShortcut(.cancelAction)

      if appliedPlan != nil {
        Button {
          rollbackLastApplication()
        } label: {
          Label("回滚上次替换", systemImage: "arrow.uturn.backward")
        }
        .accessibilityIdentifier("markdown-batch-rollback-button")
      }

      Spacer()

      Text("已选择 \(selectedDocumentIDs.count) 篇")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)

      Button {
        applySelected()
      } label: {
        Label("应用所选替换", systemImage: "checkmark.circle.fill")
      }
      .workbenchProminentActionStyle()
      .disabled(selectedDocumentIDs.isEmpty || plan == nil)
      .disabled(isBusy)
      .accessibilityIdentifier("markdown-batch-apply-button")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var options: MarkdownFindOptions {
    MarkdownFindOptions(
      caseSensitive: isCaseSensitive,
      wholeWord: isWholeWord,
      usesRegularExpression: usesRegularExpression
    )
  }

  private var scopedDrafts: [ArticleDraft] {
    publishing.drafts.filter { draft in
      guard !draft.isGeneralDraft else { return false }
      guard let siteProfileID else { return true }
      return draft.belongs(toSiteProfileID: siteProfileID)
    }
  }

  private var currentDocuments: [MarkdownBatchReplaceDocument] {
    scopedDrafts.map { draft in
      MarkdownBatchReplaceDocument(
        id: draft.id,
        title: draft.title.nilIfEmpty ?? String(localized: "未命名文章"),
        markdown: store.draftBodyEditorBuffer(for: draft.id).bodyMarkdown
      )
    }
  }

  private var selectedAllApplicable: Bool {
    guard let applicable = plan?.applicablePreviews, !applicable.isEmpty else { return false }
    return applicable.allSatisfy { selectedDocumentIDs.contains($0.documentID) }
  }

  private var isBusy: Bool {
    isPlanning || isApplyingWrites
  }

  private func markPreviewStale() {
    let hadPreview = plan != nil
    if isPlanning {
      cancelPlanning(showsMessage: false)
    }
    guard hadPreview else { return }
    plan = nil
    selectedDocumentIDs = []
    message = "查找条件已变化，请重新生成预览。"
    isFailure = false
  }

  private func generatePreview() {
    let documents = currentDocuments
    let requestedQuery = query
    let requestedReplacement = replacement
    let requestedOptions = options
    let requestID = UUID()
    planningRequestID = requestID
    isPlanning = true
    message = String(localized: "正在后台计算替换预览…")
    isFailure = false
    planningTask = Task { @MainActor in
      do {
        let generated = try await Self.planInBackground(
          documents: documents,
          query: requestedQuery,
          replacement: requestedReplacement,
          options: requestedOptions
        )
        guard !Task.isCancelled, planningRequestID == requestID else { return }
        planningTask = nil
        isPlanning = false
        plan = generated
        selectedDocumentIDs = Set(generated.applicablePreviews.map(\.documentID))
        message =
          generated.applicablePreviews.isEmpty
          ? String(localized: "没有找到可替换的正文内容。")
          : String(localized: "预览已生成；应用时会再次校验文章快照。")
        isFailure = false
      } catch is CancellationError {
        guard planningRequestID == requestID else { return }
        planningTask = nil
        isPlanning = false
        message = String(localized: "预览计算已取消。")
        isFailure = false
      } catch {
        guard planningRequestID == requestID else { return }
        planningTask = nil
        isPlanning = false
        plan = nil
        selectedDocumentIDs = []
        message = String(localized: "无法生成预览：\(error.localizedDescription)")
        isFailure = true
      }
    }
  }

  private func cancelPlanning(showsMessage: Bool) {
    guard isPlanning else { return }
    planningRequestID = UUID()
    planningTask?.cancel()
    planningTask = nil
    isPlanning = false
    if showsMessage {
      message = String(localized: "预览或复验计算已取消。")
      isFailure = false
    }
  }

  private func toggleAllApplicable() {
    guard let applicable = plan?.applicablePreviews else { return }
    if selectedAllApplicable {
      selectedDocumentIDs.subtract(applicable.map(\.documentID))
    } else {
      selectedDocumentIDs.formUnion(applicable.map(\.documentID))
    }
  }

  private func applySelected() {
    guard let previewPlan = plan else { return }
    let selectedPreviews = previewPlan.applicablePreviews.filter {
      selectedDocumentIDs.contains($0.documentID)
    }
    guard !selectedPreviews.isEmpty else { return }

    let selectedIDs = Set(selectedPreviews.map(\.documentID))
    let selectedDocuments = currentDocuments.filter { selectedIDs.contains($0.id) }
    let requestID = UUID()
    planningRequestID = requestID
    isPlanning = true
    message = String(localized: "正在后台复验所选文章…")
    isFailure = false
    planningTask = Task { @MainActor in
      do {
        let revalidated = try await Self.planInBackground(
          documents: selectedDocuments,
          query: previewPlan.query,
          replacement: previewPlan.replacement,
          options: previewPlan.options,
          expectedOriginals: selectedPreviews.map(\.originalSnapshot)
        )
        guard !Task.isCancelled, planningRequestID == requestID else { return }
        planningTask = nil
        isPlanning = false
        guard
          revalidated.previews.count == selectedPreviews.count,
          !revalidated.hasConflicts,
          revalidated.applicablePreviews.count == selectedPreviews.count
        else {
          plan = revalidated
          selectedDocumentIDs = Set(revalidated.applicablePreviews.map(\.documentID))
          message = String(
            localized: "文章在预览后发生变化，整批替换已停止；请检查冲突并重新预览。"
          )
          isFailure = true
          return
        }

        isApplyingWrites = true
        message = String(localized: "复验通过，正在分批写入所选文章…")
        appliedWriteCount = 0
        totalWriteCount = revalidated.applicablePreviews.count
        for (index, preview) in revalidated.applicablePreviews.enumerated() {
          _ = store.createManualVersion(for: preview.documentID)
          if index.isMultiple(of: 8) {
            await Task.yield()
          }
        }
        guard
          await apply(
            previews: revalidated.applicablePreviews,
            restoringOriginalsOnFailure: true
          )
        else {
          isApplyingWrites = false
          message = String(localized: "写入期间检测到版本变化，已撤销本次已写入的内容。")
          isFailure = true
          return
        }

        isApplyingWrites = false
        appliedPlan = revalidated
        selectedDocumentIDs = []
        message = String(
          localized:
            "已替换 \(revalidated.applicablePreviews.count) 篇文章、\(revalidated.totalMatchCount) 处；可用“回滚上次替换”恢复。"
        )
        isFailure = false
      } catch is CancellationError {
        guard planningRequestID == requestID else { return }
        planningTask = nil
        isPlanning = false
        message = String(localized: "替换复验已取消，正文没有修改。")
        isFailure = false
      } catch {
        guard planningRequestID == requestID else { return }
        planningTask = nil
        isPlanning = false
        isApplyingWrites = false
        message = String(localized: "替换失败：\(error.localizedDescription)")
        isFailure = true
      }
    }
  }

  @MainActor
  private func apply(
    previews: [MarkdownBatchReplacePreview],
    restoringOriginalsOnFailure: Bool
  ) async -> Bool {
    var applied: [MarkdownBatchReplacePreview] = []
    // Do not suspend between the first accepted mutation and either complete
    // success or rollback. Yielding here would let another window edit an
    // already-replaced draft, making an otherwise atomic rollback partial.
    for preview in previews {
      let current = store.draftBodyEditorBuffer(for: preview.documentID)
      guard preview.originalSnapshot.matches(current.bodyMarkdown),
        let result = store.replaceDraftBody(
          preview.proposedMarkdown,
          for: preview.documentID,
          expectedRevision: current.revision
        ),
        result.wasAccepted
      else {
        if restoringOriginalsOnFailure {
          restoreImmediately(applied.reversed())
        }
        return false
      }
      applied.append(preview)
      appliedWriteCount = applied.count
    }
    for (index, preview) in applied.enumerated() {
      store.flushDraftBodyEditorBuffer(for: preview.documentID)
      if index.isMultiple(of: 8) {
        await Task.yield()
      }
    }
    return true
  }

  private static func planInBackground(
    documents: [MarkdownBatchReplaceDocument],
    query: String,
    replacement: String,
    options: MarkdownFindOptions,
    expectedOriginals: [MarkdownBatchReplaceOriginalSnapshot] = []
  ) async throws -> MarkdownBatchReplacePlan {
    let worker = Task.detached(priority: .userInitiated) {
      try MarkdownBatchFindReplacePlanningService().plan(
        documents: documents,
        query: query,
        replacement: replacement,
        options: options,
        expectedOriginals: expectedOriginals
      )
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  @MainActor
  private func restoreImmediately<S: Sequence>(_ previews: S)
  where S.Element == MarkdownBatchReplacePreview {
    for preview in previews {
      let current = store.draftBodyEditorBuffer(for: preview.documentID)
      guard current.bodyMarkdown == preview.proposedMarkdown else { continue }
      _ = store.replaceDraftBody(
        preview.originalSnapshot.markdown,
        for: preview.documentID,
        expectedRevision: current.revision
      )
      store.flushDraftBodyEditorBuffer(for: preview.documentID)
    }
  }

  @MainActor
  private func rollbackLastApplication() {
    guard let appliedPlan else { return }
    let appliedIDs = Set(appliedPlan.applicablePreviews.map(\.documentID))
    let rollback = planningService.rollbackPlan(
      currentDocuments: currentDocuments.filter { appliedIDs.contains($0.id) },
      appliedPlan: appliedPlan
    )
    guard !rollback.hasConflicts else {
      let conflictCount = rollback.previews.count { preview in
        if case .conflict = preview.status { return true }
        return false
      }
      message = "\(conflictCount) 篇文章在替换后又被编辑，未执行回滚，以免覆盖新内容。"
      isFailure = true
      return
    }

    for preview in rollback.applicablePreviews {
      let current = store.draftBodyEditorBuffer(for: preview.documentID)
      guard current.bodyMarkdown == preview.currentMarkdown,
        let result = store.replaceDraftBody(
          preview.restoredMarkdown,
          for: preview.documentID,
          expectedRevision: current.revision
        ),
        result.wasAccepted
      else {
        message = "回滚时检测到新的版本变化，已停止；未覆盖冲突文章。"
        isFailure = true
        return
      }
    }
    for preview in rollback.applicablePreviews {
      store.flushDraftBodyEditorBuffer(for: preview.documentID)
    }
    self.appliedPlan = nil
    generatePreview()
    message = "上次批量替换已安全回滚，并已重新生成预览。"
    isFailure = false
  }
}

struct MarkdownBatchReplacePreviewPresentation: Equatable {
  let statusText: String
  let sourceExcerpt: String?

  init(preview: MarkdownBatchReplacePreview) {
    switch preview.status {
    case .ready:
      statusText = "\(preview.matchCount) 处匹配"
    case .noMatches:
      statusText = "无匹配"
    case .noChange:
      statusText = "替换后无变化"
    case .conflict(.duplicateDocumentIdentifier):
      statusText = "文章标识重复"
    case .conflict(.duplicateBaselineSnapshot):
      statusText = "预览快照重复"
    case .conflict(.sourceChangedSincePreview):
      statusText = "正文已变化"
    }

    guard let firstRange = preview.matchRanges.first else {
      sourceExcerpt = nil
      return
    }
    let source = preview.originalSnapshot.markdown as NSString
    guard firstRange.location >= 0, NSMaxRange(firstRange) <= source.length else {
      sourceExcerpt = nil
      return
    }
    let surrounding = source.paragraphRange(for: firstRange)
    let raw = source.substring(with: surrounding)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    sourceExcerpt = raw.count > 180 ? "\(raw.prefix(177))…" : raw
  }
}
