import XCTest
@testable import PublishingWorkbenchCore

final class DraftVersionComparisonServiceTests: XCTestCase {
  private let service = DraftVersionComparisonService()
  private let profileID = UUID()

  func testComparisonReportsMetadataAndAlignedBodyChanges() {
    let previous = ArticleDraft(
      siteProfileID: profileID,
      title: "旧标题",
      slug: "old-title",
      tags: ["Swift"],
      summary: "旧摘要",
      bodyMarkdown: "# 标题\n\n第一段\n保留段落\n结尾"
    )
    var current = previous
    current.title = "新标题"
    current.tags = ["Swift", "macOS"]
    current.bodyMarkdown = "# 标题\n\n第一段已更新\n保留段落\n新增段落\n结尾"

    let comparison = service.compare(previous: previous, current: current)

    XCTAssertEqual(comparison.fieldChanges.map(\.field), [.title, .tags])
    XCTAssertEqual(comparison.removedLineCount, 1)
    XCTAssertEqual(comparison.addedLineCount, 2)
    XCTAssertTrue(comparison.bodyLineDiffs.contains {
      $0.kind == .removed && $0.text == "第一段"
    })
    XCTAssertTrue(comparison.bodyLineDiffs.contains {
      $0.kind == .added && $0.text == "第一段已更新"
    })
    XCTAssertTrue(comparison.bodyLineDiffs.contains {
      $0.kind == .unchanged && $0.text == "保留段落"
    })
  }

  func testComparisonCollapsesDistantUnchangedLines() {
    let originalLines = (1...30).map { "第 \($0) 行" }
    var updatedLines = originalLines
    updatedLines[15] = "第 16 行已更新"
    let previous = ArticleDraft(
      siteProfileID: profileID,
      title: "文章",
      bodyMarkdown: originalLines.joined(separator: "\n")
    )
    let current = ArticleDraft(
      siteProfileID: profileID,
      title: "文章",
      bodyMarkdown: updatedLines.joined(separator: "\n")
    )

    let comparison = service.compare(previous: previous, current: current, contextLineCount: 2)

    XCTAssertEqual(comparison.bodyLineDiffs.first?.kind, .skipped)
    XCTAssertEqual(comparison.bodyLineDiffs.last?.kind, .skipped)
    XCTAssertEqual(comparison.removedLineCount, 1)
    XCTAssertEqual(comparison.addedLineCount, 1)
  }

  func testEquivalentDraftsProduceNoChanges() {
    let draft = ArticleDraft(
      siteProfileID: profileID,
      title: "相同",
      bodyMarkdown: "相同正文"
    )

    let comparison = service.compare(previous: draft, current: draft)

    XCTAssertFalse(comparison.hasChanges)
    XCTAssertTrue(comparison.fieldChanges.isEmpty)
    XCTAssertTrue(comparison.bodyLineDiffs.isEmpty)
  }

  func testRestoreAppliesEditableContentButPreservesRepositoryAndPublicationTracking() {
    let attachment = DraftAttachment(
      originalFilename: "old.png",
      relativePublishPath: "/images/old.png",
      repositoryPath: "static/images/old.png"
    )
    let snapshotDate = Date(timeIntervalSince1970: 1_000)
    let currentCreatedAt = Date(timeIntervalSince1970: 2_000)
    let restoredAt = Date(timeIntervalSince1970: 3_000)
    let snapshot = ArticleDraft(
      id: UUID(),
      siteProfileID: UUID(),
      title: "旧标题",
      date: snapshotDate,
      slug: "old-title",
      tags: ["旧标签"],
      visibility: .private,
      summary: "旧摘要",
      coverAttachmentID: attachment.id,
      bodyMarkdown: "旧正文",
      attachments: [attachment],
      status: .draft,
      repositoryPath: "content/old.md",
      repositorySHA: "old-sha"
    )
    let current = ArticleDraft(
      siteProfileID: profileID,
      title: "当前标题",
      slug: "current-title",
      bodyMarkdown: "当前正文",
      status: .published,
      createdAt: currentCreatedAt,
      repositoryPath: "content/current.md",
      repositorySHA: "current-sha"
    )

    let restored = service.restoringContent(
      from: snapshot,
      into: current,
      restoredAt: restoredAt
    )

    XCTAssertEqual(restored.id, current.id)
    XCTAssertEqual(restored.siteProfileID, current.siteProfileID)
    XCTAssertEqual(restored.createdAt, currentCreatedAt)
    XCTAssertEqual(restored.status, .published)
    XCTAssertEqual(restored.repositoryPath, "content/current.md")
    XCTAssertEqual(restored.repositorySHA, "current-sha")
    XCTAssertEqual(restored.title, "旧标题")
    XCTAssertEqual(restored.date, snapshotDate)
    XCTAssertEqual(restored.bodyMarkdown, "旧正文")
    XCTAssertEqual(restored.attachments, [attachment])
    XCTAssertEqual(restored.coverAttachmentID, attachment.id)
    XCTAssertEqual(restored.updatedAt, restoredAt)
  }

  func testRestoreDropsCoverReferenceMissingFromSnapshotAttachments() {
    let snapshot = ArticleDraft(
      siteProfileID: profileID,
      title: "旧文章",
      coverAttachmentID: UUID(),
      bodyMarkdown: "旧正文"
    )
    let current = ArticleDraft(siteProfileID: profileID, title: "当前文章", bodyMarkdown: "当前正文")

    let restored = service.restoringContent(from: snapshot, into: current)

    XCTAssertNil(restored.coverAttachmentID)
  }
}
