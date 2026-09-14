import PublishingWorkbenchCore
import SwiftUI

/// A review surface for a queue owned by `WorkbenchStore`. It deliberately
/// creates work only after the user presses the create button.
struct AIBatchMaintenancePanel: View {
  @Environment(\.dismiss) private var dismiss
  let store: WorkbenchStore
  let initialDraftIDs: Set<UUID>
  let siteProfileID: UUID
  @ObservedObject private var maintenance: AIBatchMaintenanceStore
  @State private var operation: AIBatchMaintenanceOperation = .summary
  @State private var selectedDraftIDs: Set<UUID>
  @State private var draftSearch = ""
  @State private var showingResetConfirmation = false

  init(store: WorkbenchStore, initialDraftIDs: Set<UUID>) {
    self.store = store
    self.initialDraftIDs = initialDraftIDs
    self.siteProfileID = store.activeProfileID
    _maintenance = ObservedObject(wrappedValue: store.aiBatchMaintenance)
    let eligible = store.drafts.filter {
      initialDraftIDs.contains($0.id) && $0.belongs(toSiteProfileID: store.activeProfileID)
        && !$0.isPrivate && !$0.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }.prefix(100)
    _selectedDraftIDs = State(initialValue: Set(eligible.map(\.id)))
  }

  private var queue: AIBatchMaintenanceQueue? { maintenance.queue(for: siteProfileID) }
  private var siteDrafts: [ArticleDraft] {
    store.drafts.filter {
      $0.belongs(toSiteProfileID: siteProfileID) && !$0.isPrivate
        && !$0.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }
  private var selectedDrafts: [ArticleDraft] {
    siteDrafts.filter { selectedDraftIDs.contains($0.id) }
  }
  private var filteredSiteDrafts: [ArticleDraft] {
    let query = draftSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return siteDrafts }
    return siteDrafts.filter { $0.title.localizedCaseInsensitiveContains(query) }
  }
  private var hasExistingQueue: Bool { queue != nil }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          configuration
          selection
          if let message = maintenance.message {
            Text(message).font(.callout).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading).padding(10)
              .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: 8))
          }
          queueSummary
          results
        }
        .padding(20)
      }
      .navigationTitle("AI 批量维护")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") { close() }
            .accessibilityIdentifier("ai-batch-maintenance-close")
        }
      }
    }
    .frame(minWidth: 760, idealWidth: 880, minHeight: 600, idealHeight: 760)
    .alert("已有批量队列", isPresented: $showingResetConfirmation) {
      Button("取消", role: .cancel) {}
      Button("创建并重置", role: .destructive) { createQueue() }
    } message: {
      Text("重置会丢弃当前队列中的预览结果。")
    }
    .onDisappear { maintenance.pause(siteProfileID: siteProfileID) }
    .accessibilityIdentifier("ai-batch-maintenance-panel")
  }

  private var configuration: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("维护项目").font(.headline)
      Picker("维护项目", selection: $operation) {
        ForEach(AIBatchMaintenanceOperation.allCases) { item in
          Text(item.title).tag(item)
        }
      }
      .pickerStyle(.segmented)
      Text(
        "当前模型：\(store.aiProviderConfig(for: store.profiles.first { $0.id == siteProfileID } ?? store.activeProfile).normalizedModel) · 每篇文章生成一次建议；重试会再次请求 · 正文输入上限 24,000 字符"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var selection: some View {
    GroupBox("选择文章") {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("仅显示当前站点的非私密文章 · 已选 \(selectedDraftIDs.count) / 最多 100 篇")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("全选") { selectedDraftIDs = Set(siteDrafts.prefix(100).map(\.id)) }
          Button("清空") { selectedDraftIDs.removeAll() }
        }
        TextField("搜索文章标题", text: $draftSearch)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("ai-batch-maintenance-draft-search")
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(filteredSiteDrafts) { draft in
              Toggle(
                isOn: Binding(
                  get: { selectedDraftIDs.contains(draft.id) },
                  set: { checked in
                    if checked && selectedDraftIDs.count < 100 { selectedDraftIDs.insert(draft.id) }
                    if !checked { selectedDraftIDs.remove(draft.id) }
                  }
                )
              ) {
                Text(draft.title.nilIfEmpty ?? String(localized: "未命名文章"))
              }
              .toggleStyle(.checkbox)
            }
          }
        }
        .frame(maxHeight: 220)
        .scrollIndicators(.automatic)
        if filteredSiteDrafts.isEmpty {
          Text("没有匹配的可维护文章。").foregroundStyle(.secondary)
        }
        if siteDrafts.isEmpty { Text("当前站点没有可维护的非私密文章。").foregroundStyle(.secondary) }
        Button("创建批量队列") {
          if hasExistingQueue { showingResetConfirmation = true } else { createQueue() }
        }
        .workbenchProminentActionStyle()
        .disabled(
          selectedDrafts.isEmpty || selectedDrafts.count > 100 || maintenance.runningSiteID != nil
        )
        .accessibilityIdentifier("ai-batch-maintenance-create")
      }
      .padding(4)
    }
  }

  @ViewBuilder private var queueSummary: some View {
    if let queue {
      GroupBox("队列") {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("\(queue.operation.title) · \(queue.displayModelName)")
            Spacer()
            Text("\(queue.processedCount)/\(queue.totalCount)")
              .monospacedDigit()
          }
          ProgressView(value: queue.progressFraction)
          HStack {
            Text(
              "待处理 \(queue.pendingCount) · 就绪 \(queue.readyCount) · 失败 \(queue.failedCount) · 已应用/跳过 \(queue.appliedCount + queue.skippedCount)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            let anotherSiteRunning =
              maintenance.runningSiteID != nil && maintenance.runningSiteID != siteProfileID
            if queue.runningCount > 0 {
              Button("暂停") { maintenance.pause(siteProfileID: siteProfileID) }
            } else if anotherSiteRunning {
              Text("其他站点正在处理").font(.caption).foregroundStyle(.secondary)
            } else {
              Button(queue.isPaused ? String(localized: "继续") : String(localized: "开始")) {
                maintenance.start(siteProfileID: siteProfileID)
              }
              .disabled(queue.pendingCount == 0 || maintenance.runningSiteID != nil)
            }
            if queue.failedCount > 0 {
              Button("重试失败") { maintenance.start(siteProfileID: siteProfileID, retryFailed: true) }
                .disabled(maintenance.runningSiteID != nil)
            }
            if queue.isPaused {
              Text(
                queue.runningCount > 0 && maintenance.runningSiteID == siteProfileID
                  ? "当前文章完成后暂停" : "已暂停"
              )
              .font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .padding(4)
      }
    }
  }

  @ViewBuilder private var results: some View {
    if let queue {
      VStack(alignment: .leading, spacing: 8) {
        Text("结果").font(.headline)
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(queue.items) { item in
            itemRow(item, operation: queue.operation)
          }
        }
      }
    }
  }

  private func itemRow(_ item: AIBatchMaintenanceItem, operation: AIBatchMaintenanceOperation)
    -> some View
  {
    let current = store.drafts.first { $0.id == item.draftID }
    return VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(item.draftTitle.nilIfEmpty ?? String(localized: "未命名文章")).font(
          .subheadline.weight(.semibold))
        if let modelName = item.modelName ?? queue?.modelName {
          Text(modelName).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Text(statusTitle(item.status)).font(.caption).foregroundStyle(.secondary)
        if item.status == .ready {
          let current = maintenance.isCurrent(item: item, siteProfileID: siteProfileID)
          if operation == .terminologyReview || operation == .internalLinksReview {
            if current {
              Button("标记已审阅") {
                maintenance.markReviewed(itemID: item.id, siteProfileID: siteProfileID)
              }
            }
          } else {
            Button("应用") { _ = maintenance.apply(itemID: item.id, siteProfileID: siteProfileID) }
              .disabled(!current || maintenance.runningSiteID != nil)
          }
          if !current {
            Button("丢弃陈旧结果") {
              _ = maintenance.discardStaleResult(itemID: item.id, siteProfileID: siteProfileID)
            }
            .disabled(maintenance.runningSiteID != nil)
          }
        }
        if item.status != .running && item.status != .applied {
          Button("重新生成") {
            _ = maintenance.regenerate(itemID: item.id, siteProfileID: siteProfileID)
          }
          .disabled(maintenance.runningSiteID != nil)
        }
        if [.pending, .ready, .failed].contains(item.status) {
          Button("跳过") {
            _ = maintenance.skip(itemID: item.id, siteProfileID: siteProfileID)
          }
          .disabled(maintenance.runningSiteID != nil)
        }
        if item.status == .ready && !maintenance.isCurrent(item: item, siteProfileID: siteProfileID)
        {
          Text("文章已变化，请重新创建预览").font(.caption).foregroundStyle(WorkbenchTheme.risk)
        }
      }
      if let error = item.errorMessage {
        Text(error).font(.caption).foregroundStyle(WorkbenchTheme.risk)
      }
      if let result = item.resultText {
        DisclosureGroup("展开结果预览") {
          resultPreview(result: result, operation: operation, current: current)
        }
      }
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder private func resultPreview(
    result: String, operation: AIBatchMaintenanceOperation, current: ArticleDraft?
  ) -> some View {
    if operation != .terminologyReview && operation != .internalLinksReview, let current {
      let parsed = AIBatchMaintenanceService().suggestion(operation: operation, text: result)
      VStack(alignment: .leading, spacing: 4) {
        if operation == .summary || operation == .metadata {
          Text("当前摘要：\(current.summary.nilIfEmpty ?? "（空）")")
          Text("建议摘要：\(parsed?.summary ?? "（未识别）")")
        }
        if operation == .tags || operation == .metadata {
          Text("当前标签：\(current.tags.isEmpty ? "（空）" : current.tags.joined(separator: "、"))")
          Text(
            "建议标签：\(parsed?.tags.isEmpty == false ? parsed!.tags.joined(separator: "、") : "（未识别）")")
        }
        Text(result).font(.caption).textSelection(.enabled)
      }
    } else {
      Text(result).font(.caption).textSelection(.enabled)
    }
  }

  private func createQueue() {
    _ = maintenance.create(
      draftIDs: selectedDraftIDs, operation: operation, siteProfileID: siteProfileID)
  }

  private func close() {
    pauseAndDismiss()
  }

  private func pauseAndDismiss() {
    maintenance.pause(siteProfileID: siteProfileID)
    dismiss()
  }

  private func statusTitle(_ status: AIBatchMaintenanceItemStatus) -> String {
    switch status {
    case .pending: return String(localized: "待处理")
    case .running: return String(localized: "处理中")
    case .ready: return String(localized: "待审核")
    case .failed: return String(localized: "失败")
    case .applied: return String(localized: "已应用/已审阅")
    case .skipped: return String(localized: "已跳过")
    }
  }
}
