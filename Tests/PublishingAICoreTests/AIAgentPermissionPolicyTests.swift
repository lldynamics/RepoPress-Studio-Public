import Foundation
import XCTest

@testable import PublishingAICore

final class AIAgentPermissionPolicyTests: XCTestCase {
  func testMissingPolicyUsesLegacySafeDefault() throws {
    let decoded = try JSONDecoder().decode(
      AIAgentPermissionPolicy.self,
      from: Data("{}".utf8)
    )

    XCTAssertEqual(decoded, .legacySafeDefault)
    XCTAssertTrue(decoded.isDefault)
    XCTAssertEqual(decoded.enabledScopes, [.localRead, .draftCreation])
  }

  func testLegacyAllowedScopesKeyAndUnknownScopesAreHandled() throws {
    let decoded = try JSONDecoder().decode(
      AIAgentPermissionPolicy.self,
      from: Data(#"{"allowedScopes":["networkAccess","futureScope"]}"#.utf8)
    )

    XCTAssertEqual(decoded.enabledScopes, [.networkAccess])
    XCTAssertTrue(decoded.allows(.networkAccess))
    XCTAssertFalse(decoded.allows(.publishing))
  }

  func testEnabledScopesKeyTakesPrecedenceOverLegacyKey() throws {
    let decoded = try JSONDecoder().decode(
      AIAgentPermissionPolicy.self,
      from: Data(
        #"{"enabledScopes":["publishing"],"allowedScopes":["localRead"]}"#.utf8
      )
    )

    XCTAssertEqual(decoded.enabledScopes, [.publishing])
  }

  func testEncodingUsesStableSortedScopeValues() throws {
    let policy = AIAgentPermissionPolicy(
      enabledScopes: [.publishing, .localRead, .networkAccess]
    )
    let encoded = try JSONEncoder().encode(policy)
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )

    XCTAssertEqual(
      payload["enabledScopes"] as? [String],
      ["localRead", "networkAccess", "publishing"]
    )
    XCTAssertNil(payload["allowedScopes"])
  }

  func testMasterSwitchGatesEffectiveScopesWithoutDiscardingSelections() {
    let policy = AIAgentPermissionPolicy(
      enabledScopes: [.localRead, .networkAccess]
    )

    XCTAssertEqual(policy.effectiveScopes(masterEnabled: true), policy.enabledScopes)
    XCTAssertEqual(policy.effectiveScopes(masterEnabled: false), [])
    XCTAssertTrue(policy.allows(.networkAccess, masterEnabled: true))
    XCTAssertFalse(policy.allows(.networkAccess, masterEnabled: false))
  }
}
