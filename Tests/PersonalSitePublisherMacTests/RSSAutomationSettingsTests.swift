import Foundation
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class RSSAutomationSettingsTests: XCTestCase {
  func testDefaultsAndIntervalOptionsAreCentralized() {
    XCTAssertTrue(RSSReaderUserPreferences.defaultBackgroundRefreshEnabled)
    XCTAssertEqual(RSSReaderUserPreferences.defaultBackgroundRefreshIntervalMinutes, 30)
    XCTAssertTrue(RSSReaderUserPreferences.defaultAutomaticMarkReadAtEndEnabled)
    XCTAssertEqual(
      RSSReaderUserPreferences.backgroundRefreshIntervalOptions,
      [15, 30, 60, 120]
    )
    XCTAssertEqual(
      RSSReaderUserPreferences.normalizedBackgroundRefreshIntervalMinutes(0),
      15
    )
    XCTAssertEqual(
      RSSReaderUserPreferences.normalizedBackgroundRefreshIntervalMinutes(45),
      30
    )
    XCTAssertEqual(
      RSSReaderUserPreferences.normalizedBackgroundRefreshIntervalMinutes(999),
      120
    )
    XCTAssertEqual(
      RSSReaderUserPreferences.backgroundRefreshIntervalSeconds(60),
      60 * 60
    )
  }

  func testMarkReadPolicyKeepsProgressPersistenceIndependentFromReadGating() {
    XCTAssertTrue(
      RSSReaderUserPreferences.shouldAutomaticallyMarkReadAtEnd(
        enabled: true,
        previousProgress: 0.994,
        progress: 0.995
      )
    )
    XCTAssertFalse(
      RSSReaderUserPreferences.shouldAutomaticallyMarkReadAtEnd(
        enabled: false,
        previousProgress: 0.994,
        progress: 0.995
      )
    )
    XCTAssertFalse(
      RSSReaderUserPreferences.shouldAutomaticallyMarkReadAtEnd(
        enabled: true,
        previousProgress: 0.995,
        progress: 1
      )
    )
  }

  func testContentEntryRefreshUsesTheSamePersistedBackgroundPolicy() {
    XCTAssertFalse(
      RSSReaderBackgroundRefreshPolicy.shouldRefreshStaleFeedsOnEntry(
        isSceneActive: true,
        isSafeMode: false,
        isEnabled: false,
        isRSSSectionSelected: true
      )
    )
    XCTAssertTrue(
      RSSReaderBackgroundRefreshPolicy.shouldRefreshStaleFeedsOnEntry(
        isSceneActive: true,
        isSafeMode: false,
        isEnabled: true,
        isRSSSectionSelected: true
      )
    )
    XCTAssertFalse(
      RSSReaderBackgroundRefreshPolicy.shouldRefreshStaleFeedsOnEntry(
        isSceneActive: true,
        isSafeMode: true,
        isEnabled: true,
        isRSSSectionSelected: true
      )
    )
  }

  @MainActor
  func testBackgroundRefreshReconfigurationReplacesRunningTimer() {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RSSAutomationSettingsTests-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("reader.sqlite")
    let store = RSSReaderStore(fileURL: fileURL)
    defer {
      store.stopBackgroundRefresh()
      try? FileManager.default.removeItem(at: directory)
    }

    store.startBackgroundRefresh(interval: 15 * 60)
    XCTAssertTrue(store.isBackgroundRefreshRunning)
    XCTAssertEqual(store.configuredBackgroundRefreshInterval, 15 * 60)

    store.startBackgroundRefresh(interval: 60 * 60)
    XCTAssertTrue(store.isBackgroundRefreshRunning)
    XCTAssertEqual(store.configuredBackgroundRefreshInterval, 60 * 60)

    store.configureBackgroundRefresh(enabled: false, interval: 30 * 60)
    XCTAssertFalse(store.isBackgroundRefreshRunning)
    XCTAssertNil(store.configuredBackgroundRefreshInterval)
  }
}
