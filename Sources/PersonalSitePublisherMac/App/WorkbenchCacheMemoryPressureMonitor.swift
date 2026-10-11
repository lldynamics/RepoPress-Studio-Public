import Foundation
import PublishingKnowledgeCore

@MainActor
final class WorkbenchCacheMemoryPressureMonitor {
  typealias ImageCachePolicyHandler = @Sendable (Bool, UInt64) async -> Void

  private var source: (any DispatchSourceMemoryPressure)?
  private weak var knowledgeStore: KnowledgeStore?
  private let updateImageCaches: ImageCachePolicyHandler
  private(set) var isCacheRetentionEnabled = true
  private(set) var generation: UInt64 = 0

  init(
    updateImageCaches: @escaping ImageCachePolicyHandler = updateSharedImageCaches
  ) {
    self.updateImageCaches = updateImageCaches
  }

  func start() {
    guard source == nil else { return }
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .main
    )
    source.setEventHandler { [weak self, weak source] in
      guard let event = source?.data else { return }
      // FIFO on the source's main queue preserves event order before numbering
      // policies and dispatching asynchronous updates to individual caches.
      DispatchQueue.main.async { [weak self] in
        guard let self, self.source != nil else { return }
        self.receive(event)
      }
    }
    self.source = source
    source.resume()
  }

  func stop() {
    source?.cancel()
    source = nil
  }

  func bindKnowledgeStore(_ store: KnowledgeStore?) {
    knowledgeStore = store
    updateKnowledgeCache()
  }

  func receive(_ event: DispatchSource.MemoryPressureEvent) {
    if !event.intersection([.warning, .critical]).isEmpty {
      isCacheRetentionEnabled = false
    } else if event.contains(.normal) {
      isCacheRetentionEnabled = true
    } else {
      return
    }
    generation += 1
    let isEnabled = isCacheRetentionEnabled
    let generation = generation
    let updateImageCaches = updateImageCaches
    Task { await updateImageCaches(isEnabled, generation) }
    updateKnowledgeCache()
  }

  private func updateKnowledgeCache() {
    guard let knowledgeStore else { return }
    let isEnabled = isCacheRetentionEnabled
    let generation = generation
    Task {
      await knowledgeStore.setCacheRetentionEnabled(isEnabled, generation: generation)
    }
  }

  private nonisolated static func updateSharedImageCaches(
    _ isEnabled: Bool, _ generation: UInt64
  ) async {
    await RSSArticleCoverThumbnailCache.shared.setCacheRetentionEnabled(
      isEnabled, generation: generation)
    await WorkbenchThumbnailCache.shared.setCacheRetentionEnabled(
      isEnabled, generation: generation)
    await MarkdownInlineAttachmentImageCache.shared.setCacheRetentionEnabled(
      isEnabled, generation: generation)
  }
}
