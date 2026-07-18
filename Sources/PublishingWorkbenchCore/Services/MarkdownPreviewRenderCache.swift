public struct MarkdownPreviewRenderCache<Key, Snapshot>: Sendable
where Key: Hashable & Sendable, Snapshot: Sendable {
  public let capacity: Int
  private var snapshotByKey: [Key: Snapshot] = [:]
  private var keysByRecency: [Key] = []

  public init(capacity: Int = 4) {
    self.capacity = max(1, capacity)
  }

  public var count: Int {
    snapshotByKey.count
  }

  public mutating func snapshot(for key: Key) -> Snapshot? {
    guard let snapshot = snapshotByKey[key] else { return nil }
    markRecentlyUsed(key)
    return snapshot
  }

  public mutating func insert(_ snapshot: Snapshot, for key: Key) {
    snapshotByKey[key] = snapshot
    markRecentlyUsed(key)

    while snapshotByKey.count > capacity, let leastRecentKey = keysByRecency.first {
      keysByRecency.removeFirst()
      snapshotByKey.removeValue(forKey: leastRecentKey)
    }
  }

  public mutating func removeAll() {
    snapshotByKey.removeAll(keepingCapacity: true)
    keysByRecency.removeAll(keepingCapacity: true)
  }

  private mutating func markRecentlyUsed(_ key: Key) {
    keysByRecency.removeAll { $0 == key }
    keysByRecency.append(key)
  }
}
