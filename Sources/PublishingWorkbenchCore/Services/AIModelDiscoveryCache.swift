import Foundation

/// A small in-memory cache for model discovery results.
///
/// The cache deliberately accepts only an opaque key. `AIModelDiscoveryService`
/// derives that key from the endpoint/configuration and a one-way credential
/// digest, so raw API keys are never retained by this type. Entries are
/// bounded by both age and count and are safe to access from concurrent
/// discovery tasks.
public actor AIModelDiscoveryCache {
  public static let shared = AIModelDiscoveryCache()
  public static let defaultTTL: TimeInterval = 5 * 60
  public static let defaultMaximumEntryCount = 16

  public struct InsertionToken: Hashable, Sendable {
    fileprivate let rawValue: UUID

    fileprivate init() {
      rawValue = UUID()
    }
  }

  private struct Entry: Sendable {
    let models: [AIModelDescriptor]
    let expiresAt: Date
    var lastAccess: UInt64
    let insertionToken: InsertionToken
  }

  private let ttl: TimeInterval
  private let maximumEntryCount: Int
  private let insertionBarrier: (@Sendable () async -> Void)?
  private var entries: [String: Entry] = [:]
  private var accessCounter: UInt64 = 0

  public init(
    ttl: TimeInterval = AIModelDiscoveryCache.defaultTTL,
    maximumEntryCount: Int = AIModelDiscoveryCache.defaultMaximumEntryCount
  ) {
    self.ttl = max(0, ttl)
    self.maximumEntryCount = max(1, maximumEntryCount)
    insertionBarrier = nil
  }

  /// Internal test-only injection point used to exercise cancellation while
  /// the actor is in the insertion window. Production callers use the public
  /// initializer above, which has no suspension in the insertion path.
  init(
    ttl: TimeInterval = AIModelDiscoveryCache.defaultTTL,
    maximumEntryCount: Int = AIModelDiscoveryCache.defaultMaximumEntryCount,
    insertionBarrier: (@Sendable () async -> Void)?
  ) {
    self.ttl = max(0, ttl)
    self.maximumEntryCount = max(1, maximumEntryCount)
    self.insertionBarrier = insertionBarrier
  }

  public func value(for key: String, now: Date = Date()) -> [AIModelDescriptor]? {
    removeExpiredEntries(now: now)
    guard var entry = entries[key], now < entry.expiresAt else {
      entries[key] = nil
      return nil
    }
    accessCounter &+= 1
    entry.lastAccess = accessCounter
    entries[key] = entry
    return entry.models
  }

  public func insert(
    _ models: [AIModelDescriptor],
    for key: String,
    now: Date = Date()
  ) async -> InsertionToken? {
    guard ttl > 0, !Task.isCancelled else { return nil }
    removeExpiredEntries(now: now)
    if let insertionBarrier {
      await insertionBarrier()
    }
    // Cancellation can happen while an injected/test barrier or another
    // actor hop is pending. Check immediately before mutating the entry so a
    // cancelled discovery cannot publish its result.
    guard !Task.isCancelled else { return nil }
    accessCounter &+= 1
    let insertionToken = InsertionToken()
    entries[key] = Entry(
      models: models,
      expiresAt: now.addingTimeInterval(ttl),
      lastAccess: accessCounter,
      insertionToken: insertionToken
    )
    evictLeastRecentlyUsedEntriesIfNeeded()
    return insertionToken
  }

  func removeValue(
    for key: String,
    ifGeneration insertionToken: InsertionToken
  ) {
    guard entries[key]?.insertionToken == insertionToken else {
      return
    }
    entries[key] = nil
  }

  public func removeAll() {
    entries.removeAll(keepingCapacity: true)
  }

  public var count: Int {
    entries.count
  }

  private func removeExpiredEntries(now: Date) {
    entries = entries.filter { _, entry in now < entry.expiresAt }
  }

  private func evictLeastRecentlyUsedEntriesIfNeeded() {
    guard entries.count > maximumEntryCount else { return }
    let overflow = entries.count - maximumEntryCount
    let keysToRemove =
      entries
      .sorted { lhs, rhs in lhs.value.lastAccess < rhs.value.lastAccess }
      .prefix(overflow)
      .map(\.key)
    for key in keysToRemove {
      entries[key] = nil
    }
  }
}
