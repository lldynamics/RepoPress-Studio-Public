import Foundation

public enum DraftOwnershipTransferOperation: String, Codable, CaseIterable, Identifiable, Sendable {
  case moveToSite
  case copyToSite
  case moveToGeneral

  public var id: String { rawValue }

  public var isCopy: Bool {
    self == .copyToSite
  }
}

public enum DraftOwnershipTransferConflictKind: String, Codable, Sendable {
  case targetPathOccupied
  case duplicateTargetPath
  case sameDestination
  case sourceChanged
  case unavailableSource
  case unavailableTarget
}

public struct DraftOwnershipTransferConflict: Identifiable, Codable, Hashable, Sendable {
  public var id: String
  public var kind: DraftOwnershipTransferConflictKind
  public var draftID: UUID?
  public var title: String
  public var message: String

  public init(
    id: String,
    kind: DraftOwnershipTransferConflictKind,
    draftID: UUID?,
    title: String,
    message: String
  ) {
    self.id = id
    self.kind = kind
    self.draftID = draftID
    self.title = title
    self.message = message
  }
}

public struct DraftOwnershipTransferItem: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID { draftID }
  public var draftID: UUID
  public var title: String
  public var sourceProfileName: String
  public var sourceMarkdownPath: String?
  public var sourcePermalink: String?
  public var targetProfileName: String
  public var targetMarkdownPath: String?
  public var targetPermalink: String?
  public var sourceUpdatedAt: Date
  public var conflicts: [DraftOwnershipTransferConflict]

  public init(
    draftID: UUID,
    title: String,
    sourceProfileName: String,
    sourceMarkdownPath: String?,
    sourcePermalink: String?,
    targetProfileName: String,
    targetMarkdownPath: String?,
    targetPermalink: String?,
    sourceUpdatedAt: Date,
    conflicts: [DraftOwnershipTransferConflict] = []
  ) {
    self.draftID = draftID
    self.title = title
    self.sourceProfileName = sourceProfileName
    self.sourceMarkdownPath = sourceMarkdownPath
    self.sourcePermalink = sourcePermalink
    self.targetProfileName = targetProfileName
    self.targetMarkdownPath = targetMarkdownPath
    self.targetPermalink = targetPermalink
    self.sourceUpdatedAt = sourceUpdatedAt
    self.conflicts = conflicts
  }
}

public struct DraftOwnershipTransferPlan: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var operation: DraftOwnershipTransferOperation
  public var targetProfileID: UUID?
  public var items: [DraftOwnershipTransferItem]
  public var conflicts: [DraftOwnershipTransferConflict]

  public init(
    id: UUID = UUID(),
    operation: DraftOwnershipTransferOperation,
    targetProfileID: UUID?,
    items: [DraftOwnershipTransferItem],
    conflicts: [DraftOwnershipTransferConflict]
  ) {
    self.id = id
    self.operation = operation
    self.targetProfileID = targetProfileID
    self.items = items
    self.conflicts = conflicts
  }

  public var draftIDs: [UUID] {
    items.map(\.draftID)
  }

  public var canApply: Bool {
    !items.isEmpty && conflicts.isEmpty
  }

  public var isBatch: Bool {
    items.count > 1
  }
}

public struct DraftOwnershipTransferResult: Hashable, Sendable {
  public var operation: DraftOwnershipTransferOperation
  public var affectedDraftIDs: [UUID]
  public var undoID: UUID

  public init(
    operation: DraftOwnershipTransferOperation,
    affectedDraftIDs: [UUID],
    undoID: UUID
  ) {
    self.operation = operation
    self.affectedDraftIDs = affectedDraftIDs
    self.undoID = undoID
  }
}

struct DraftOwnershipTransferUndoState: Sendable {
  struct OriginalDraft: Sendable {
    var index: Int
    var draft: ArticleDraft
  }

  var id: UUID
  var operation: DraftOwnershipTransferOperation
  var originals: [OriginalDraft]
  var createdDraftIDs: [UUID]
  var expectedDraftsAfterTransfer: [UUID: ArticleDraft]
  var previousActiveProfileID: UUID
  var previousDraftListContentScope: DraftListContentScope
  var previousSelectedDraftID: UUID?
}
