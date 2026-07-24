import Foundation
import Testing
@testable import PublishingWorkbenchCore

struct LocalContentImportMergeServiceTests {
  @Test func plansInsertUpdateSkipAndConflictWithoutMutatingInput() {
    let profileID = UUID()
    var existing = ArticleDraft.fixture(
      title: "Existing",
      siteProfileID: profileID,
      repositoryPath: "content/existing.md"
    )
    existing.createdAt = Date(timeIntervalSince1970: 100)
    let original = [existing]

    var updated = existing
    updated.id = UUID()
    updated.title = "Imported update"
    updated.createdAt = Date(timeIntervalSince1970: 999)
    let inserted = ArticleDraft.fixture(
      title: "Inserted",
      siteProfileID: profileID,
      repositoryPath: "content/inserted.md"
    )
    let conflicted = ArticleDraft.fixture(
      title: "Conflict",
      siteProfileID: profileID,
      repositoryPath: "content/conflict.md"
    )

    let plan = LocalContentImportMergeService().makePlan(
      existingDrafts: original,
      result: LocalContentImportResult(
        importedDrafts: [updated, inserted, conflicted],
        skippedPaths: ["content/unsupported.txt"]
      ),
      canInsert: { $0 != "content/conflict.md" }
    )

    #expect(original[0].title == "Existing")
    #expect(plan.summary.insertedCount == 1)
    #expect(plan.summary.updatedCount == 1)
    #expect(plan.summary.skippedCount == 2)
    #expect(plan.conflictCount == 1)
    #expect(plan.replacedDrafts == [existing])
    #expect(plan.drafts.count == 2)
    #expect(plan.drafts[0].id == existing.id)
    #expect(plan.drafts[0].createdAt == existing.createdAt)
    #expect(plan.drafts[0].title == "Imported update")
  }
}

private extension ArticleDraft {
  static func fixture(
    title: String,
    siteProfileID: UUID,
    repositoryPath: String
  ) -> ArticleDraft {
    ArticleDraft(
      siteProfileID: siteProfileID,
      title: title,
      slug: title.lowercased().replacingOccurrences(of: " ", with: "-"),
      tags: [],
      categories: [],
      authors: [],
      summary: "",
      bodyMarkdown: "Body",
      repositoryPath: repositoryPath
    )
  }
}
