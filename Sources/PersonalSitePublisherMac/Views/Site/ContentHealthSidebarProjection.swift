import Combine
import Foundation
import PublishingWorkbenchCore
import SwiftUI

@MainActor
final class ContentHealthSidebarProjection: ObservableObject {
  struct Snapshot: Equatable {
    let profileID: UUID
    let orderedAIFixDraftIDs: [UUID]
    let issueCount: Int

    var aiFixDraftIDs: Set<UUID> {
      Set(orderedAIFixDraftIDs)
    }
  }

  enum QueueState: Equatable {
    case loading
    case ready([UUID])
    case failed
    case cancelled
  }

  private enum State: Equatable {
    case idle
    case loading(profileID: UUID)
    case ready(Snapshot)
    case failed(profileID: UUID)
    case cancelled(profileID: UUID)
  }

  @Published private var state: State = .idle

  func beginLoading(profileID: UUID) {
    state = .loading(profileID: profileID)
  }

  func replace(profileID: UUID, aiFixQueueItems: [AIPublishingFixQueueItem], issueCount: Int = 0) {
    var seenDraftIDs: Set<UUID> = []
    let orderedDraftIDs = aiFixQueueItems.compactMap { item in
      seenDraftIDs.insert(item.draftID).inserted ? item.draftID : nil
    }
    state = .ready(
      Snapshot(
        profileID: profileID,
        orderedAIFixDraftIDs: orderedDraftIDs,
        issueCount: max(0, issueCount)
      ))
  }

  func markFailed(profileID: UUID) {
    state = .failed(profileID: profileID)
  }

  func cancelLoading() {
    guard case .loading(let profileID) = state else { return }
    state = .cancelled(profileID: profileID)
  }

  func queueState(for profileID: UUID) -> QueueState {
    switch state {
    case .ready(let snapshot) where snapshot.profileID == profileID:
      return .ready(snapshot.orderedAIFixDraftIDs)
    case .failed(let failedProfileID) where failedProfileID == profileID:
      return .failed
    case .cancelled(let cancelledProfileID) where cancelledProfileID == profileID:
      return .cancelled
    case .idle, .loading, .ready, .failed, .cancelled:
      return .loading
    }
  }

  func aiFixDraftIDs(for profileID: UUID) -> Set<UUID>? {
    guard case .ready(let snapshot) = state,
      snapshot.profileID == profileID
    else { return nil }
    return snapshot.aiFixDraftIDs
  }

  func knownIssueCount(for profileID: UUID) -> Int? {
    guard case .ready(let snapshot) = state,
      snapshot.profileID == profileID
    else { return nil }
    return snapshot.issueCount
  }
}

/// A window-owned bridge to the mounted health page. The page retains its AI
/// tasks and review sheets; this object only routes inspector commands to it.
@MainActor
final class ContentHealthInspectorActions: ObservableObject {
  struct Handlers {
    let isCurrent: () -> Bool
    let isAIRunning: () -> Bool
    let locate: (PreflightIssue, UUID) -> Void
    let runAIFix: (AIPublishingFixQueueItem) -> Void
    let openMaintenanceDraft: (UUID) -> Void
    let copyMaintenance: (MaintenanceActionItem) -> Void
    let recordMaintenance: (MaintenanceActionItem) -> Void
    let sendMaintenanceToAI: (MaintenanceActionItem) -> Void
    let slugResolution: (UUID) -> AnyView?
  }

  @Published private(set) var isAvailable = false
  @Published private(set) var isAIRunning = false
  @Published private(set) var generatedAt: Date?
  private var ownerID: UUID?
  private var handlers: Handlers?

  func install(ownerID: UUID, generatedAt: Date, handlers: Handlers) {
    self.ownerID = ownerID
    self.handlers = handlers
    self.generatedAt = generatedAt
    isAvailable = handlers.isCurrent()
    isAIRunning = handlers.isAIRunning()
  }

  func updateAIState(ownerID: UUID) {
    guard self.ownerID == ownerID, let handlers else { return }
    isAIRunning = handlers.isAIRunning()
  }

  func clear(ownerID: UUID) {
    guard self.ownerID == ownerID else { return }
    self.ownerID = nil
    handlers = nil
    generatedAt = nil
    isAvailable = false
    isAIRunning = false
  }

  func locate(_ issue: PreflightIssue, draftID: UUID) {
    guard let handlers, handlers.isCurrent() else { return }
    handlers.locate(issue, draftID)
  }

  func runAIFix(_ item: AIPublishingFixQueueItem) {
    guard let handlers, handlers.isCurrent(), !handlers.isAIRunning() else { return }
    handlers.runAIFix(item)
  }

  func openMaintenanceDraft(_ draftID: UUID) {
    guard let handlers, handlers.isCurrent() else { return }
    handlers.openMaintenanceDraft(draftID)
  }

  func copyMaintenance(_ item: MaintenanceActionItem) {
    guard let handlers, handlers.isCurrent() else { return }
    handlers.copyMaintenance(item)
  }

  func recordMaintenance(_ item: MaintenanceActionItem) {
    guard let handlers, handlers.isCurrent() else { return }
    handlers.recordMaintenance(item)
  }

  func sendMaintenanceToAI(_ item: MaintenanceActionItem) {
    guard let handlers, handlers.isCurrent(), !handlers.isAIRunning() else { return }
    handlers.sendMaintenanceToAI(item)
  }

  func slugResolution(for draftID: UUID) -> AnyView? {
    guard let handlers, handlers.isCurrent() else { return nil }
    return handlers.slugResolution(draftID)
  }
}
