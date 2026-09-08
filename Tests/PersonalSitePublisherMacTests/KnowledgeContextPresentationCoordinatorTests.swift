import Foundation
import PublishingKnowledgeCore
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class KnowledgeContextPresentationCoordinatorTests: XCTestCase {
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
}
