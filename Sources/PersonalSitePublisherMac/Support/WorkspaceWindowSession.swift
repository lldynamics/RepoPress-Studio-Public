import Combine
import Foundation
import PublishingWorkbenchCore
import SwiftUI

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
  @Published private(set) var isKeyWindow = false
  /// Writing-list controls belong to this window for the same reason as the
  /// selected draft: another window must not replace a user's active filter
  /// or folder expansion while it is in the background.
  let writingListState: WritingListWindowPresentationState

  private var didRestoreStorage = false
  private let editorFocusRequestDelivery: WorkspaceEditorFocusRequestDelivery

  init(
    windowID: UUID = UUID(),
    selectedSection: WorkspaceSection,
    selectedDraftID: UUID? = nil,
    writingListState: WritingListWindowPresentationState = WritingListWindowPresentationState(),
    editorFocusRequestDelivery: WorkspaceEditorFocusRequestDelivery = .shared
  ) {
    self.windowID = windowID
    self.selectedSection = selectedSection
    self.selectedDraftID = selectedDraftID
    self.writingListState = writingListState
    self.editorFocusRequestDelivery = editorFocusRequestDelivery
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

  /// Records that this WindowGroup initiated an editor-location request while
  /// a sheet may have temporarily made it non-key. The shared Store keeps the
  /// request for compatibility, while this delivery ledger keeps another
  /// window displaying the same draft from applying it.
  func registerEditorFocusRequest(_ requestID: UUID) {
    editorFocusRequestDelivery.register(requestID, for: windowID)
  }

  /// Returns true exactly once for the window allowed to apply a location
  /// request. Legacy requests that have no explicit owner may be claimed only
  /// by the current key window, never by a background editor.
  func consumeEditorFocusRequest(_ requestID: UUID) -> Bool {
    editorFocusRequestDelivery.consume(
      requestID,
      for: windowID,
      isKeyWindow: isKeyWindow
    )
  }
}

/// App-lifetime, bounded delivery ledger for transient editor focus requests.
/// It deliberately does not clear the Store's request: clearing it globally
/// lets a background window race the presenting window and loses restoration
/// information for the request owner.
@MainActor
final class WorkspaceEditorFocusRequestDelivery {
  static let shared = WorkspaceEditorFocusRequestDelivery()

  private struct Entry {
    let ownerWindowID: UUID
    var wasConsumed = false
  }

  private var entries: [UUID: Entry] = [:]
  private var insertionOrder: [UUID] = []
  private let maximumEntryCount = 128

  var entryCount: Int { entries.count }

  func register(_ requestID: UUID, for windowID: UUID) {
    guard entries[requestID] == nil else { return }
    entries[requestID] = Entry(ownerWindowID: windowID)
    insertionOrder.append(requestID)
    trimEntriesIfNeeded()
  }

  func consume(_ requestID: UUID, for windowID: UUID, isKeyWindow: Bool) -> Bool {
    if var entry = entries[requestID] {
      guard entry.ownerWindowID == windowID, !entry.wasConsumed else { return false }
      entry.wasConsumed = true
      entries[requestID] = entry
      return true
    }

    // Requests issued by older call sites have no explicit owner. Retain the
    // historic key-window behavior, then make that choice durable so a later
    // remount or another window on the same draft cannot replay it.
    guard isKeyWindow else { return false }
    entries[requestID] = Entry(ownerWindowID: windowID, wasConsumed: true)
    insertionOrder.append(requestID)
    trimEntriesIfNeeded()
    return true
  }

  private func trimEntriesIfNeeded() {
    guard insertionOrder.count > maximumEntryCount else { return }
    let excessCount = insertionOrder.count - maximumEntryCount
    let removed = Array(insertionOrder.prefix(excessCount))
    insertionOrder.removeFirst(excessCount)
    for requestID in removed {
      entries.removeValue(forKey: requestID)
    }
  }
}

private struct WorkspaceWindowIDEnvironmentKey: EnvironmentKey {
  static let defaultValue: UUID? = nil
}

private struct WorkspaceWindowSessionEnvironmentKey: EnvironmentKey {
  static let defaultValue: WorkspaceWindowSession? = nil
}

private struct WorkspaceWindowIsKeyEnvironmentKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var workspaceWindowID: UUID? {
    get { self[WorkspaceWindowIDEnvironmentKey.self] }
    set { self[WorkspaceWindowIDEnvironmentKey.self] = newValue }
  }

  var workspaceWindowSession: WorkspaceWindowSession? {
    get { self[WorkspaceWindowSessionEnvironmentKey.self] }
    set { self[WorkspaceWindowSessionEnvironmentKey.self] = newValue }
  }

  var workspaceWindowIsKey: Bool {
    get { self[WorkspaceWindowIsKeyEnvironmentKey.self] }
    set { self[WorkspaceWindowIsKeyEnvironmentKey.self] = newValue }
  }
}
