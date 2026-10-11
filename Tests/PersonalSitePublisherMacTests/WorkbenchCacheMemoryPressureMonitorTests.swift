import Foundation
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingKnowledgeCore

@MainActor
final class WorkbenchCacheMemoryPressureMonitorTests: XCTestCase {
  func testPressureEventsNumberPoliciesAndPrioritizePressureOverNormal() async throws {
    let probe = CachePolicyProbe()
    let monitor = WorkbenchCacheMemoryPressureMonitor { isEnabled, generation in
      await probe.record(isEnabled: isEnabled, generation: generation)
    }
    monitor.receive([])
    XCTAssertEqual(monitor.generation, 0)
    monitor.receive(.warning)
    XCTAssertFalse(monitor.isCacheRetentionEnabled)
    monitor.receive(.critical)
    monitor.receive(.normal)
    XCTAssertTrue(monitor.isCacheRetentionEnabled)
    monitor.receive([.normal, .warning])
    XCTAssertFalse(monitor.isCacheRetentionEnabled)
    XCTAssertEqual(monitor.generation, 4)

    try await waitUntil { await probe.policies.count == 4 }
    let policies = await probe.policies
    XCTAssertEqual(policies, [1: false, 2: false, 3: true, 4: false])
  }

  func testKnowledgeStoreBoundAfterPressureInheritsPolicyAndResumesOnNormal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "memory-pressure-monitor-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = KnowledgeLibraryService(rootURL: root)
    let store = KnowledgeStore(service: service)
    await store.startupReloadTask?.value
    let cache = try service.database().semanticFlatVectorIndexes
    let index = KnowledgeSemanticVectorFlatIndex(
      key: KnowledgeSemanticVectorIndexKey(modelIdentifier: "monitor", dimension: 2),
      vectors: [1, 0], entries: [])
    cache.insert(index)
    XCTAssertEqual(cache.count, 1)

    let monitor = WorkbenchCacheMemoryPressureMonitor { _, _ in }
    monitor.receive(.warning)
    monitor.bindKnowledgeStore(store)
    try await waitUntil { cache.count == 0 }
    cache.insert(index)
    XCTAssertEqual(cache.count, 0)

    monitor.receive(.normal)
    try await waitUntil {
      cache.insert(index)
      return cache.count == 1
    }
    XCTAssertNotNil(cache.value(for: index.key))
    monitor.bindKnowledgeStore(nil)
  }

  private func waitUntil(_ condition: () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while !(await condition()) {
      guard clock.now < deadline else {
        XCTFail("Cache policy was not applied before the deadline")
        throw CachePolicyWaitError.timedOut
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private actor CachePolicyProbe {
  private(set) var policies: [UInt64: Bool] = [:]

  func record(isEnabled: Bool, generation: UInt64) {
    policies[generation] = isEnabled
  }
}

private enum CachePolicyWaitError: Error {
  case timedOut
}
