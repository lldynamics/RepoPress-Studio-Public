import PublishingWorkbenchCore
import SwiftUI

struct EditorCenterColumn: View {
  let store: WorkbenchStore
  let contentHealthFilter: ContentHealthContextFilter
  @Binding var repositoryContextStage: RepositoryContextStage
  @StateObject private var editorState: WorkbenchEditorNavigationFeatureFacade
  @ObservedObject private var knowledge: KnowledgeStore

  init(
    store: WorkbenchStore,
    contentHealthFilter: ContentHealthContextFilter,
    repositoryContextStage: Binding<RepositoryContextStage>
  ) {
    self.store = store
    self.contentHealthFilter = contentHealthFilter
    _repositoryContextStage = repositoryContextStage
    _editorState = StateObject(
      wrappedValue: WorkbenchEditorNavigationFeatureFacade(store: store)
    )
    _knowledge = ObservedObject(wrappedValue: store.knowledge)
  }

  var body: some View {
    Group {
      switch editorState.selectedSection.centerSurface {
      case .knowledgeLibrary:
        KnowledgeLibraryDetailView(knowledge: store.knowledge)
      case .repository:
        RepositoryWorkspaceView(store: store, stage: $repositoryContextStage)
      case .images:
        ImageWorkbenchView(store: store)
      case .contentHealth:
        ContentHealthDetailView(store: store, filter: contentHealthFilter)
      case .siteStarter:
        SiteStarterWorkspaceView(store: store)
      case .generalDrafts:
        GeneralDraftLibraryDetailView(store: store)
      case .editor:
        writingEditorDetail
      }
    }
    .onAppear {
      ensureDraftIfNeeded()
    }
    .onChange(of: editorState.activeProfileID) { _, _ in
      ensureDraftIfNeeded()
    }
    .onChange(of: editorState.selectedSection) { _, _ in
      ensureDraftIfNeeded()
    }
    .onChange(of: knowledge.statusMessage) { _, message in
      guard editorState.selectedSection.centerSurface == .knowledgeLibrary,
            let message else { return }
      EditorAccessibilityAnnouncementCenter.announce(message)
    }
  }

  private func ensureDraftIfNeeded() {
    if editorState.selectedSection.requiresEditableDraftForCenterSurface {
      store.ensureEditableDraftSelected()
    }
  }

  @ViewBuilder
  private var writingEditorDetail: some View {
    if let fallbackDraft = editorState.selectedDraft {
      let draft = Binding<ArticleDraft>(
        get: { editorState.selectedDraft ?? fallbackDraft },
        set: { store.updateDraftFromEditor($0) }
      )

      MacMarkdownComposerView(draft: draft, store: store)
    } else {
      EmptyStateView(
        title: "还没有草稿",
        message: "新建一篇文章后，中间区域只负责正文编辑；预览通过编辑器顶部按钮打开。",
        systemImage: "doc.badge.plus"
      )
    }
  }

}
