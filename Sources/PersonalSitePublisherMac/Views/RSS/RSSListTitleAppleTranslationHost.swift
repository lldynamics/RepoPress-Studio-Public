import Combine
import Foundation
import NaturalLanguage
import PublishingKnowledgeCore
import SwiftUI

#if canImport(Translation)
  import Translation
#endif

struct RSSListTitleAppleRequest: Identifiable {
  let id: UUID
  let sourceLanguage: String
  let target: RSSArticleTranslationTarget
  let titles: [RSSArticleTranslationTextRequest]
}

/// Keeps the system session attached to the view and bridges cancellation to its waiter.
@MainActor
final class RSSListTitleAppleTranslationBridge: ObservableObject {
  @Published private(set) var request: RSSListTitleAppleRequest?
  private var continuation: CheckedContinuation<[String: String], Error>?

  func translate(
    _ titles: [RSSArticleTranslationTextRequest], target: RSSArticleTranslationTarget
  ) async throws -> RSSListTitleTranslationBatchResult {
    guard RSSReaderUserPreferences.isAppleTranslationAvailable else {
      return RSSListTitleTranslationBatchResult(
        translations: [:],
        issue: RSSArticleTranslationRoutingIssue.requiresMacOS15.message)
    }
    guard !target.languageCode.hasPrefix("custom:") else {
      return RSSListTitleTranslationBatchResult(
        translations: [:],
        issue: RSSArticleTranslationRoutingIssue.customTarget.message)
    }
    var result = RSSListTitleTranslationBatchResult(translations: [:])
    var translations: [String: String] = [:]
    var groups: [String: [RSSArticleTranslationTextRequest]] = [:]
    for title in titles {
      let recognizer = NLLanguageRecognizer()
      recognizer.processString(title.sourceText)
      guard let language = recognizer.dominantLanguage?.rawValue else {
        result.issue = RSSArticleTranslationRoutingIssue.availabilityUnknown.message
        continue
      }
      if language == target.languageCode {
        translations[title.id] = title.sourceText
      } else {
        groups[language, default: []].append(title)
      }
    }
    // A system TranslationSession has one source language. Mixed feeds need separate batches.
    for language in groups.keys.sorted() {
      try Task.checkCancellation()
      let availability = await Self.availability(source: language, target: target.languageCode)
      try Task.checkCancellation()
      let decision = RSSArticleTranslationRoutingPolicy.decision(
        backend: .apple, force: false, target: target,
        isAppleTranslationAvailable: true, availability: availability)
      guard decision == .apple else {
        if case .blocked(let issue) = decision { result.issue = issue.message }
        continue
      }
      do {
        let translated = try await translateInstalledBatch(
          groups[language] ?? [], source: language, target: target)
        translations.merge(translated) { _, new in new }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        result.issue = error.localizedDescription
      }
    }
    return RSSListTitleTranslationBatchResult(translations: translations, issue: result.issue)
  }

  func complete(id: UUID, result: Result<[String: String], Error>) {
    guard request?.id == id else { return }
    let waiter = continuation
    continuation = nil
    request = nil
    waiter?.resume(with: result)
  }

  func cancel() {
    guard let id = request?.id else { return }
    complete(id: id, result: .failure(CancellationError()))
  }

  private func translateInstalledBatch(
    _ titles: [RSSArticleTranslationTextRequest], source: String,
    target: RSSArticleTranslationTarget
  ) async throws -> [String: String] {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { waiter in
        cancel()
        continuation = waiter
        request = RSSListTitleAppleRequest(
          id: id, sourceLanguage: source, target: target, titles: titles)
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.complete(id: id, result: .failure(CancellationError()))
      }
    }
  }

  private static func availability(
    source: String, target: String
  ) async -> RSSAppleTranslationAvailabilityStatus {
    #if canImport(Translation)
      if #available(macOS 15.0, *) {
        switch await LanguageAvailability().status(
          from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        {
        case .installed: return .installed
        case .supported: return .supported
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
      }
    #endif
    return .unsupported
  }
}

struct RSSListTitleAppleTranslationHost: View {
  @ObservedObject var bridge: RSSListTitleAppleTranslationBridge

  var body: some View {
    #if canImport(Translation)
      if #available(macOS 15.0, *), let request = bridge.request {
        Color.clear.frame(width: 1, height: 1)
          .accessibilityHidden(true)
          .translationTask(
            TranslationSession.Configuration(
              source: Locale.Language(identifier: request.sourceLanguage),
              target: Locale.Language(identifier: request.target.languageCode)
            )
          ) { session in
            do {
              var translations: [String: String] = [:]
              for try await response in session.translate(
                batch: request.titles.map {
                  TranslationSession.Request(sourceText: $0.sourceText, clientIdentifier: $0.id)
                })
              {
                try Task.checkCancellation()
                if let id = response.clientIdentifier { translations[id] = response.targetText }
              }
              try Task.checkCancellation()
              bridge.complete(id: request.id, result: .success(translations))
            } catch {
              bridge.complete(id: request.id, result: .failure(error))
            }
          }
          .id(request.id)
      }
    #endif
  }
}
