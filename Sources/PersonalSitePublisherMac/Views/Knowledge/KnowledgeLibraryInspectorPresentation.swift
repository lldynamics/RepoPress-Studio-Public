import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeSourceHistoryPresentation: Identifiable {
  let id = UUID()
  let documentID: UUID
  let preparesLocalRepairOnAppear: Bool
}

struct KnowledgeLibraryInspectorPresentationState {
  var metadataDocument: KnowledgeDocument?
  var annotationDraft: KnowledgeAnnotation?
  var sourceHistory: KnowledgeSourceHistoryPresentation?

  mutating func editMetadata(for document: KnowledgeDocument) {
    metadataDocument = document
  }

  mutating func addAnnotation(to document: KnowledgeDocument) {
    annotationDraft = KnowledgeAnnotation(
      documentID: document.id,
      revisionID: document.currentRevisionID,
      note: ""
    )
  }

  mutating func annotateSearchResult(
    _ result: KnowledgeSearchResult?,
    in document: KnowledgeDocument
  ) {
    guard let result else {
      addAnnotation(to: document)
      return
    }
    annotationDraft = KnowledgeAnnotation(
      documentID: document.id,
      revisionID: result.chunk.revisionID,
      chunkID: result.chunk.id,
      locator: result.chunk.locator?.nilIfEmpty ?? result.chunk.headingPath?.nilIfEmpty,
      highlightedText: String(result.chunk.content.prefix(4_000)),
      note: ""
    )
  }

  mutating func editAnnotation(_ annotation: KnowledgeAnnotation) {
    annotationDraft = annotation
  }

  mutating func openSourceHistory(
    for documentID: UUID,
    preparesLocalRepairOnAppear: Bool = false
  ) {
    sourceHistory = KnowledgeSourceHistoryPresentation(
      documentID: documentID,
      preparesLocalRepairOnAppear: preparesLocalRepairOnAppear
    )
  }

  mutating func dismissAll() {
    metadataDocument = nil
    annotationDraft = nil
    sourceHistory = nil
  }
}

private struct KnowledgeLibraryInspectorSheetPresenter: ViewModifier {
  let knowledge: KnowledgeStore
  @Binding var presentation: KnowledgeLibraryInspectorPresentationState

  func body(content: Content) -> some View {
    content
      .sheet(item: $presentation.metadataDocument) { document in
        KnowledgeMetadataEditorView(document: document) { metadata in
          await knowledge.updateMetadata(documentID: document.id, metadata: metadata)
        }
      }
      .sheet(item: $presentation.annotationDraft) { annotation in
        KnowledgeAnnotationEditorView(annotation: annotation) { updated in
          await knowledge.saveAnnotation(updated)
        }
      }
      .sheet(item: $presentation.sourceHistory) { sourceHistory in
        KnowledgeSourceHistoryView(
          knowledge: knowledge,
          documentID: sourceHistory.documentID,
          preparesLocalRepairOnAppear: sourceHistory.preparesLocalRepairOnAppear
        )
      }
  }
}

extension View {
  func knowledgeLibraryInspectorSheets(
    knowledge: KnowledgeStore,
    presentation: Binding<KnowledgeLibraryInspectorPresentationState>
  ) -> some View {
    modifier(
      KnowledgeLibraryInspectorSheetPresenter(
        knowledge: knowledge,
        presentation: presentation
      )
    )
  }
}
