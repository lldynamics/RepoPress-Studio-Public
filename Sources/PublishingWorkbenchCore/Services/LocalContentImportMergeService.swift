import Foundation

public struct LocalContentImportMergePlan: Sendable {
  public let drafts: [ArticleDraft]
  public let replacedDrafts: [ArticleDraft]
  public let summary: LocalContentImportMergeSummary
  public let conflictCount: Int

  public init(
    drafts: [ArticleDraft],
    replacedDrafts: [ArticleDraft],
    summary: LocalContentImportMergeSummary,
    conflictCount: Int
  ) {
    self.drafts = drafts
    self.replacedDrafts = replacedDrafts
    self.summary = summary
    self.conflictCount = conflictCount
  }
}

/// Builds a deterministic import merge plan without mutating the publishing
/// store. Store orchestration remains responsible for version history,
/// persistence and user-facing progress messages.
public struct LocalContentImportMergeService: Sendable {
  public init() {}

  public func makePlan(
    existingDrafts: [ArticleDraft],
    result: LocalContentImportResult,
    canReplace: (ArticleDraft, String) -> Bool = { _, _ in true },
    canInsert: (String) -> Bool = { _ in true }
  ) -> LocalContentImportMergePlan {
    var drafts = existingDrafts
    var replacedDrafts: [ArticleDraft] = []
    var insertedCount = 0
    var updatedCount = 0
    var conflictCount = 0

    for imported in result.importedDrafts {
      let repositoryPath = imported.repositoryPath?.normalizedRelativePath() ?? ""
      if let index = drafts.firstIndex(where: {
        $0.siteProfileID == imported.siteProfileID
          && $0.repositoryPath == imported.repositoryPath
      }) {
        let existing = drafts[index]
        guard canReplace(existing, repositoryPath) else {
          conflictCount += 1
          continue
        }

        var updated = imported
        updated.id = existing.id
        updated.createdAt = existing.createdAt
        guard existing != updated else { continue }

        replacedDrafts.append(existing)
        // A repository import can replace list-visible front matter as well
        // as the body, so it is a real metadata update for ordering/locking.
        updated.markUpdated(replacing: existing)
        drafts[index] = updated
        updatedCount += 1
      } else {
        guard canInsert(repositoryPath) else {
          conflictCount += 1
          continue
        }
        drafts.append(imported)
        insertedCount += 1
      }
    }

    return LocalContentImportMergePlan(
      drafts: drafts,
      replacedDrafts: replacedDrafts,
      summary: LocalContentImportMergeSummary(
        insertedCount: insertedCount,
        updatedCount: updatedCount,
        skippedCount: result.skippedPaths.count + conflictCount
      ),
      conflictCount: conflictCount
    )
  }
}
