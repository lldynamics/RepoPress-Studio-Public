import Foundation
import XCTest

@testable import PublishingAICore

final class AIModelDiscoveryCacheTests: XCTestCase {
  func testCacheExpiresEntriesAndEvictsLeastRecentlyUsedKeys() async {
    let cache = AIModelDiscoveryCache(ttl: 10, maximumEntryCount: 1)
    let now = Date(timeIntervalSince1970: 10_000)
    let modelA = [AIModelDescriptor(id: "model-a")]
    let modelB = [AIModelDescriptor(id: "model-b")]

    _ = await cache.insert(modelA, for: "opaque-a", now: now)
    let stillFresh = await cache.value(for: "opaque-a", now: now.addingTimeInterval(9))
    XCTAssertEqual(stillFresh, modelA)
    _ = await cache.insert(modelB, for: "opaque-b", now: now.addingTimeInterval(9))
    let evictedA = await cache.value(for: "opaque-a", now: now.addingTimeInterval(9))
    XCTAssertNil(evictedA)
    let freshB = await cache.value(for: "opaque-b", now: now.addingTimeInterval(9))
    XCTAssertEqual(freshB, modelB)
    let expiredB = await cache.value(for: "opaque-b", now: now.addingTimeInterval(19))
    XCTAssertNil(expiredB)
  }

  func testCacheGenerationDoesNotRemoveConcurrentReplacement() async throws {
    let cache = AIModelDiscoveryCache()
    let first = [AIModelDescriptor(id: "first-refresh")]
    let replacement = [AIModelDescriptor(id: "replacement-refresh")]

    let optionalFirstToken = await cache.insert(first, for: "same-account")
    let firstToken = try XCTUnwrap(optionalFirstToken)
    _ = await cache.insert(replacement, for: "same-account")
    await cache.removeValue(for: "same-account", ifGeneration: firstToken)

    let cachedReplacement = await cache.value(for: "same-account")?.map(\.id)
    XCTAssertEqual(
      cachedReplacement,
      ["replacement-refresh"]
    )
  }

  func testModelDescriptorPreservesDefaultsBadgePriorityAndCodableContract() throws {
    let defaultDescriptor = AIModelDescriptor(id: "plain-model")
    XCTAssertEqual(defaultDescriptor.name, "plain-model")
    XCTAssertFalse(defaultDescriptor.isReasoning)
    XCTAssertFalse(defaultDescriptor.isVision)
    XCTAssertTrue(defaultDescriptor.isChat)
    XCTAssertNil(defaultDescriptor.badgeTitle)

    let reasoningDescriptor = AIModelDescriptor(
      id: "reasoning-vision-model",
      name: "Reasoning Vision",
      isReasoning: true,
      isVision: true,
      isChat: false
    )
    XCTAssertEqual(reasoningDescriptor.badgeTitle, "深度思考")

    let visionDescriptor = AIModelDescriptor(
      id: "vision-model",
      isVision: true
    )
    XCTAssertEqual(visionDescriptor.badgeTitle, "多模态")

    let encoded = try JSONEncoder().encode(reasoningDescriptor)
    XCTAssertEqual(
      try JSONDecoder().decode(AIModelDescriptor.self, from: encoded),
      reasoningDescriptor
    )
  }
}
