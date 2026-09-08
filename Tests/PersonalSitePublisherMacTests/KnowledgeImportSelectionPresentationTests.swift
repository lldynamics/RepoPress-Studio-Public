import PublishingKnowledgeCore
import XCTest

@testable import PersonalSitePublisherMac

final class KnowledgeImportSelectionPresentationTests: XCTestCase {
  func testSelectedPreviewContainsOnlyExplicitlySelectedCandidates() {
    let first = candidate(index: 1, disposition: .new)
    let second = candidate(index: 2, disposition: .update)
    let duplicate = candidate(index: 3, disposition: .duplicate)
    let preview = KnowledgeImportPreview(
      sourceName: "批量导入",
      candidates: [first, second, duplicate],
      warnings: ["全局提醒"]
    )

    let selected = KnowledgeImportSelectionPresentation.selectedPreview(
      from: preview,
      selectedCandidateIDs: [second.id]
    )

    XCTAssertEqual(selected.candidates.map(\.id), [second.id])
    XCTAssertEqual(selected.importableCount, 1)
    XCTAssertEqual(selected.warnings, ["全局提醒"])
  }

  func testCandidateBeyondInitialPreviewLimitCanBeSelectedForCommit() {
    let candidates = (0..<60).map { candidate(index: $0, disposition: .new) }
    let candidateBeyondFold = candidates[55]
    let preview = KnowledgeImportPreview(sourceName: "大型文件夹", candidates: candidates)

    let selected = KnowledgeImportSelectionPresentation.selectedPreview(
      from: preview,
      selectedCandidateIDs: [candidateBeyondFold.id]
    )

    XCTAssertEqual(KnowledgeImportSelectionPresentation.initialCandidateLimit, 50)
    XCTAssertEqual(selected.candidates.map(\.id), [candidateBeyondFold.id])
    XCTAssertEqual(selected.importableCount, 1)
  }

  func testEmptySelectionProducesNoImportableCandidates() {
    let preview = KnowledgeImportPreview(
      sourceName: "取消全部",
      candidates: [candidate(index: 1, disposition: .new)]
    )

    let selected = KnowledgeImportSelectionPresentation.selectedPreview(
      from: preview,
      selectedCandidateIDs: []
    )

    XCTAssertTrue(selected.candidates.isEmpty)
    XCTAssertEqual(selected.importableCount, 0)
  }

  private func candidate(
    index: Int,
    disposition: KnowledgeImportDisposition
  ) -> KnowledgeImportCandidate {
    KnowledgeImportCandidate(
      disposition: disposition,
      kind: .article,
      title: "资料 \(index)",
      sourceName: "source-\(index).md",
      originalContentHash: "original-\(index)",
      normalizedText: "正文 \(index)",
      normalizedContentHash: "normalized-\(index)",
      sections: []
    )
  }
}
