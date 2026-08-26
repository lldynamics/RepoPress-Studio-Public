import Combine
import Foundation
import PublishingWorkbenchCore

/// Window-owned navigation state for the main `WindowGroup` scene.
///
/// Section and draft identity are remembered per window. The shared Store is
/// still the compatibility execution context, so the key window activates its
/// remembered values atomically instead of letting background windows mutate
/// app-wide selection.
@MainActor
final class WorkspaceWindowSession: ObservableObject {
  struct StorageValues: Equatable {
    let windowIDRawValue: String
    let selectedSectionRawValue: String
    let selectedDraftIDRawValue: String
  }

  @Published private(set) var windowID: UUID
  @Published private(set) var selectedSection: WorkspaceSection
  @Published private(set) var selectedDraftID: UUID?
  private(set) var isKeyWindow = false

  private var didRestoreStorage = false

  init(
    windowID: UUID = UUID(),
    selectedSection: WorkspaceSection,
    selectedDraftID: UUID? = nil
  ) {
    self.windowID = windowID
    self.selectedSection = selectedSection
    self.selectedDraftID = selectedDraftID
  }

  var storageValues: StorageValues {
    StorageValues(
      windowIDRawValue: windowID.uuidString,
      selectedSectionRawValue: selectedSection.rawValue,
      selectedDraftIDRawValue: selectedDraftID?.uuidString ?? ""
    )
  }

  /// Applies SceneStorage once. Invalid legacy or partial values fall back to
  /// the current shared section and a newly generated stable window identity.
  @discardableResult
  func restoreStorageIfNeeded(
    windowIDRawValue: String,
    selectedSectionRawValue: String,
    fallbackSection: WorkspaceSection,
    selectedDraftIDRawValue: String = "",
    fallbackDraftID: UUID? = nil
  ) -> StorageValues {
    guard !didRestoreStorage else { return storageValues }
    didRestoreStorage = true

    if let restoredWindowID = UUID(uuidString: windowIDRawValue) {
      windowID = restoredWindowID
    }
    selectedSection =
      WorkspaceSection(rawValue: selectedSectionRawValue)
      ?? fallbackSection
    selectedDraftID = UUID(uuidString: selectedDraftIDRawValue) ?? fallbackDraftID
    return storageValues
  }

  /// Activates this window's section as the compatibility context used by
  /// existing app-wide commands. Resigning key status never mutates the Store.
  func setKeyWindow(
    _ isKeyWindow: Bool,
    activateSharedContext: (WorkspaceSection, UUID?) -> Void
  ) {
    guard self.isKeyWindow != isKeyWindow else { return }
    self.isKeyWindow = isKeyWindow
    if isKeyWindow {
      activateSharedContext(selectedSection, selectedDraftID)
    }
  }

  func selectSection(
    _ section: WorkspaceSection,
    activateSharedSection: (WorkspaceSection) -> Void
  ) {
    if selectedSection != section {
      selectedSection = section
    }
    if isKeyWindow {
      activateSharedSection(section)
    }
  }

  /// Selects the draft for this window. A background window only updates its
  /// own intent; the shared Store is activated after AppKit makes the window
  /// key (or immediately when it is already key).
  func selectDraft(
    _ draftID: UUID?,
    activateSharedDraft: (UUID?) -> Void
  ) {
    if selectedDraftID != draftID {
      selectedDraftID = draftID
    }
    if isKeyWindow {
      activateSharedDraft(draftID)
    }
  }

  /// Applies section and draft as one window navigation intent. This is used
  /// by deep links and context-menu focus actions so a key-window activation
  /// cannot observe a half-updated section/draft pair.
  func selectContext(
    section: WorkspaceSection,
    draftID: UUID?,
    activateSharedContext: (WorkspaceSection, UUID?) -> Void
  ) {
    selectedSection = section
    selectedDraftID = draftID
    if isKeyWindow {
      activateSharedContext(section, draftID)
    }
  }

  /// Replays the current window intent into the shared compatibility Store.
  /// Calling this is explicit and safe for commands that must run against the
  /// key window's draft, even when the selection itself did not change.
  func activateSharedContext(
    _ activateSharedContext: (WorkspaceSection, UUID?) -> Void
  ) {
    guard isKeyWindow else { return }
    activateSharedContext(selectedSection, selectedDraftID)
  }

  /// Deep legacy navigation still writes the shared Store. Only the key
  /// window adopts that change; background windows retain their own section.
  func receiveSharedSection(_ section: WorkspaceSection) {
    guard isKeyWindow, selectedSection != section else { return }
    selectedSection = section
  }

  /// Deep legacy navigation still writes the shared Store. Only the key
  /// window adopts that draft; background windows retain their own memory.
  func receiveSharedDraft(_ draftID: UUID?) {
    guard isKeyWindow, selectedDraftID != draftID else { return }
    selectedDraftID = draftID
  }

  /// Removes a dangling per-window identity before the window becomes key.
  /// A nil selection remains meaningful; only a deleted non-nil identity
  /// falls back to the current shared context.
  func reconcileDraftSelection(
    validDraftIDs: Set<UUID>,
    fallbackDraftID: UUID?
  ) {
    guard let selectedDraftID, !validDraftIDs.contains(selectedDraftID) else { return }
    self.selectedDraftID = fallbackDraftID.flatMap { fallback in
      validDraftIDs.contains(fallback) ? fallback : nil
    }
  }
}
