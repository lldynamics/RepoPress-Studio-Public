import PublishingKnowledgeCore
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
      let date = knowledge.documentSort.field == .updatedAt
        ? document.updatedAt
        : document.importedAt
      // A byte count describes the downloaded page container, which is not
      // useful when browsing web sources. The detail inspector shows readable
      // text statistics once the extracted body is available.
      let size =
        document.kind == .webpage
        ? nil
        : ByteCountFormatter.string(fromByteCount: document.sourceByteCount, countStyle: .file)
      let relativeDate = date.formatted(
        .relative(presentation: .named, unitsStyle: .abbreviated)
      )
      let subtitle: String
      if let size {
        subtitle =
          knowledge.documentSort.field == .fileSize
          ? "\(size) · \(document.kind.localizedDisplayName) · \(relativeDate)"
          : "\(document.kind.localizedDisplayName) · \(relativeDate) · \(size)"
      } else {
        subtitle = "\(document.kind.localizedDisplayName) · \(relativeDate)"
      }
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
