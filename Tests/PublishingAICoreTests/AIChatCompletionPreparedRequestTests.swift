import Foundation
import PublishingAICore
import XCTest

final class AIChatCompletionPreparedRequestTests: XCTestCase {
  private enum ConsumptionOutcome: Equatable, Sendable {
    case success
    case alreadyConsumed
    case unexpected(String)
  }

  private static func preparedRequest(
    mode: AIChatTransportMode = .streaming,
    configurationFingerprint: String = "fixture-fingerprint"
  ) -> AIPreparedAIChatCompletionRequest {
    AIPreparedAIChatCompletionRequest(
      normalizedRequest: AIChatCompletionRequest(
        model: "fixture-model",
        messages: [AIChatMessage(role: "user", content: "fixture prompt")]
      ),
      endpointIdentity: "https://example.com/v1",
      endpointURL: URL(string: "https://example.com/v1/chat/completions")!,
      encodedBody: Data(#"{"model":"fixture-model"}"#.utf8),
      mode: mode,
      purpose: .interactiveChat,
      capabilitySupportSnapshot: [.chat: .supported],
      capabilityEvidenceSnapshot: [:],
      configurationFingerprint: configurationFingerprint
    )
  }

  func testTransportModesPreserveRawValuesRoundTripAndStreamingFlags() throws {
    let modes: [AIChatTransportMode] = [.nonStreaming, .streaming]

    XCTAssertEqual(modes.map(\.rawValue), ["non_streaming", "streaming"])
    XCTAssertEqual(modes.map(\.isStreaming), [false, true])

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for mode in modes {
      let encoded = try encoder.encode(mode)
      XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"\(mode.rawValue)\"")
      XCTAssertEqual(try decoder.decode(AIChatTransportMode.self, from: encoded), mode)
    }
  }

  func testPreparedRequestSnapshotEqualityHashAndConsumptionIndependentIdentity() throws {
    let snapshot = Self.preparedRequest()
    let equalCopy = Self.preparedRequest()

    XCTAssertEqual(snapshot.normalizedRequest.model, "fixture-model")
    XCTAssertEqual(snapshot.endpointIdentity, "https://example.com/v1")
    XCTAssertEqual(
      snapshot.endpointURL,
      URL(string: "https://example.com/v1/chat/completions")
    )
    XCTAssertEqual(snapshot.encodedBody, Data(#"{"model":"fixture-model"}"#.utf8))
    XCTAssertEqual(snapshot.canonicalEncodedBody, snapshot.encodedBody)
    XCTAssertEqual(snapshot.mode, .streaming)
    XCTAssertEqual(snapshot.purpose, .interactiveChat)
    XCTAssertEqual(snapshot.capabilitySupportSnapshot[.chat], .supported)
    XCTAssertTrue(snapshot.capabilityEvidenceSnapshot.isEmpty)
    XCTAssertEqual(snapshot.configurationFingerprint, "fixture-fingerprint")
    XCTAssertNil(snapshot.authorizationExpiresAt)
    XCTAssertTrue(snapshot.isStreaming)

    XCTAssertEqual(snapshot, equalCopy)
    XCTAssertEqual(snapshot.hashValue, equalCopy.hashValue)
    XCTAssertTrue(Set([snapshot]).contains(equalCopy))
    XCTAssertNotEqual(snapshot, Self.preparedRequest(mode: .nonStreaming))
    XCTAssertNotEqual(
      snapshot,
      Self.preparedRequest(configurationFingerprint: "different-fingerprint")
    )

    let consumedCopy = snapshot
    try consumedCopy.consume()
    let freshCopy = Self.preparedRequest()
    XCTAssertEqual(consumedCopy, freshCopy)
    XCTAssertEqual(consumedCopy.hashValue, freshCopy.hashValue)
    XCTAssertTrue(Set([consumedCopy]).contains(freshCopy))
  }

  func testBindingAuthorizationDeadlineOnlyTightensAndReboundSealsAreIndependent() {
    let original = Self.preparedRequest()
    let earlier = Date(timeIntervalSince1970: 100)
    let later = Date(timeIntervalSince1970: 200)
    let muchLater = Date(timeIntervalSince1970: 300)

    let unbound = original.bindingAuthorizationDeadline(nil)
    let firstDeadline = original.bindingAuthorizationDeadline(later)
    let tightenedDeadline = firstDeadline.bindingAuthorizationDeadline(earlier)
    let attemptedExtension = firstDeadline.bindingAuthorizationDeadline(muchLater)
    let retainedDeadline = firstDeadline.bindingAuthorizationDeadline(nil)
    let directEarlierDeadline = original.bindingAuthorizationDeadline(earlier)

    XCTAssertNil(unbound.authorizationExpiresAt)
    XCTAssertEqual(firstDeadline.authorizationExpiresAt, later)
    XCTAssertEqual(tightenedDeadline.authorizationExpiresAt, earlier)
    XCTAssertEqual(attemptedExtension.authorizationExpiresAt, later)
    XCTAssertEqual(retainedDeadline.authorizationExpiresAt, later)
    XCTAssertEqual(directEarlierDeadline.authorizationExpiresAt, earlier)

    let source = Self.preparedRequest()
    let rebound = source.bindingAuthorizationDeadline(later)
    XCTAssertNoThrow(try source.consume())
    XCTAssertNoThrow(try rebound.consume())
  }

  func testConcurrentPreparedRequestCopiesAllowExactlyOneConsumption() async {
    let source = Self.preparedRequest()
    let copyCount = 16
    let outcomes: [ConsumptionOutcome] = await withTaskGroup(
      of: ConsumptionOutcome.self
    ) { group in
      for _ in 0..<copyCount {
        let copy = source
        group.addTask {
          do {
            try copy.consume()
            return .success
          } catch let error as AIChatCompletionClientError {
            if error == .preparedRequestAlreadyConsumed {
              return .alreadyConsumed
            }
            return .unexpected(String(describing: error))
          } catch {
            return .unexpected(String(describing: error))
          }
        }
      }

      var collected: [ConsumptionOutcome] = []
      for await outcome in group {
        collected.append(outcome)
      }
      return collected
    }

    XCTAssertEqual(outcomes.count, copyCount)
    XCTAssertEqual(outcomes.filter { $0 == .success }.count, 1)
    XCTAssertEqual(outcomes.filter { $0 == .alreadyConsumed }.count, copyCount - 1)
    XCTAssertFalse(outcomes.contains { if case .unexpected = $0 { true } else { false } })
  }
}
