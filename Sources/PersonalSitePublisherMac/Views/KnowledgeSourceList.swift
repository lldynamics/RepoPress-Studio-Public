import PublishingWorkbenchCore
import SwiftUI


struct KnowledgeDocumentListRowSnapshot: Identifiable {
  var id: UUID { document.id }
  let document: KnowledgeDocument
  let subtitle: String
}

struct KnowledgeSourceListPresentationSnapshot {
  let revision: UInt64
  let documentRows: [KnowledgeDocumentListRowSnapshot]
  let searchResults: [KnowledgeSearchResult]
  let searchGroups: [KnowledgeSearchDocumentGroup]

  @MainActor
  static func make(knowledge: KnowledgeStore) -> Self {
    let documentRows = knowledge.visibleDocuments.map { document in
      let size = ByteCountFormatter.string(
        fromByteCount: document.sourceByteCount,
        countStyle: .file
      )
      let date = knowledge.documentSort.field == .updatedAt
        ? document.updatedAt
        : document.importedAt
      let relativeDate = date.formatted(
        .relative(presentation: .named, unitsStyle: .abbreviated)
      )
      let subtitle = knowledge.documentSort.field == .fileSize
        ? "\(size) · \(document.kind.localizedDisplayName) · \(relativeDate)"
        : "\(document.kind.localizedDisplayName) · \(relativeDate) · \(size)"
      return KnowledgeDocumentListRowSnapshot(document: document, subtitle: subtitle)
    }

    let searchResults = knowledge.visibleSearchResults
    var searchGroups: [KnowledgeSearchDocumentGroup] = []
    var indices: [UUID: Int] = [:]
    for result in searchResults {
      if let index = indices[result.document.id] {
        searchGroups[index].results.append(result)
      } else {
        indices[result.document.id] = searchGroups.count
        searchGroups.append(
          KnowledgeSearchDocumentGroup(document: result.document, results: [result])
        )
      }
    }
    return Self(
      revision: knowledge.listPresentationRevision,
      documentRows: documentRows,
      searchResults: searchResults,
      searchGroups: searchGroups
    )
  }
}

enum FolderEditorMode {
  case create
  case rename(UUID)
}

struct KnowledgeSearchDocumentGroup: Identifiable {
  var id: UUID { document.id }
  let document: KnowledgeDocument
  var results: [KnowledgeSearchResult]
}
