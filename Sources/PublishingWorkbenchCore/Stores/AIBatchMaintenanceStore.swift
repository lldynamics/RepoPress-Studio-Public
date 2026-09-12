import Combine
import Foundation

/// One retained queue per site, with one network request in flight per workspace.
@MainActor
public final class AIBatchMaintenanceStore: ObservableObject {
  @Published public private(set) var queues: [UUID: AIBatchMaintenanceQueue] = [:]
  @Published public private(set) var message: String?
  @Published public private(set) var runningSiteID: UUID?
  private weak var store: WorkbenchStore?
  private let fileURL: URL
  private let service = AIBatchMaintenanceService()
  private var task: Task<Void, Never>?
  private var loadFailed = false
  private let generate:
    (@MainActor (AIBatchMaintenanceOperation, ArticleDraft, SiteProfile) async throws -> String)?

  init(
    store: WorkbenchStore,
    generate: (
      @MainActor (AIBatchMaintenanceOperation, ArticleDraft, SiteProfile) async throws -> String
    )? = nil
  ) {
    self.store = store
    self.generate = generate
    fileURL = store.persistenceStore.persistence.fileURL
      .appendingPathExtension("ai-maintenance.json")
    load()
  }

  public func queue(for siteID: UUID) -> AIBatchMaintenanceQueue? { queues[siteID] }

  @discardableResult
  public func create(
    draftIDs: Set<UUID>, operation: AIBatchMaintenanceOperation, siteProfileID: UUID
  ) -> Bool {
    guard let store, store.canUseProtectedWorkbench, !loadFailed, runningSiteID == nil,
      let profile = store.profiles.first(where: { $0.id == siteProfileID })
    else { return false }
    guard store.flushPendingChanges() else {
      message = CoreL10n.text("文章尚未保存成功，请先处理保存问题。")
      return false
    }
    let config = store.aiProviderConfig(for: profile)
    let drafts = store.drafts.filter {
      draftIDs.contains($0.id) && !$0.isPrivate && $0.scope == .site(siteProfileID)
        && !$0.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }.prefix(100)
    guard !drafts.isEmpty else {
      message = CoreL10n.text("请选择当前站点有正文的非私密文章。")
      return false
    }
    let items = drafts.map {
      AIBatchMaintenanceItem(
        draftID: $0.id, draftTitle: $0.title,
        sourceFingerprint: service.fingerprint(draft: $0, profile: profile, config: config))
    }
    queues[siteProfileID] = AIBatchMaintenanceQueue(
      siteProfileID: siteProfileID, operation: operation, modelName: config.normalizedModel,
      items: items)
    message = CoreL10n.format("已准备 %lld 篇文章。点击开始后才发送 AI 请求。", items.count)
    return persist()
  }

  public func start(siteProfileID: UUID, retryFailed: Bool = false) {
    guard task == nil, !loadFailed, let store, store.canUseProtectedWorkbench,
      var queue = queues[siteProfileID]
    else { return }
    let retryIDs = retryFailed ? Set(queue.items.filter { $0.status == .failed }.map(\.id)) : nil
    if retryFailed { queue.retryFailed() }
    queue.resume()
    queues[siteProfileID] = queue
    guard persist() else { return }
    runningSiteID = siteProfileID
    message = nil
    task = Task { [weak self] in
      await self?.run(siteProfileID: siteProfileID, eligibleItemIDs: retryIDs)
    }
  }

  /// A pause completes the current request, then stops before the next article.
  public func pause(siteProfileID: UUID) {
    guard queues[siteProfileID] != nil else { return }
    queues[siteProfileID]?.pause()
    _ = persist()
  }

  public func isCurrent(item: AIBatchMaintenanceItem, siteProfileID: UUID) -> Bool {
    guard let store, store.canUseProtectedWorkbench,
      let draft = store.draft(for: item.draftID), !draft.isPrivate,
      draft.scope == .site(siteProfileID),
      let profile = store.profiles.first(where: { $0.id == siteProfileID }),
      !store.draftBodyEditorBuffer(for: item.draftID).isDirty
    else { return false }
    return !item.sourceFingerprint.isEmpty
      && service.fingerprint(
        draft: draft, profile: profile, config: store.aiProviderConfig(for: profile)
      ) == item.sourceFingerprint
  }

  @discardableResult
  public func apply(itemID: UUID, siteProfileID: UUID) -> Bool {
    guard let store, let queue = queues[siteProfileID],
      let item = queue.items.first(where: { $0.id == itemID }), item.status == .ready,
      let text = item.resultText,
      let suggestion = service.suggestion(operation: queue.operation, text: text)
    else { return false }
    guard store.canUseProtectedWorkbench, store.flushPendingChanges() else {
      message = CoreL10n.text("当前修改未保存成功，AI 建议尚未应用。")
      return false
    }
    guard isCurrent(item: item, siteProfileID: siteProfileID),
      var draft = store.draft(for: item.draftID)
    else {
      message = AIBatchMaintenanceError.changed.localizedDescription
      return false
    }
    let oldDraft = draft
    if let summary = suggestion.summary { draft.summary = summary }
    if !suggestion.tags.isEmpty { draft.tags = suggestion.tags }
    guard draft.summary != oldDraft.summary || draft.tags != oldDraft.tags else {
      queues[siteProfileID]?.markApplied(id: itemID)
      message = CoreL10n.text("建议与当前内容一致，无需修改。")
      return persist()
    }
    guard store.prepareRetainedBatchRecoveryVersions(for: [draft.id]) != nil,
      store.flushPendingChanges()
    else {
      message = CoreL10n.text("未能保存修改前版本，AI 建议尚未应用。")
      return false
    }
    // No suspension between final comparison and mutation. Never replace a
    // draft captured before the network request or a dirty editor buffer.
    guard isCurrent(item: item, siteProfileID: siteProfileID) else {
      message = AIBatchMaintenanceError.changed.localizedDescription
      return false
    }
    draft.markUpdated(replacing: oldDraft)
    store.updateDraft(draft)
    store.save()
    guard store.flushPendingChanges() else {
      // Keep visible content and the retained version; disk may be partially
      // updated, so a rollback here would lose repository state.
      message = CoreL10n.text("建议已进入编辑器，但保存失败。请处理保存问题；修改前版本已保留。")
      return false
    }
    queues[siteProfileID]?.markApplied(id: itemID)
    message = CoreL10n.text("已应用并保存建议，修改前版本已保留。")
    return persist()
  }

  public func markReviewed(itemID: UUID, siteProfileID: UUID) {
    guard let queue = queues[siteProfileID],
      queue.operation == .terminologyReview || queue.operation == .internalLinksReview,
      let item = queue.items.first(where: { $0.id == itemID }),
      isCurrent(item: item, siteProfileID: siteProfileID)
    else { return }
    queues[siteProfileID]?.markApplied(id: itemID)
    _ = persist()
  }

  private func run(siteProfileID: UUID, eligibleItemIDs: Set<UUID>? = nil) async {
    defer {
      runningSiteID = nil
      task = nil
    }
    while !Task.isCancelled, var queue = queues[siteProfileID],
      let item = queue.beginNext(eligibleItemIDs: eligibleItemIDs)
    {
      queues[siteProfileID] = queue
      guard persist() else {
        queues[siteProfileID]?.recoverInterrupted()
        break
      }
      do {
        guard let store, store.canUseProtectedWorkbench,
          let draft = store.draft(for: item.draftID),
          let profile = store.profiles.first(where: { $0.id == siteProfileID })
        else { throw AIBatchMaintenanceError.unavailable }
        guard isCurrent(item: item, siteProfileID: siteProfileID) else {
          throw AIBatchMaintenanceError.changed
        }
        let result: String
        if let generate {
          result = try await generate(queue.operation, draft, profile)
        } else {
          result = try await store.aiStore.generateBatchMaintenance(
            operation: queue.operation, draft: draft, profile: profile)
        }
        guard isCurrent(item: item, siteProfileID: siteProfileID) else {
          throw AIBatchMaintenanceError.changed
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128_000 else {
          throw AIBatchMaintenanceError.invalidResult
        }
        if queue.operation != .terminologyReview && queue.operation != .internalLinksReview,
          service.suggestion(operation: queue.operation, text: trimmed) == nil
        {
          throw AIBatchMaintenanceError.invalidResult
        }
        queues[siteProfileID]?.complete(id: item.id, resultText: trimmed)
      } catch {
        queues[siteProfileID]?.fail(id: item.id, message: error.localizedDescription)
        if store?.canUseProtectedWorkbench != true { queues[siteProfileID]?.pause() }
        if let authorizationError = error as? AIPublishingAssistantError {
          switch authorizationError {
          case .missingAPIKey, .dataSharingConsentRequired:
            queues[siteProfileID]?.pause()
          default: break
          }
        }
      }
      guard persist() else { break }
    }
  }

  private func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let data = try Data(contentsOf: fileURL)
      guard data.count <= 32 * 1_024 * 1_024 else { throw AIBatchMaintenanceError.invalidResult }
      let loaded = try JSONDecoder().decode([AIBatchMaintenanceQueue].self, from: data)
      for var queue in loaded
      where store?.profiles.contains(where: { $0.id == queue.siteProfileID }) == true {
        queue.recoverInterrupted()
        queues[queue.siteProfileID] = queue
      }
    } catch {
      loadFailed = true
      message = CoreL10n.format("无法读取 AI 批次记录：%@。%@", fileURL.path, error.localizedDescription)
    }
  }

  @discardableResult
  private func persist() -> Bool {
    guard !loadFailed else { return false }
    do {
      let data = try JSONEncoder().encode(Array(queues.values))
      guard data.count <= 32 * 1_024 * 1_024 else { throw AIBatchMaintenanceError.invalidResult }
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: fileURL, options: [.atomic])
      return true
    } catch {
      for key in Array(queues.keys) { queues[key]?.pause() }
      message = CoreL10n.format("AI 批次进度尚未保存：%@。%@", fileURL.path, error.localizedDescription)
      return false
    }
  }
}
