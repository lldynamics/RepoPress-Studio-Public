import Foundation

public struct KnowledgeNavigationSnapshot: Sendable {
  public let documentCount: Int
  public let unfiledDocumentCount: Int
  public let folderDocumentCounts: [UUID: Int]
  public let smartCollections: [KnowledgeSmartCollection]
  private let savedCollectionCounts: [KnowledgeSavedCollection: Int]

  init(
    documentCount: Int,
    unfiledDocumentCount: Int,
    folderDocumentCounts: [UUID: Int],
    smartCollections: [KnowledgeSmartCollection],
    savedCollectionCounts: [KnowledgeSavedCollection: Int] = [:]
  ) {
    self.documentCount = documentCount
    self.unfiledDocumentCount = unfiledDocumentCount
    self.folderDocumentCounts = folderDocumentCounts
    self.smartCollections = smartCollections
    self.savedCollectionCounts = savedCollectionCounts
  }

  public func documentCount(forFolderID folderID: UUID) -> Int {
    folderDocumentCounts[folderID, default: 0]
  }

  public func documentCount(for collection: KnowledgeSavedCollection) -> Int {
    savedCollectionCounts[collection, default: 0]
  }

  static let empty = KnowledgeNavigationSnapshot(
    documentCount: 0,
    unfiledDocumentCount: 0,
    folderDocumentCounts: [:],
    smartCollections: []
  )
}

@MainActor
extension KnowledgeStore {
  /// Returns the navigation counts from one document-revision snapshot. The
  /// saved-collection input replaces, rather than accumulates, the cached
  /// rules so AppStorage edits cannot grow the cache without bound.
  public func navigationSnapshot(
    savedCollections: [KnowledgeSavedCollection]
  ) -> KnowledgeNavigationSnapshot {
    let now = Date()
    let calendar = Calendar.current
    let documentSnapshot = navigationDocumentSnapshot(now: now, calendar: calendar)

    guard navigationSavedCollectionsCache != savedCollections else {
      return documentSnapshot.withSavedCollectionCounts(navigationSavedCollectionCounts)
    }

    var counts: [KnowledgeSavedCollection: Int] = [:]
    for collection in savedCollections {
      counts[collection] = 0
    }
    for document in documents {
      for collection in savedCollections
      where smartCollectionService.matches(
        document,
        rules: collection.rules,
        matchMode: collection.matchMode,
        now: now,
        calendar: calendar
      ) {
        counts[collection, default: 0] += 1
      }
    }
    #if DEBUG
      navigationSavedCollectionCountBuildCount += 1
    #endif
    navigationSavedCollectionsCache = savedCollections
    navigationSavedCollectionCounts = counts
    return documentSnapshot.withSavedCollectionCounts(counts)
  }

  #if DEBUG
    var navigationSavedCollectionCacheEntryCount: Int {
      navigationSavedCollectionsCache.isEmpty ? 0 : 1
    }
  #endif

  func navigationDocumentSnapshot() -> KnowledgeNavigationSnapshot {
    let now = Date()
    return navigationDocumentSnapshot(now: now, calendar: .current)
  }

  private func navigationDocumentSnapshot(
    now: Date,
    calendar: Calendar
  ) -> KnowledgeNavigationSnapshot {
    let day = calendar.startOfDay(for: now)
    if navigationSnapshotRevision == navigationRevision,
      navigationSnapshotDay == day
    {
      return navigationSnapshot
    }

    var unfiledDocumentCount = 0
    var folderDocumentCounts: [UUID: Int] = [:]
    for document in documents {
      if let folderID = document.folderID {
        folderDocumentCounts[folderID, default: 0] += 1
      } else {
        unfiledDocumentCount += 1
      }
    }
    let snapshot = KnowledgeNavigationSnapshot(
      documentCount: documents.count,
      unfiledDocumentCount: unfiledDocumentCount,
      folderDocumentCounts: folderDocumentCounts,
      smartCollections: smartCollectionService.collections(
        for: documents,
        now: now,
        calendar: calendar
      )
    )
    #if DEBUG
      navigationSnapshotBuildCount += 1
    #endif
    navigationSnapshotRevision = navigationRevision
    navigationSnapshotDay = day
    navigationSnapshot = snapshot
    navigationSavedCollectionsCache = []
    navigationSavedCollectionCounts = [:]
    return snapshot
  }
}

extension KnowledgeNavigationSnapshot {
  fileprivate func withSavedCollectionCounts(
    _ savedCollectionCounts: [KnowledgeSavedCollection: Int]
  ) -> KnowledgeNavigationSnapshot {
    KnowledgeNavigationSnapshot(
      documentCount: documentCount,
      unfiledDocumentCount: unfiledDocumentCount,
      folderDocumentCounts: folderDocumentCounts,
      smartCollections: smartCollections,
      savedCollectionCounts: savedCollectionCounts
    )
  }
}
