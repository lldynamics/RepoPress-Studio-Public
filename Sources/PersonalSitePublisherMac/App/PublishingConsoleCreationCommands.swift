import SwiftUI

/// The scene-local target for the primary New command. Keeping this decision
/// separate from the menu makes the focused-scene behavior explicit and
/// testable: settings and other contexts have no creation target.
enum PublishingConsoleCreationTarget: Equatable {
  case writing
  case knowledgeLibrary
  case unavailable

  init(
    writingAvailable: Bool,
    knowledgeLibraryAvailable: Bool
  ) {
    if writingAvailable {
      self = .writing
    } else if knowledgeLibraryAvailable {
      self = .knowledgeLibrary
    } else {
      self = .unavailable
    }
  }

  var primaryTitle: String {
    switch self {
    case .writing: return String(localized: "新建文章")
    case .knowledgeLibrary: return String(localized: "新建笔记")
    case .unavailable: return String(localized: "新建")
    }
  }

  var isEnabled: Bool {
    self != .unavailable
  }
}

/// New-item commands owned by the scene. `PublishingConsoleCommands` should
/// install this helper in place of its old `.newItem` group.
struct PublishingConsoleCreationCommands: Commands {
  @WorkspaceModuleVisibilityStorage private var moduleVisibility
  @FocusedObject private var commandRouter: WorkspaceSceneCommandRouter?
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button(String(localized: "新建窗口")) {
        openWindow(id: "main-workbench")
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])

      Divider()

      Button(primaryTarget.primaryTitle) {
        performPrimaryCreation()
      }
      .keyboardShortcut("n")
      .disabled(!primaryTarget.isEnabled)

      Button(String(localized: "新建通用草稿")) {
        commandRouter?.writingDraftCommandActions?.createGeneralDraft?()
      }
      .disabled(commandRouter?.writingDraftCommandActions?.createGeneralDraft == nil)

      Button(String(localized: "从模板新建文章…")) {
        commandRouter?.writingDraftCommandActions?.presentTemplatePicker?()
      }
      .disabled(commandRouter?.writingDraftCommandActions?.presentTemplatePicker == nil)
    }
  }

  private var primaryTarget: PublishingConsoleCreationTarget {
    PublishingConsoleCreationTarget(
      writingAvailable: commandRouter?.writingDraftCommandActions != nil,
      knowledgeLibraryAvailable: commandRouter?.knowledgeLibraryCommandActions != nil
        && moduleVisibility.libraryEnabled
    )
  }

  private func performPrimaryCreation() {
    Self.performPrimaryCreation(
      target: primaryTarget,
      writing: commandRouter?.writingDraftCommandActions,
      knowledgeLibrary: commandRouter?.knowledgeLibraryCommandActions
    )
  }

  static func performPrimaryCreation(
    target: PublishingConsoleCreationTarget,
    writing: WritingDraftCommandActions?,
    knowledgeLibrary: KnowledgeLibraryCommandActions?
  ) {
    switch target {
    case .writing:
      writing?.createDraft()
    case .knowledgeLibrary:
      knowledgeLibrary?.createNote()
    case .unavailable:
      break
    }
  }
}
