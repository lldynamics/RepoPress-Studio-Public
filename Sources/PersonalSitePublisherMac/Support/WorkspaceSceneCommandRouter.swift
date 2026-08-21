import Combine
import Foundation
import PublishingWorkbenchCore

@MainActor
final class WorkspaceSceneCommandRouter: @preconcurrency ObservableObject {
  struct RootUpdateKey: Equatable {
    let selectedSection: WorkspaceSection
    let isFocusModeActive: Bool
    let canToggleFocusMode: Bool
    let repositorySourceHasUnsavedChanges: Bool
  }

  struct MarkdownPresentation: Equatable {
    let draftID: UUID
    let canRewriteSelection: Bool
    let canUseFindReplace: Bool
  }

  struct RSSPresentation: Equatable {
    let canNavigatePrevious: Bool
    let canNavigateNext: Bool
    let canActOnArticle: Bool
  }

  struct RepositorySourcePresentation: Equatable {
    let hasDocument: Bool
    let canSave: Bool
  }

  let objectWillChange = ObservableObjectPublisher()

  private(set) var publishDrawerCommandAction: PublishDrawerCommandAction?
  private(set) var localSitePreviewCommandAction: LocalSitePreviewCommandAction?
  private(set) var workspaceCommandPaletteAction: WorkspaceCommandPaletteAction?
  private(set) var workspaceFirstRunSetupCommandAction: WorkspaceFirstRunSetupCommandAction?
  private(set) var draftFullTextSearchAction: DraftFullTextSearchAction?
  private(set) var workspaceFocusModeCommandAction: WorkspaceFocusModeCommandAction?
  private(set) var repositorySourceSessionCommandActions: RepositorySourceSessionCommandActions?

  private(set) var markdownEditorCommandActions: MarkdownEditorCommandActions?
  private(set) var writingDraftCommandActions: WritingDraftCommandActions?
  private(set) var knowledgeLibraryCommandActions: KnowledgeLibraryCommandActions?
  private(set) var repositorySourceEditorCommandActions: RepositorySourceEditorCommandActions?
  private(set) var rssReaderCommandActions: RSSReaderCommandActions?

  private var markdownOwner: UUID?
  private var writingOwner: UUID?
  private var knowledgeOwner: UUID?
  private var repositorySourceOwner: UUID?
  private var rssOwner: UUID?
  private var isChangeNotificationScheduled = false

  func updateRoot(
    publishDrawerCommandAction: PublishDrawerCommandAction,
    localSitePreviewCommandAction: LocalSitePreviewCommandAction,
    workspaceCommandPaletteAction: WorkspaceCommandPaletteAction,
    workspaceFirstRunSetupCommandAction: WorkspaceFirstRunSetupCommandAction,
    draftFullTextSearchAction: DraftFullTextSearchAction,
    workspaceFocusModeCommandAction: WorkspaceFocusModeCommandAction,
    repositorySourceSessionCommandActions: RepositorySourceSessionCommandActions
  ) {
    mutatePresentation {
      self.publishDrawerCommandAction = publishDrawerCommandAction
      self.localSitePreviewCommandAction = localSitePreviewCommandAction
      self.workspaceCommandPaletteAction = workspaceCommandPaletteAction
      self.workspaceFirstRunSetupCommandAction = workspaceFirstRunSetupCommandAction
      self.draftFullTextSearchAction = draftFullTextSearchAction
      self.workspaceFocusModeCommandAction = workspaceFocusModeCommandAction
      self.repositorySourceSessionCommandActions = repositorySourceSessionCommandActions
    }
  }

  func clearAll() {
    mutatePresentation {
      publishDrawerCommandAction = nil
      localSitePreviewCommandAction = nil
      workspaceCommandPaletteAction = nil
      workspaceFirstRunSetupCommandAction = nil
      draftFullTextSearchAction = nil
      workspaceFocusModeCommandAction = nil
      repositorySourceSessionCommandActions = nil

      markdownOwner = nil
      writingOwner = nil
      knowledgeOwner = nil
      repositorySourceOwner = nil
      rssOwner = nil
      markdownEditorCommandActions = nil
      writingDraftCommandActions = nil
      knowledgeLibraryCommandActions = nil
      repositorySourceEditorCommandActions = nil
      rssReaderCommandActions = nil
    }
  }

  func registerMarkdownEditor(_ actions: MarkdownEditorCommandActions, owner: UUID) {
    mutatePresentation {
      markdownOwner = owner
      markdownEditorCommandActions = actions
    }
  }

  func unregisterMarkdownEditor(owner: UUID) {
    guard markdownOwner == owner else { return }
    mutatePresentation {
      markdownOwner = nil
      markdownEditorCommandActions = nil
    }
  }

  func registerWritingDrafts(_ actions: WritingDraftCommandActions, owner: UUID) {
    mutatePresentation {
      writingOwner = owner
      writingDraftCommandActions = actions
    }
  }

  func unregisterWritingDrafts(owner: UUID) {
    guard writingOwner == owner else { return }
    mutatePresentation {
      writingOwner = nil
      writingDraftCommandActions = nil
    }
  }

  func registerKnowledgeLibrary(_ actions: KnowledgeLibraryCommandActions, owner: UUID) {
    mutatePresentation {
      knowledgeOwner = owner
      knowledgeLibraryCommandActions = actions
    }
  }

  func unregisterKnowledgeLibrary(owner: UUID) {
    guard knowledgeOwner == owner else { return }
    mutatePresentation {
      knowledgeOwner = nil
      knowledgeLibraryCommandActions = nil
    }
  }

  func registerRepositorySource(
    _ actions: RepositorySourceEditorCommandActions,
    owner: UUID
  ) {
    mutatePresentation {
      repositorySourceOwner = owner
      repositorySourceEditorCommandActions = actions
    }
  }

  func unregisterRepositorySource(owner: UUID) {
    guard repositorySourceOwner == owner else { return }
    mutatePresentation {
      repositorySourceOwner = nil
      repositorySourceEditorCommandActions = nil
    }
  }

  func registerRSSReader(_ actions: RSSReaderCommandActions?, owner: UUID) {
    mutatePresentation {
      rssOwner = owner
      rssReaderCommandActions = actions
    }
  }

  func unregisterRSSReader(owner: UUID) {
    guard rssOwner == owner else { return }
    mutatePresentation {
      rssOwner = nil
      rssReaderCommandActions = nil
    }
  }

  private func mutatePresentation(_ mutation: () -> Void) {
    let previous = presentationSnapshot
    mutation()
    guard presentationSnapshot != previous else { return }
    scheduleChangeNotification()
  }

  private var presentationSnapshot: PresentationSnapshot {
    PresentationSnapshot(
      hasRootActions: publishDrawerCommandAction != nil,
      focusModeIsActive: workspaceFocusModeCommandAction?.isActive,
      focusModeCanToggle: workspaceFocusModeCommandAction?.canToggle,
      repositorySourceHasUnsavedChanges: repositorySourceSessionCommandActions?.hasUnsavedChanges,
      markdownOwner: markdownOwner,
      markdown: markdownEditorCommandActions.map {
        MarkdownPresentation(
          draftID: $0.draftID,
          canRewriteSelection: $0.canRewriteSelection,
          canUseFindReplace: $0.canUseFindReplace
        )
      },
      writingOwner: writingOwner,
      hasWritingDraftActions: writingDraftCommandActions != nil,
      knowledgeOwner: knowledgeOwner,
      hasKnowledgeLibraryActions: knowledgeLibraryCommandActions != nil,
      repositorySourceOwner: repositorySourceOwner,
      repositorySource: repositorySourceEditorCommandActions.map {
        RepositorySourcePresentation(hasDocument: $0.hasDocument, canSave: $0.canSave)
      },
      rssOwner: rssOwner,
      rss: rssReaderCommandActions.map {
        RSSPresentation(
          canNavigatePrevious: $0.canNavigatePrevious,
          canNavigateNext: $0.canNavigateNext,
          canActOnArticle: $0.canActOnArticle
        )
      }
    )
  }

  private func scheduleChangeNotification() {
    guard !isChangeNotificationScheduled else { return }
    isChangeNotificationScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.isChangeNotificationScheduled = false
      self.objectWillChange.send()
    }
  }

  private struct PresentationSnapshot: Equatable {
    let hasRootActions: Bool
    let focusModeIsActive: Bool?
    let focusModeCanToggle: Bool?
    let repositorySourceHasUnsavedChanges: Bool?
    let markdownOwner: UUID?
    let markdown: MarkdownPresentation?
    let writingOwner: UUID?
    let hasWritingDraftActions: Bool
    let knowledgeOwner: UUID?
    let hasKnowledgeLibraryActions: Bool
    let repositorySourceOwner: UUID?
    let repositorySource: RepositorySourcePresentation?
    let rssOwner: UUID?
    let rss: RSSPresentation?
  }
}

extension MarkdownEditorCommandActions {
  var sceneCommandPresentation: WorkspaceSceneCommandRouter.MarkdownPresentation {
    WorkspaceSceneCommandRouter.MarkdownPresentation(
      draftID: draftID,
      canRewriteSelection: canRewriteSelection,
      canUseFindReplace: canUseFindReplace
    )
  }
}

extension RSSReaderCommandActions {
  var sceneCommandPresentation: WorkspaceSceneCommandRouter.RSSPresentation {
    WorkspaceSceneCommandRouter.RSSPresentation(
      canNavigatePrevious: canNavigatePrevious,
      canNavigateNext: canNavigateNext,
      canActOnArticle: canActOnArticle
    )
  }
}

extension RepositorySourceEditorCommandActions {
  var sceneCommandPresentation: WorkspaceSceneCommandRouter.RepositorySourcePresentation {
    WorkspaceSceneCommandRouter.RepositorySourcePresentation(
      hasDocument: hasDocument,
      canSave: canSave
    )
  }
}
