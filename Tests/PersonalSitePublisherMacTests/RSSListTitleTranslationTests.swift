import PublishingKnowledgeCore
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class RSSListTitleTranslationTests: XCTestCase {
  private func input(
    titles: [RSSArticleTranslationTextRequest] = [.init(id: "one", sourceText: "Original title")],
    enabled: Bool = true, target: RSSArticleTranslationTarget = .simplifiedChinese,
    backend: RSSArticleTranslationBackend = .ai, provider: Int = 1, retry: Int = 0
  ) -> RSSListTitleTranslationInput {
    RSSListTitleTranslationInput(
      enabled: enabled, titles: titles, target: target,
      backend: backend, providerIdentity: provider, consent: nil, retryRevision: retry)
  }

  private func translated(
    _ controller: RSSListTitleTranslationController, _ input: RSSListTitleTranslationInput,
    index: Int = 0
  ) -> String? {
    let title = input.titles[index]
    return controller.translatedTitle(
      id: title.id, source: title.sourceText,
      target: input.target, backend: input.backend, providerIdentity: input.providerIdentity)
  }

  func testDisabledDoesNotSendTitles() async {
    let controller = RSSListTitleTranslationController()
    await controller.run(input(enabled: false)) { _ in
      XCTFail("Disabled title translation must not contact a provider")
      return .init(translations: [:])
    }
    XCTAssertFalse(controller.isRunning)
  }

  func testBatchesLoadedTitlesAndMapsResponsesByID() async {
    let controller = RSSListTitleTranslationController()
    let request = input(titles: (0..<45).map { .init(id: "\($0)", sourceText: "Title \($0)") })
    var sizes: [Int] = []
    await controller.run(request) { batch in
      sizes.append(batch.count)
      return .init(
        translations: Dictionary(
          uniqueKeysWithValues: batch.reversed().map {
            ($0.id, "译文 \($0.id)")
          }))
    }
    XCTAssertEqual(sizes, [20, 20, 5])
    XCTAssertEqual(translated(controller, request, index: 44), "译文 44")
    await controller.run(request) { _ in
      XCTFail("Successful title translations should be reused")
      return .init(translations: [:])
    }
  }

  func testCacheSeparatesSourceLanguageBackendAndProvider() async {
    let controller = RSSListTitleTranslationController()
    let original = input()
    await controller.run(original) { _ in .init(translations: ["one": "原始标题"]) }
    XCTAssertEqual(translated(controller, original), "原始标题")
    for changed in [
      input(titles: [.init(id: "one", sourceText: "Updated title")]),
      input(target: .japanese), input(backend: .apple), input(provider: 2),
    ] {
      XCTAssertNil(translated(controller, changed))
    }
  }

  func testFailureKeepsOriginalAndWaitsForExplicitRetry() async {
    let controller = RSSListTitleTranslationController()
    var calls = 0
    let request = input()
    await controller.run(request) { _ in
      calls += 1
      throw RSSArticleTranslationError.invalidResponse
    }
    XCTAssertNil(translated(controller, request))
    XCTAssertNotNil(controller.issue)
    await controller.run(request) { _ in
      calls += 1
      return .init(translations: ["one": "unexpected"])
    }
    XCTAssertEqual(calls, 1)
    await controller.run(input(retry: 1)) { _ in
      calls += 1
      return .init(translations: ["one": "已重试"])
    }
    XCTAssertEqual(calls, 2)
    XCTAssertEqual(translated(controller, request), "已重试")
    XCTAssertNil(controller.issue)
  }

  func testPartialResponseNeverSubstitutesAnotherTitleOrBlankText() async {
    let controller = RSSListTitleTranslationController()
    let request = input(titles: [
      .init(id: "a", sourceText: "First"), .init(id: "b", sourceText: "Second"),
      .init(id: "c", sourceText: "Third"),
    ])
    await controller.run(request) { _ in
      .init(translations: ["a": "第一", "b": " \n", "unknown": "不属于列表"])
    }
    XCTAssertEqual(translated(controller, request), "第一")
    XCTAssertNil(translated(controller, request, index: 1))
    XCTAssertNil(translated(controller, request, index: 2))
    XCTAssertNotNil(controller.issue)
  }

  func testDisableWhileInFlightRejectsLateProviderResult() async {
    let controller = RSSListTitleTranslationController()
    let request = input()
    var pending: CheckedContinuation<RSSListTitleTranslationBatchResult, Never>?
    let running = Task {
      await controller.run(request) { _ in
        await withCheckedContinuation { pending = $0 }
      }
    }
    while pending == nil { await Task.yield() }
    await controller.run(input(enabled: false)) { _ in
      XCTFail("Disabled")
      return .init(translations: [:])
    }
    pending?.resume(returning: .init(translations: ["one": "过期结果"]))
    await running.value
    XCTAssertNil(translated(controller, request))
    XCTAssertFalse(controller.isRunning)
  }

  func testCancellationRejectsLateResultEvenBeforeReplacementRun() async {
    let controller = RSSListTitleTranslationController()
    let request = input()
    var pending: CheckedContinuation<RSSListTitleTranslationBatchResult, Never>?
    let running = Task {
      await controller.run(request) { _ in
        await withCheckedContinuation { pending = $0 }
      }
    }
    while pending == nil { await Task.yield() }
    running.cancel()
    pending?.resume(returning: .init(translations: ["one": "过期结果"]))
    await running.value
    XCTAssertNil(translated(controller, request))
  }

  func testEmptyAndOversizedTitlesDoNotSendOrTruncateSource() async {
    let controller = RSSListTitleTranslationController()
    await controller.run(
      input(titles: [
        .init(id: "empty", sourceText: "  "),
        .init(id: "large", sourceText: String(repeating: "x", count: 501)),
      ])
    ) { _ in
      XCTFail("Invalid titles must remain original")
      return .init(translations: [:])
    }
  }

  func testSwitchingToCachedListClearsFailureFromPreviousFilter() async {
    let controller = RSSListTitleTranslationController()
    let cached = input()
    await controller.run(cached) { _ in .init(translations: ["one": "已缓存"]) }
    await controller.run(input(titles: [.init(id: "failed", sourceText: "Another title")])) { _ in
      throw RSSArticleTranslationError.invalidResponse
    }
    XCTAssertNotNil(controller.issue)
    await controller.run(cached) { _ in
      XCTFail("Cached list should not retranslate")
      return .init(translations: [:])
    }
    XCTAssertNil(controller.issue)
  }
}
