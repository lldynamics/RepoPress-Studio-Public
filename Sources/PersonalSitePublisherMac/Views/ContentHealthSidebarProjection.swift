import Combine
import Foundation
import PublishingWorkbenchCore

@MainActor
final class ContentHealthSidebarProjection: ObservableObject {
  struct Snapshot: Equatable {
    let profileID: UUID
    let orderedAIFixDraftIDs: [UUID]

    var aiFixDraftIDs: Set<UUID> {
      Set(orderedAIFixDraftIDs)
    }
  }

  enum QueueState: Equatable {
    case loading
    case ready([UUID])
    case failed
  }

  private enum State: Equatable {
    case idle
    case loading(profileID: UUID)
    case ready(Snapshot)
    case failed(profileID: UUID)
  }

  @Published private var state: State = .idle

  func beginLoading(profileID: UUID) {
    state = .loading(profileID: profileID)
  }

  func replace(profileID: UUID, aiFixQueueItems: [AIPublishingFixQueueItem]) {
    var seenDraftIDs: Set<UUID> = []
    let orderedDraftIDs = aiFixQueueItems.compactMap { item in
      seenDraftIDs.insert(item.draftID).inserted ? item.draftID : nil
    }
    state = .ready(Snapshot(
      profileID: profileID,
      orderedAIFixDraftIDs: orderedDraftIDs
    ))
  }

  func markFailed(profileID: UUID) {
    state = .failed(profileID: profileID)
  }

  func queueState(for profileID: UUID) -> QueueState {
    switch state {
    case .ready(let snapshot) where snapshot.profileID == profileID:
      return .ready(snapshot.orderedAIFixDraftIDs)
    case .failed(let failedProfileID) where failedProfileID == profileID:
      return .failed
    case .idle, .loading, .ready, .failed:
      return .loading
    }
  }

  func aiFixDraftIDs(for profileID: UUID) -> Set<UUID>? {
    guard case .ready(let snapshot) = state,
          snapshot.profileID == profileID else { return nil }
    return snapshot.aiFixDraftIDs
  }
}
