import Combine
import Foundation
import PublishingAICore
import PublishingKnowledgeCore

struct RSSListTitleTranslationInput: Equatable {
  let enabled: Bool
  let titles: [RSSArticleTranslationTextRequest]
  let target: RSSArticleTranslationTarget
  let backend: RSSArticleTranslationBackend
  let providerIdentity: Int
  let consent: AIDataSharingConsentPresentation?
  var retryRevision = 0
}

struct RSSListTitleTranslationBatchResult {
  let translations: [String: String]
  var issue: String?
}

/// Presentation-only translations never overwrite feed titles or load article bodies.
/// The source title participates in the key so refreshed headlines cannot reuse old text.
@MainActor
final class RSSListTitleTranslationController: ObservableObject {
  static let batchSize = 20
  static let cacheLimit = 512

  private struct Key: Hashable {
    let articleID: String
    let source: String
    let target: RSSArticleTranslationTarget
    let backend: RSSArticleTranslationBackend
    let providerIdentity: Int
  }

  @Published private var cache: [Key: String] = [:]
  @Published private(set) var isRunning = false
  @Published private(set) var issue: String?
  private var cacheOrder: [Key] = []
  private var failedKeys: [Key: String] = [:]
  private var generation = UUID()
  private var previousInput: RSSListTitleTranslationInput?

  func translatedTitle(
    id: String, source: String, target: RSSArticleTranslationTarget,
    backend: RSSArticleTranslationBackend, providerIdentity: Int
  ) -> String? {
    cache[
      Key(
        articleID: id, source: source, target: target,
        backend: backend, providerIdentity: providerIdentity)]
  }

  func cancel() {
    generation = UUID()
    isRunning = false
  }

  func run(
    _ input: RSSListTitleTranslationInput,
    translate: ([RSSArticleTranslationTextRequest]) async throws ->
      RSSListTitleTranslationBatchResult
  ) async {
    let requestID = UUID()
    generation = requestID
    if previousInput?.enabled != input.enabled
      || previousInput?.retryRevision != input.retryRevision
      || previousInput?.consent != input.consent
      || previousInput?.target != input.target
      || previousInput?.backend != input.backend
      || previousInput?.providerIdentity != input.providerIdentity
    {
      failedKeys.removeAll()
      issue = nil
    }
    previousInput = input
    isRunning = false
    guard input.enabled, !Task.isCancelled else { return }

    func key(_ title: RSSArticleTranslationTextRequest) -> Key {
      Key(
        articleID: title.id, source: title.sourceText, target: input.target,
        backend: input.backend, providerIdentity: input.providerIdentity)
    }
    issue = input.titles.lazy.compactMap { self.failedKeys[key($0)] }.first
    var seen = Set<String>()
    let pending = input.titles.filter {
      seen.insert($0.id).inserted
        && !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && $0.sourceText.count <= 500 && cache[key($0)] == nil && failedKeys[key($0)] == nil
    }
    guard !pending.isEmpty else { return }
    isRunning = true
    defer { if generation == requestID { isRunning = false } }

    for start in stride(from: 0, to: pending.count, by: Self.batchSize) {
      guard generation == requestID, !Task.isCancelled else { return }
      let batch = Array(pending[start..<min(start + Self.batchSize, pending.count)])
      do {
        let result = try await translate(batch)
        guard generation == requestID, !Task.isCancelled else { return }
        if let batchIssue = result.issue { issue = batchIssue }
        for title in batch {
          let entryKey = key(title)
          if let value = result.translations[title.id]?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !value.isEmpty, value.count <= 2_000
          {
            cache[entryKey] = value
            cacheOrder.removeAll { $0 == entryKey }
            cacheOrder.append(entryKey)
          } else {
            issue = result.issue ?? RSSArticleTranslationError.invalidResponse.localizedDescription
            failedKeys[entryKey] = issue
          }
        }
        while cacheOrder.count > Self.cacheLimit {
          cache.removeValue(forKey: cacheOrder.removeFirst())
        }
      } catch is CancellationError {
        return
      } catch {
        guard generation == requestID, !Task.isCancelled else { return }
        issue = error.localizedDescription
        // A provider/consent failure must not send the remaining pages repeatedly.
        for title in pending.dropFirst(start) {
          failedKeys[key(title)] = error.localizedDescription
        }
        break
      }
    }
    if failedKeys.count > Self.cacheLimit {
      let retained = Set(input.titles.suffix(Self.cacheLimit).map(key))
      failedKeys = failedKeys.filter { retained.contains($0.key) }
    }
  }
}
