import Foundation
import PublishingKnowledgeCore
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class KnowledgeContextPresentationCoordinatorTests: XCTestCase {
  func testWritingTargetPresentationShowsSiteAndPathAndSearchesBoth() {
    let presentation = KnowledgeWritingTargetPickerPresentation(
      id: UUID(),
      updatedAt: .now,
      title: "重复标题",
      siteName: "产品站",
      path: "content/articles/release-notes.md",
      isGeneral: false,
      isMasked: false
    )

    XCTAssertEqual(presentation.title, "重复标题")
    XCTAssertEqual(presentation.detail, "产品站 · content/articles/release-notes.md")
    XCTAssertTrue(presentation.matches("产品站"))
    XCTAssertTrue(presentation.matches("release-notes"))
    XCTAssertTrue(presentation.matches("重复标题"))
    XCTAssertFalse(presentation.matches("不存在"))
  }

  func testMaskedWritingTargetDoesNotExposePrivateMetadataThroughDisplayOrSearch() {
    let privateTitle = "不应显示的标题"
    let privateSiteName = "不应显示的站点"
    let privatePath = "private-route"
    let presentation = KnowledgeWritingTargetPickerPresentation(
      id: UUID(),
      updatedAt: .now,
      title: privateTitle,
      siteName: privateSiteName,
      path: privatePath,
      isGeneral: false,
      isMasked: true
    )

    XCTAssertEqual(presentation.title, "私密文章")
    XCTAssertEqual(presentation.detail, "内容已遮挡")
    XCTAssertFalse(presentation.help.contains(privateTitle))
    XCTAssertFalse(presentation.accessibilityLabel.contains(privateTitle))
    XCTAssertFalse(presentation.matches(privateTitle))
    XCTAssertFalse(presentation.matches(privateSiteName))
    XCTAssertFalse(presentation.matches(privatePath))
    XCTAssertTrue(presentation.matches("私密文章"))
  }

  func testWritingTargetOrderingKeepsCurrentTargetFirstThenRecentUpdates() {
    let current = makeWritingTargetPresentation(
      title: "当前目标",
      updatedAt: Date(timeIntervalSince1970: 100)
    )
    let newest = makeWritingTargetPresentation(
      title: "最近更新",
      updatedAt: Date(timeIntervalSince1970: 300)
    )
    let older = makeWritingTargetPresentation(
      title: "较早更新",
      updatedAt: Date(timeIntervalSince1970: 200)
    )

    let ordered = KnowledgeWritingTargetPickerPresentation.ordered(
      [older, newest, current],
      selectedID: current.id
    )

    XCTAssertEqual(ordered.map(\.id), [current.id, newest.id, older.id])
  }

  func testWritingTargetSearchFindsAnExistingRepositoryPathAmongOneHundredSameNamedArticles() {
    let targets = (0..<100).map { index in
      return KnowledgeWritingTargetPickerPresentation(
        id: UUID(),
        updatedAt: .now,
        title: "同名文章",
        siteName: "站点",
        path: "content/existing/article-\(index).md",
        isGeneral: false,
        isMasked: false
      )
    }

    XCTAssertEqual(targets.filter { $0.matches("article-42.md") }.map(\.id), [targets[42].id])
    XCTAssertEqual(targets.filter { $0.matches("   ") }.count, 100)
    XCTAssertTrue(targets.filter { $0.matches("not-present") }.isEmpty)
    XCTAssertFalse(targets[42].matches("generated-42"))
  }

  func testNewerInputCannotBeReplacedByCancelledOlderCalculation() async throws {
    let first = input(query: "标题：Fedora", ordinal: 0)
    let latest = input(query: "标题：SwiftUI", ordinal: 1)
    let coordinator = KnowledgeContextPresentationCoordinator { input in
      if input.query == first.query {
        try? await Task.sleep(for: .milliseconds(80))
      }
      return KnowledgeContextRecommendationPresentationPolicy.snapshot(for: input)
    }

    coordinator.update(with: first)
    coordinator.update(with: latest)

    for _ in 0..<20 where coordinator.snapshot?.query != latest.query {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertEqual(coordinator.snapshot?.query, latest.query)
    XCTAssertEqual(coordinator.snapshot?.groups.strong.first?.document.title, "SwiftUI 资料")
  }

  private func input(
    query: String,
    ordinal: Int
  ) -> KnowledgeContextRecommendationPresentationInput {
    let document = KnowledgeDocument(kind: .note, title: ordinal == 0 ? "Fedora 资料" : "SwiftUI 资料")
    let result = KnowledgeSearchResult(
      document: document,
      chunk: KnowledgeChunk(
        documentID: document.id,
        revisionID: document.currentRevisionID,
        ordinal: ordinal,
        content: document.title,
        tokenEstimate: 4,
        contentHash: "chunk-\(ordinal)"
      ),
      score: 1,
      signals: [.semantic]
    )
    return KnowledgeContextRecommendationPresentationInput(
      query: query,
      results: [result],
      excludingDocumentIDs: []
    )
  }

  private func makeWritingTargetPresentation(
    title: String,
    updatedAt: Date
  ) -> KnowledgeWritingTargetPickerPresentation {
    KnowledgeWritingTargetPickerPresentation(
      id: UUID(),
      updatedAt: updatedAt,
      title: title,
      siteName: "站点",
      path: title,
      isGeneral: false,
      isMasked: false
    )
  }
}
