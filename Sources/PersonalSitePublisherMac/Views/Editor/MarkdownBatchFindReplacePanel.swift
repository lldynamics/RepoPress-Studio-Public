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
        Image(systemName: "arrow.right")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField("替换为", text: $replacement)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("替换正文")
          .accessibilityIdentifier("markdown-batch-replacement")
        Button("生成预览", action: generatePreview)
          .keyboardShortcut(.return, modifiers: [.command])
          .disabled(query.isEmpty)
          .accessibilityIdentifier("markdown-batch-preview-button")
      }

      HStack(spacing: 14) {
        Toggle("区分大小写", isOn: $isCaseSensitive)
        Toggle("全词匹配", isOn: $isWholeWord)
        Toggle("正则表达式", isOn: $usesRegularExpression)

        Spacer()

        Label(
          siteProfileID == nil ? "全部站点" : "当前站点",
          systemImage: siteProfileID == nil ? "rectangle.3.group" : "doc.text"
        )
        .foregroundStyle(.secondary)
      }
      .toggleStyle(.checkbox)
      .font(.caption)

      if !message.isEmpty {
        Label(
          message,
          systemImage: isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        )
        .font(.caption)
        .foregroundStyle(isFailure ? WorkbenchTheme.warning : WorkbenchTheme.success)
        .accessibilityIdentifier("markdown-batch-status")
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

  private func markPreviewStale() {
    guard plan != nil else { return }
    plan = nil
    selectedDocumentIDs = []
    message = "查找条件已变化，请重新生成预览。"
    isFailure = false
  }

  private func generatePreview() {
    do {
      let generated = try planningService.plan(
        documents: currentDocuments,
        query: query,
        replacement: replacement,
        options: options
      )
      plan = generated
      selectedDocumentIDs = Set(generated.applicablePreviews.map(\.documentID))
      message =
        generated.applicablePreviews.isEmpty
        ? "没有找到可替换的正文内容。"
        : "预览已生成；应用时会再次校验文章快照。"
      isFailure = false
    } catch {
      plan = nil
      selectedDocumentIDs = []
      message = "无法生成预览：\(error.localizedDescription)"
      isFailure = true
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

  @MainActor
  private func applySelected() {
    guard let previewPlan = plan else { return }
    let selectedPreviews = previewPlan.applicablePreviews.filter {
      selectedDocumentIDs.contains($0.documentID)
    }
    guard !selectedPreviews.isEmpty else { return }

    let selectedIDs = Set(selectedPreviews.map(\.documentID))
    let selectedDocuments = currentDocuments.filter { selectedIDs.contains($0.id) }
    do {
      let revalidated = try planningService.plan(
        documents: selectedDocuments,
        query: previewPlan.query,
        replacement: previewPlan.replacement,
        options: previewPlan.options,
        expectedOriginals: selectedPreviews.map(\.originalSnapshot)
      )
      guard
        revalidated.previews.count == selectedPreviews.count,
        !revalidated.hasConflicts,
        revalidated.applicablePreviews.count == selectedPreviews.count
      else {
        plan = revalidated
        selectedDocumentIDs = Set(revalidated.applicablePreviews.map(\.documentID))
        message = "文章在预览后发生变化，整批替换已停止；请检查冲突并重新预览。"
        isFailure = true
        return
      }

      for preview in revalidated.applicablePreviews {
        _ = store.createManualVersion(for: preview.documentID)
      }
      guard apply(previews: revalidated.applicablePreviews, restoringOriginalsOnFailure: true)
      else {
        message = "写入期间检测到版本变化，已撤销本次已写入的内容。"
        isFailure = true
        return
      }

      appliedPlan = revalidated
      selectedDocumentIDs = []
      message =
        "已替换 \(revalidated.applicablePreviews.count) 篇文章、"
        + "\(revalidated.totalMatchCount) 处；可用“回滚上次替换”恢复。"
      isFailure = false
    } catch {
      message = "替换失败：\(error.localizedDescription)"
      isFailure = true
    }
  }

  @MainActor
  private func apply(
    previews: [MarkdownBatchReplacePreview],
    restoringOriginalsOnFailure: Bool
  ) -> Bool {
    var applied: [MarkdownBatchReplacePreview] = []
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
    }
    for preview in applied {
      store.flushDraftBodyEditorBuffer(for: preview.documentID)
    }
    return true
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
