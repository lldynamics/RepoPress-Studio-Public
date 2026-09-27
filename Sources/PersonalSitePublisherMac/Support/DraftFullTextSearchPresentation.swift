import Foundation
import PublishingWorkbenchCore

struct DraftFullTextSearchRequest: Equatable, Sendable {
  let query: String
  let scope: DraftFullTextSearchScope
}

struct DraftFullTextSearchInput: Sendable {
  let draft: ArticleDraft
  let bodyMarkdown: String
}

enum DraftFullTextSearchPreparation {
  static func prepare(
    inputs: [DraftFullTextSearchInput],
    masksPrivateContent: Bool
  ) -> [ArticleDraft] {
    inputs.map { input in
      var draft = input.draft
      draft.bodyMarkdown = input.bodyMarkdown
      guard masksPrivateContent, draft.isPrivate else { return draft }
      draft.slug = ""
      draft.summary = ""
      draft.bodyMarkdown = ""
      draft.tags = []
      draft.categories = []
      draft.authors = []
      draft.detachFromRepository()
      return draft
    }
  }
}

extension DraftFullTextSearchScope {
  func includes(_ draft: ArticleDraft, activeProfileID: UUID) -> Bool {
    switch self {
    case .allDrafts: true
    case .currentSite: draft.belongs(toSiteProfileID: activeProfileID)
    case .allSites: !draft.isGeneralDraft
    case .generalDrafts: draft.isGeneralDraft
    }
  }

  var localizedDisplayName: String {
    switch self {
    case .allDrafts: String(localized: "全部文章")
    case .currentSite: String(localized: "当前站点")
    case .allSites: String(localized: "全部站点")
    case .generalDrafts: String(localized: "通用草稿")
    }
  }
}

struct DraftFullTextSearchGroup: Identifiable, Equatable, Sendable {
  var id: UUID { draftID }
  let draftID: UUID
  let siteProfileID: UUID
  let title: String
  var hits: [DraftFullTextSearchHit]
}

/// A single linear projection of search hits into the grouped and keyboard-
/// navigable forms consumed by the command palette. Keeping it in state avoids rebuilding
/// groups and repeatedly flattening them on every SwiftUI body evaluation.
struct DraftFullTextSearchPresentationSnapshot: Equatable, Sendable {
  static let empty = DraftFullTextSearchPresentationSnapshot(hits: [])

  let groups: [DraftFullTextSearchGroup]
  let displayedHits: [DraftFullTextSearchHit]
  private let displayedIndexByID: [DraftFullTextSearchHitID: Int]

  init(hits: [DraftFullTextSearchHit]) {
    var groups: [DraftFullTextSearchGroup] = []
    var groupIndexByDraftID: [UUID: Int] = [:]
    groupIndexByDraftID.reserveCapacity(hits.count)

    for hit in hits {
      if let index = groupIndexByDraftID[hit.draftID] {
        groups[index].hits.append(hit)
      } else {
        groupIndexByDraftID[hit.draftID] = groups.count
        groups.append(
          DraftFullTextSearchGroup(
            draftID: hit.draftID,
            siteProfileID: hit.siteProfileID,
            title: hit.draftTitle,
            hits: [hit]
          )
        )
      }
    }

    let displayedHits = groups.flatMap(\.hits)
    var displayedIndexByID: [DraftFullTextSearchHitID: Int] = [:]
    displayedIndexByID.reserveCapacity(displayedHits.count)
    for (index, hit) in displayedHits.enumerated() {
      displayedIndexByID[hit.id] = index
    }

    self.groups = groups
    self.displayedHits = displayedHits
    self.displayedIndexByID = displayedIndexByID
  }

  func hit(withID id: DraftFullTextSearchHitID) -> DraftFullTextSearchHit? {
    guard let index = displayedIndexByID[id] else { return nil }
    return displayedHits[index]
  }

  func index(of id: DraftFullTextSearchHitID) -> Int? {
    displayedIndexByID[id]
  }
}

extension DraftFullTextSearchField {
  var localizedDisplayName: String {
    switch self {
    case .title: String(localized: "标题")
    case .summary: String(localized: "摘要")
    case .body: String(localized: "正文")
    case .slug: "Slug"
    case .tags: String(localized: "标签")
    case .categories: String(localized: "分类")
    case .authors: String(localized: "作者")
    case .repositoryPath: String(localized: "仓库路径")
    }
  }

  var systemImage: String {
    switch self {
    case .title: "doc.plaintext"
    case .summary: "text.alignleft"
    case .body: "doc.text"
    case .slug: "link"
    case .tags: "tag"
    case .categories: "folder"
    case .authors: "person.2"
    case .repositoryPath: "point.topleft.down.to.point.bottomright.curvepath"
    }
  }
}
