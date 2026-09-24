import Foundation
import XCTest
@testable import PublishingKnowledgeCore

final class RPNoteCloudSyncEngineTests: XCTestCase {
  func testAccountSwitchIsDetectedAndDoesNotReuseBoundState() {
    let old = RPNoteCloudPersistentState(engineState: Data([1, 2]), boundAccountID: "old-account", initialFetchComplete: true)
    XCTAssertTrue(RPNoteCloudBootstrapPolicy.accountChanged("new-account", saved: old))
    XCTAssertFalse(RPNoteCloudBootstrapPolicy.maySeedLocalChanges(RPNoteCloudBootstrapPolicy.lockSeedUntilFetch(old)))

    let confirmed = RPNoteCloudBootstrapPolicy.stateForConfirmedAccountChange("new-account")
    XCTAssertEqual(confirmed.boundAccountID, "new-account")
    XCTAssertNil(confirmed.engineState)
    XCTAssertFalse(confirmed.initialFetchComplete)
  }

  func testFirstBindingNeverOpensSeedGate() {
    let empty = RPNoteCloudPersistentState()
    let bound = RPNoteCloudBootstrapPolicy.stateForFirstBinding("account", saved: empty)
    XCTAssertEqual(bound.boundAccountID, "account")
    XCTAssertFalse(RPNoteCloudBootstrapPolicy.maySeedLocalChanges(bound))
  }

  func testInvalidSerializationResetsTokenAndFetchGate() {
    let invalid = RPNoteCloudPersistentState(engineState: Data([0xff]), boundAccountID: "account", initialFetchComplete: true)
    let reset = RPNoteCloudBootstrapPolicy.resetAfterInvalidEngineState(invalid)
    XCTAssertNil(reset.engineState)
    XCTAssertFalse(reset.initialFetchComplete)
    XCTAssertEqual(reset.boundAccountID, "account")
  }

  func testPersistentStateDecodesOlderSidecarWithoutRecoveryFlag() throws {
    let oldSidecar = Data(#"{"boundAccountID":"account","initialFetchComplete":true}"#.utf8)
    let state = try JSONDecoder().decode(RPNoteCloudPersistentState.self, from: oldSidecar)
    XCTAssertEqual(state.boundAccountID, "account")
    XCTAssertTrue(state.initialFetchComplete)
    XCTAssertFalse(state.zoneRecoveryRequired)
    XCTAssertFalse(state.zoneEstablished)
  }

  func testDeletedRemoteZoneRequiresExplicitRecoveryBeforeRebinding() {
    let state = RPNoteCloudPersistentState(engineState: Data([1]), boundAccountID: "account", initialFetchComplete: true)
    let blocked = RPNoteCloudBootstrapPolicy.requireZoneRecovery(state)
    XCTAssertTrue(blocked.zoneRecoveryRequired)
    XCTAssertFalse(blocked.initialFetchComplete)
    XCTAssertFalse(RPNoteCloudBootstrapPolicy.maySeedLocalChanges(blocked))
    let confirmed = RPNoteCloudBootstrapPolicy.confirmZoneRecovery(blocked)
    XCTAssertFalse(confirmed.zoneRecoveryRequired)
    XCTAssertNil(confirmed.engineState)
    XCTAssertFalse(confirmed.initialFetchComplete)
  }

  func testSeedWaitsForSuccessfulCompleteZoneFetchAndAppliedRecords() {
    let pending = RPNoteCloudBootstrapPolicy.lockSeedUntilFetch(
      RPNoteCloudPersistentState(engineState: Data([9]), boundAccountID: "account", initialFetchComplete: true)
    )
    XCTAssertFalse(RPNoteCloudBootstrapPolicy.maySeedLocalChanges(pending))
    XCTAssertFalse(RPNoteCloudBootstrapPolicy.mayCommitFetch(completed: false, zoneFetchSucceeded: true, allRemoteChangesApplied: true))
    XCTAssertFalse(RPNoteCloudBootstrapPolicy.mayCommitFetch(completed: true, zoneFetchSucceeded: false, allRemoteChangesApplied: true))
    XCTAssertFalse(RPNoteCloudBootstrapPolicy.mayCommitFetch(completed: true, zoneFetchSucceeded: true, allRemoteChangesApplied: false))
    XCTAssertTrue(RPNoteCloudBootstrapPolicy.mayCommitFetch(completed: true, zoneFetchSucceeded: true, allRemoteChangesApplied: true))
    let completed = RPNoteCloudPersistentState(engineState: Data([9]), boundAccountID: "account", initialFetchComplete: true)
    XCTAssertTrue(RPNoteCloudBootstrapPolicy.maySeedLocalChanges(completed))
  }

  func testZoneNotFoundBeforeZoneWasEstablishedRetriesZoneCreation() {
    XCTAssertFalse(RPNoteCloudBootstrapPolicy.missingZoneRequiresRecovery(RPNoteCloudPersistentState(boundAccountID: "account")))
    XCTAssertTrue(RPNoteCloudBootstrapPolicy.missingZoneRequiresRecovery(RPNoteCloudPersistentState(boundAccountID: "account", zoneEstablished: true)))
  }

  func testMissingCloudKitEntitlementFailsStartWithoutConstructingContainer() async {
    let adapter = EmptyCloudAdapter()
    let engine = RPNoteCloudSyncEngine(
      adapter: adapter,
      isEnabled: true,
      entitlementCheck: { false }
    )
    do {
      try await engine.start()
      XCTFail("Expected missing CloudKit entitlement to fail before container creation.")
    } catch {
      guard case let .failed(message) = await engine.currentStatus() else {
        return XCTFail("Expected a visible failed status.")
      }
      XCTAssertTrue(message.contains("签名未包含"))
    }

    var constructed = false
    XCTAssertThrowsError(try RPNoteCloudSyncEngine.makeCloudContainerIfAuthorized(false, create: {
      constructed = true
      return 1
    }))
    XCTAssertFalse(constructed)
  }

  func testCloudKitEntitlementPreflightRequiresContainerAndCloudKitService() {
    XCTAssertTrue(RPNoteCloudSyncEngine.hasRequiredCloudKitEntitlements(
      containerIdentifiers: [RPNoteCloudSyncEngine.containerIdentifier],
      services: ["CloudKit"]
    ))
    XCTAssertFalse(RPNoteCloudSyncEngine.hasRequiredCloudKitEntitlements(
      containerIdentifiers: ["iCloud.example.other"],
      services: ["CloudKit"]
    ))
    XCTAssertFalse(RPNoteCloudSyncEngine.hasRequiredCloudKitEntitlements(
      containerIdentifiers: [RPNoteCloudSyncEngine.containerIdentifier],
      services: ["CloudDocuments"]
    ))
  }
}

private actor EmptyCloudAdapter: RPNoteCloudSyncLocalAdapter {
  private var state = RPNoteCloudPersistentState()

  func loadPersistentState() async throws -> RPNoteCloudPersistentState { state }
  func savePersistentState(_ state: RPNoteCloudPersistentState) async throws { self.state = state }
  func localChanges() async throws -> [RPNoteCloudLocalChange] { [] }
  func applyRemote(_ change: RPNoteCloudRemoteChange) async throws -> RPNoteCloudApplyResult { .applied }
  func markSent(id: UUID, revision: String, systemFields: Data) async throws {}
  func clearSystemFields(id: UUID, revision: String?) async throws {}
  func prepareAccountChange() async throws {}
  func prepareZoneRecovery() async throws {}
  func stageAsset(_ data: Data) async throws -> URL { FileManager.default.temporaryDirectory }
  func finishAsset(_ url: URL) async {}
  func attachmentData(noteID: UUID, attachmentID: UUID) async throws -> Data? { nil }
}
