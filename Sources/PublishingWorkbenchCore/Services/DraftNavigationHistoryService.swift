import Foundation

public struct DraftNavigationHistory: Equatable, Sendable {
  public static let maximumHistoryCount = 100

  public private(set) var currentDraftID: UUID?
  public private(set) var backwardDraftIDs: [UUID]
  public private(set) var forwardDraftIDs: [UUID]

  public init(
    currentDraftID: UUID? = nil,
    backwardDraftIDs: [UUID] = [],
    forwardDraftIDs: [UUID] = []
  ) {
    self.currentDraftID = currentDraftID
    self.backwardDraftIDs = Array(backwardDraftIDs.suffix(Self.maximumHistoryCount))
    self.forwardDraftIDs = Array(forwardDraftIDs.suffix(Self.maximumHistoryCount))
  }

  public mutating func recordVisit(_ draftID: UUID) {
    guard draftID != currentDraftID else { return }
    if let currentDraftID {
      backwardDraftIDs.append(currentDraftID)
      backwardDraftIDs = Array(backwardDraftIDs.suffix(Self.maximumHistoryCount))
    }
    currentDraftID = draftID
    forwardDraftIDs.removeAll()
  }

  public func canNavigateBackward(availableDraftIDs: Set<UUID>) -> Bool {
    backwardDraftIDs.contains(where: availableDraftIDs.contains)
  }

  public func canNavigateForward(availableDraftIDs: Set<UUID>) -> Bool {
    forwardDraftIDs.contains(where: availableDraftIDs.contains)
  }

  public mutating func navigateBackward(availableDraftIDs: Set<UUID>) -> UUID? {
    while let candidate = backwardDraftIDs.popLast() {
      guard availableDraftIDs.contains(candidate) else { continue }
      if let currentDraftID, availableDraftIDs.contains(currentDraftID) {
        forwardDraftIDs.append(currentDraftID)
        forwardDraftIDs = Array(forwardDraftIDs.suffix(Self.maximumHistoryCount))
      }
      currentDraftID = candidate
      return candidate
    }
    return nil
  }

  public mutating func navigateForward(availableDraftIDs: Set<UUID>) -> UUID? {
    while let candidate = forwardDraftIDs.popLast() {
      guard availableDraftIDs.contains(candidate) else { continue }
      if let currentDraftID, availableDraftIDs.contains(currentDraftID) {
        backwardDraftIDs.append(currentDraftID)
        backwardDraftIDs = Array(backwardDraftIDs.suffix(Self.maximumHistoryCount))
      }
      currentDraftID = candidate
      return candidate
    }
    return nil
  }

  public mutating func remove(_ draftID: UUID) {
    backwardDraftIDs.removeAll { $0 == draftID }
    forwardDraftIDs.removeAll { $0 == draftID }
    if currentDraftID == draftID {
      currentDraftID = nil
    }
  }
}
