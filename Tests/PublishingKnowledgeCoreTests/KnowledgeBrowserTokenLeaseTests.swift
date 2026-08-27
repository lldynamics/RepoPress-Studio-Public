import Foundation
import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeBrowserTokenLeaseTests: XCTestCase {
  func testLegacyTokenReceivesThirtyDayLeaseWithoutUnexpectedRotation() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let legacyToken = String(repeating: "a", count: 64)
    var generated = false

    let lease = KnowledgeBrowserConnectionTokenLease(
      storedToken: legacyToken,
      storedExpiresAt: nil,
      now: now,
      generateToken: {
        generated = true
        return String(repeating: "b", count: 64)
      }
    )

    XCTAssertEqual(lease.token, legacyToken)
    XCTAssertFalse(generated)
    XCTAssertEqual(
      lease.expiresAt.timeIntervalSince(now),
      KnowledgeBrowserConnectionTokenLease.defaultLifetime,
      accuracy: 0.001
    )
  }

  func testExpiredTokenIsRotatedAndOldLeaseIsRejectedAtBoundary() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let replacement = String(repeating: "c", count: 64)
    let lease = KnowledgeBrowserConnectionTokenLease(
      storedToken: String(repeating: "a", count: 64),
      storedExpiresAt: now.addingTimeInterval(-1),
      now: now,
      generateToken: { replacement }
    )

    XCTAssertEqual(lease.token, replacement)
    XCTAssertFalse(lease.isExpired(at: now))
    XCTAssertTrue(lease.isExpired(at: lease.expiresAt))
  }
}
