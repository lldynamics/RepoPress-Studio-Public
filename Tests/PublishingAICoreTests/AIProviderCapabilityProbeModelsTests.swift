import Foundation
import XCTest

import PublishingAICore

final class AIProviderCapabilityProbeModelsTests: XCTestCase {
  func testProbeValueModelsPreserveRawValuesDefaultsAndCodableContracts() throws {
    XCTAssertEqual(AIProviderCapabilityCacheKey.currentProbeSchemaVersion, 1)
    XCTAssertEqual(
      AIProviderCapabilityProbeCacheState.allCases.map(\.rawValue),
      ["hit", "partial_hit", "miss", "expired", "forced_refresh"]
    )
    for state in AIProviderCapabilityProbeCacheState.allCases {
      XCTAssertFalse(state.displayName.isEmpty)
    }

    let observedAt = Date(timeIntervalSince1970: 100)
    let expiresAt = Date(timeIntervalSince1970: 160)
    let key = makeKey()
    let evidence = makeEvidence(
      key: key,
      capability: .toolCalling,
      outcome: .supported,
      observedAt: observedAt,
      expiresAt: expiresAt,
      statusCode: 200,
      detail: "verified"
    )
    let result = AIProviderCapabilityProbeResult(
      capability: .toolCalling,
      outcome: .supported,
      statusCode: 200,
      responseModel: "model-a",
      responsePreview: "ok",
      evidence: evidence,
      fromCache: true
    )
    let entry = AIProviderCapabilityProbeCacheEntry(
      key: key,
      results: [.toolCalling: result],
      storedAt: observedAt,
      expiresAt: expiresAt
    )
    let report = AIProviderCapabilityProbeReport(
      key: key,
      results: [.toolCalling: result],
      cacheState: .hit,
      generatedAt: observedAt
    )

    XCTAssertEqual(try roundTrip(key), key)
    XCTAssertEqual(try roundTrip(evidence), evidence)
    XCTAssertEqual(try roundTrip(result), result)
    XCTAssertEqual(try roundTrip(entry), entry)
    XCTAssertEqual(try roundTrip(report), report)
    for state in AIProviderCapabilityProbeCacheState.allCases {
      XCTAssertEqual(try roundTrip(state), state)
    }

    let minimalResult = AIProviderCapabilityProbeResult(
      capability: .chat,
      outcome: .inconclusive,
      evidence: makeEvidence(
        key: key,
        capability: .chat,
        outcome: .inconclusive,
        observedAt: observedAt,
        expiresAt: expiresAt
      )
    )
    XCTAssertNil(minimalResult.statusCode)
    XCTAssertNil(minimalResult.responseModel)
    XCTAssertNil(minimalResult.responsePreview)
    XCTAssertFalse(minimalResult.fromCache)
  }

  func testEvidenceAndCacheEntryCurrentnessUsesInclusiveStartExclusiveExpiryAndSchema() {
    let key = makeKey()
    let evidence = makeEvidence(
      key: key,
      capability: .chat,
      outcome: .supported,
      observedAt: Date(timeIntervalSince1970: 100),
      expiresAt: Date(timeIntervalSince1970: 160)
    )

    XCTAssertFalse(evidence.isCurrent(at: Date(timeIntervalSince1970: 99)))
    XCTAssertTrue(evidence.isCurrent(at: Date(timeIntervalSince1970: 100)))
    XCTAssertTrue(evidence.isCurrent(at: Date(timeIntervalSince1970: 159.999)))
    XCTAssertFalse(evidence.isCurrent(at: Date(timeIntervalSince1970: 160)))
    XCTAssertFalse(
      evidence.isCurrent(at: Date(timeIntervalSince1970: 120), schemaVersion: 2)
    )

    let result = makeResult(evidence: evidence)
    let entry = AIProviderCapabilityProbeCacheEntry(
      key: key,
      results: [.chat: result],
      storedAt: Date(timeIntervalSince1970: 100),
      expiresAt: Date(timeIntervalSince1970: 200)
    )
    XCTAssertTrue(entry.isCurrent(at: Date(timeIntervalSince1970: 120)))
    XCTAssertFalse(entry.isCurrent(at: Date(timeIntervalSince1970: 170)))
    XCTAssertFalse(entry.isCurrent(at: Date(timeIntervalSince1970: 120), schemaVersion: 2))

    let longLivedEvidence = makeEvidence(
      key: key,
      capability: .chat,
      outcome: .supported,
      observedAt: Date(timeIntervalSince1970: 100),
      expiresAt: Date(timeIntervalSince1970: 240)
    )
    let entryWithEarlierExpiry = AIProviderCapabilityProbeCacheEntry(
      key: key,
      results: [.chat: makeResult(evidence: longLivedEvidence)],
      storedAt: Date(timeIntervalSince1970: 100),
      expiresAt: Date(timeIntervalSince1970: 200)
    )
    XCTAssertFalse(entryWithEarlierExpiry.isCurrent(at: Date(timeIntervalSince1970: 200)))

    let expiredEvidence = makeEvidence(
      key: key,
      capability: .visionInput,
      outcome: .unsupported,
      observedAt: Date(timeIntervalSince1970: 50),
      expiresAt: Date(timeIntervalSince1970: 90)
    )
    let mixedEntry = AIProviderCapabilityProbeCacheEntry(
      key: key,
      results: [
        .chat: result,
        .visionInput: makeResult(evidence: expiredEvidence),
      ],
      storedAt: Date(timeIntervalSince1970: 50),
      expiresAt: Date(timeIntervalSince1970: 200)
    )
    XCTAssertFalse(mixedEntry.isCurrent(at: Date(timeIntervalSince1970: 100)))
  }

  func testProbeCacheActorSupportsReplacementCurrentLookupRemovalAndCancelledStore() async {
    let cache = AIProviderCapabilityProbeCache()
    let keyA = makeKey(model: "model-a")
    let keyB = makeKey(model: "model-b")
    let entryA = makeEntry(key: keyA, storedAt: 100, expiresAt: 200)
    let entryB = makeEntry(key: keyB, storedAt: 100, expiresAt: 200)

    await cache.store(entryA)
    let storedA = await cache.entry(for: keyA)
    XCTAssertEqual(storedA, entryA)
    let currentA = await cache.currentEntry(for: keyA, at: Date(timeIntervalSince1970: 120))
    XCTAssertEqual(currentA, entryA)
    let expiredA = await cache.currentEntry(for: keyA, at: Date(timeIntervalSince1970: 200))
    XCTAssertNil(expiredA)
    let retainedA = await cache.entry(for: keyA)
    XCTAssertEqual(retainedA, entryA)

    let replacement = makeEntry(key: keyA, storedAt: 110, expiresAt: 260)
    await cache.store(replacement)
    let storedReplacement = await cache.entry(for: keyA)
    XCTAssertEqual(storedReplacement, replacement)

    await cache.store(entryB)
    let isolatedB = await cache.entry(for: keyB)
    XCTAssertEqual(isolatedB, entryB)
    await cache.remove(for: keyA)
    let removedA = await cache.entry(for: keyA)
    let remainingB = await cache.entry(for: keyB)
    XCTAssertNil(removedA)
    XCTAssertEqual(remainingB, entryB)

    await cache.removeAll()
    let clearedA = await cache.entry(for: keyA)
    let clearedB = await cache.entry(for: keyB)
    XCTAssertNil(clearedA)
    XCTAssertNil(clearedB)

    let accepted = await cache.storeUnlessCancelled(entryA)
    XCTAssertTrue(accepted)
    let acceptedEntry = await cache.entry(for: keyA)
    XCTAssertEqual(acceptedEntry, entryA)
    await cache.remove(for: keyA)

    let rejected = await Task { () -> Bool in
      withUnsafeCurrentTask { task in
        task?.cancel()
      }
      return await cache.storeUnlessCancelled(entryA)
    }.value
    XCTAssertFalse(rejected)
    let rejectedEntry = await cache.entry(for: keyA)
    XCTAssertNil(rejectedEntry)
  }

  func testProbeEvidenceAndReportMappingsCoverEveryOutcomeAndCapability() {
    let key = makeKey()
    let generatedAt = Date(timeIntervalSince1970: 120)
    let supportExpectations: [
      (outcome: AIProviderCapabilityProbeOutcome, support: AIProviderCapabilitySupport)
    ] = [
      (.supported, .supported),
      (.unsupported, .unsupported),
      (.inconclusive, .unknown),
    ]

    for expectation in supportExpectations {
      let evidence = makeEvidence(
        key: key,
        capability: .chat,
        outcome: expectation.outcome,
        observedAt: Date(timeIntervalSince1970: 100),
        expiresAt: Date(timeIntervalSince1970: 160)
      )
      XCTAssertEqual(evidence.support, expectation.support)
    }

    var results: [AIProviderCapabilityProbeKind: AIProviderCapabilityProbeResult] = [:]
    let outcomes = supportExpectations.map(\.outcome)
    for (index, capability) in AIProviderCapabilityProbeKind.allCases.enumerated() {
      let outcome = outcomes[index % outcomes.count]
      let evidence = makeEvidence(
        key: key,
        capability: capability,
        outcome: outcome,
        observedAt: Date(timeIntervalSince1970: 100),
        expiresAt: Date(timeIntervalSince1970: 160)
      )
      results[capability] = AIProviderCapabilityProbeResult(
        capability: capability,
        outcome: outcome,
        evidence: evidence
      )
    }

    let report = AIProviderCapabilityProbeReport(
      key: key,
      results: results,
      cacheState: .partialHit,
      generatedAt: generatedAt
    )
    let mappedEvidence = report.evidenceByCapability
    XCTAssertEqual(mappedEvidence.count, results.count)
    XCTAssertEqual(Set(mappedEvidence.keys), Set(AIProviderCapabilityProbeKind.allCases))
    for (capability, result) in results {
      XCTAssertEqual(mappedEvidence[capability], result.evidence)
      XCTAssertEqual(result.capability, result.evidence.capability)
      XCTAssertEqual(result.outcome, result.evidence.outcome)
    }
    XCTAssertEqual(report.key, key)
    XCTAssertEqual(report.cacheState, .partialHit)
    XCTAssertEqual(report.generatedAt, generatedAt)
  }

  private func makeKey(
    model: String = "model-a",
    schemaVersion: Int = AIProviderCapabilityCacheKey.currentProbeSchemaVersion
  ) -> AIProviderCapabilityCacheKey {
    AIProviderCapabilityCacheKey(
      preset: .custom,
      endpointIdentity: "https://example.com/v1",
      model: model,
      probeSchemaVersion: schemaVersion
    )
  }

  private func makeEvidence(
    key: AIProviderCapabilityCacheKey,
    capability: AIProviderCapabilityProbeKind,
    outcome: AIProviderCapabilityProbeOutcome,
    observedAt: Date,
    expiresAt: Date,
    statusCode: Int? = nil,
    detail: String? = nil
  ) -> AIProviderCapabilityProbeEvidence {
    AIProviderCapabilityProbeEvidence(
      key: key,
      capability: capability,
      outcome: outcome,
      observedAt: observedAt,
      expiresAt: expiresAt,
      statusCode: statusCode,
      detail: detail
    )
  }

  private func makeResult(
    evidence: AIProviderCapabilityProbeEvidence
  ) -> AIProviderCapabilityProbeResult {
    AIProviderCapabilityProbeResult(
      capability: evidence.capability,
      outcome: evidence.outcome,
      evidence: evidence
    )
  }

  private func makeEntry(
    key: AIProviderCapabilityCacheKey,
    storedAt: TimeInterval,
    expiresAt: TimeInterval
  ) -> AIProviderCapabilityProbeCacheEntry {
    let evidence = makeEvidence(
      key: key,
      capability: .chat,
      outcome: .supported,
      observedAt: Date(timeIntervalSince1970: storedAt),
      expiresAt: Date(timeIntervalSince1970: expiresAt)
    )
    return AIProviderCapabilityProbeCacheEntry(
      key: key,
      results: [.chat: makeResult(evidence: evidence)],
      storedAt: Date(timeIntervalSince1970: storedAt),
      expiresAt: Date(timeIntervalSince1970: expiresAt)
    )
  }

  private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
  }
}
