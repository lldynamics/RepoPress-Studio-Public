import PublishingAICore
import XCTest

@testable import PersonalSitePublisherMac

final class AIConnectionReconfigurationTests: XCTestCase {
  func testStagingAndCancellingPreserveConfigurationAndDoNotInvokeCommit() throws {
    let connection = connection()
    let original = connection.config
    let sites = [UUID(): "站点 A", UUID(): "站点 B"]
    var state = AIConnectionReconfigurationState()
    state.stage(connection: connection, proposedConfig: replacement(), referencingSites: sites)
    let request = try XCTUnwrap(state.pending)
    XCTAssertEqual(connection.config, original)
    XCTAssertEqual(request.referencingSites, sites)
    XCTAssertTrue(request.invalidatesAPIKey)
    state.cancel()
    var commits = 0
    XCTAssertEqual(
      state.confirm(
        requestID: request.id, selectedConnectionID: connection.id, connection: connection,
        referencingSites: sites,
        commit: { _, _, _, _ in
          commits += 1
          return true
        }), .expired)
    XCTAssertEqual(commits, 0)
  }

  func testConfirmationCommitsExactApprovedSnapshotOnlyOnce() throws {
    var connection = connection()
    let original = connection.config
    let proposed = replacement()
    let sites = [UUID(): "站点 A"]
    var state = AIConnectionReconfigurationState()
    state.stage(connection: connection, proposedConfig: proposed, referencingSites: sites)
    let request = try XCTUnwrap(state.pending)
    var commits = 0
    let result = state.confirm(
      requestID: request.id, selectedConnectionID: connection.id, connection: connection,
      referencingSites: sites
    ) { id, expected, updated, approvedSites in
      commits += 1
      XCTAssertEqual(id, connection.id)
      XCTAssertEqual(expected, original)
      XCTAssertEqual(updated, proposed)
      XCTAssertEqual(approvedSites, sites)
      connection.config = updated
      return true
    }
    XCTAssertEqual(result, .applied)
    XCTAssertEqual(connection.config, proposed)
    XCTAssertNil(state.pending)
    XCTAssertEqual(
      state.confirm(
        requestID: request.id, selectedConnectionID: connection.id, connection: connection,
        referencingSites: sites,
        commit: { _, _, _, _ in
          commits += 1
          return true
        }), .expired)
    XCTAssertEqual(commits, 1)
  }

  func testSelectionDeletionExternalEditAndChangedSiteReferencesExpireWithoutCommit() throws {
    let original = connection()
    let sites = [UUID(): "站点 A"]
    var edited = original
    edited.config.model = "external-model"
    let contexts: [(UUID, AIConnectionProfile?, [UUID: String])] = [
      (UUID(), original, sites),
      (original.id, nil, sites),
      (original.id, edited, sites),
      (original.id, original, [:]),
      (original.id, original, sites.merging([UUID(): "新加入站点"]) { _, new in new }),
      (original.id, original, sites.mapValues { _ in "已更名站点" }),
    ]
    for (selectedID, current, currentSites) in contexts {
      var state = AIConnectionReconfigurationState()
      state.stage(connection: original, proposedConfig: replacement(), referencingSites: sites)
      let request = try XCTUnwrap(state.pending)
      var commits = 0
      let result = state.confirm(
        requestID: request.id, selectedConnectionID: selectedID, connection: current,
        referencingSites: currentSites,
        commit: { _, _, _, _ in
          commits += 1
          return true
        })
      XCTAssertEqual(result, .expired)
      XCTAssertEqual(commits, 0)
      XCTAssertNil(state.pending)
    }
  }

  func testLateConfirmationCannotConsumeNewerPendingRequest() throws {
    let connection = connection()
    var state = AIConnectionReconfigurationState()
    state.stage(connection: connection, proposedConfig: replacement(), referencingSites: [:])
    let oldRequest = try XCTUnwrap(state.pending)
    var otherProposal = replacement()
    otherProposal.baseURL = "https://other.example.com/v1"
    state.stage(connection: connection, proposedConfig: otherProposal, referencingSites: [:])
    let newRequest = try XCTUnwrap(state.pending)
    XCTAssertEqual(
      state.confirm(
        requestID: oldRequest.id, selectedConnectionID: connection.id, connection: connection,
        referencingSites: [:],
        commit: { _, _, _, _ in
          XCTFail("Late commit")
          return true
        }),
      .expired)
    XCTAssertEqual(state.pending, newRequest)
  }

  func testRejectedLiveCommitRetainsOriginalConfiguration() throws {
    let connection = connection()
    let original = connection.config
    var state = AIConnectionReconfigurationState()
    state.stage(connection: connection, proposedConfig: replacement(), referencingSites: [:])
    let request = try XCTUnwrap(state.pending)
    XCTAssertEqual(
      state.confirm(
        requestID: request.id, selectedConnectionID: connection.id, connection: connection,
        referencingSites: [:], commit: { _, _, _, _ in false }), .failed)
    XCTAssertEqual(connection.config, original)
    XCTAssertNil(state.pending)
  }

  func testModelOnlyChangeDoesNotInvalidateCredentialButEndpointAndPresetChangesDo() throws {
    let connection = connection()
    var changed = connection.config
    changed.model = "another-model"
    var state = AIConnectionReconfigurationState()
    state.stage(connection: connection, proposedConfig: changed, referencingSites: [:])
    XCTAssertFalse(try XCTUnwrap(state.pending).invalidatesAPIKey)
    changed.baseURL = "https://other.example.com/v1"
    state.stage(connection: connection, proposedConfig: changed, referencingSites: [:])
    XCTAssertTrue(try XCTUnwrap(state.pending).invalidatesAPIKey)
    changed = connection.config
    changed.preset = .openAICompatible
    state.stage(connection: connection, proposedConfig: changed, referencingSites: [:])
    XCTAssertTrue(try XCTUnwrap(state.pending).invalidatesAPIKey)
  }

  func testReferenceSnapshotIncludesOnlyActualConnectionBindings() {
    let connection = connection()
    let siteA = (id: UUID(), name: "站点 A", connectionID: Optional(connection.id))
    let siteB = (id: UUID(), name: "站点 B", connectionID: Optional(UUID()))
    XCTAssertEqual(
      AIConnectionReconfigurationState.referencingSites(for: connection.id, in: [siteA, siteB]),
      [siteA.id: "站点 A"])
  }

  private func connection() -> AIConnectionProfile {
    AIConnectionProfile(
      name: "Shared API",
      config: AIProviderConfig(
        preset: .custom, baseURL: "https://original.example.com/v1", model: "original-model"))
  }

  private func replacement() -> AIProviderConfig {
    var config = AIProviderConfig(preset: .deepSeek)
    config.applyPresetDefaults()
    return config
  }
}
