import XCTest
@testable import PublishingGitCore

final class RepositoryAutoSyncSettingsTests: XCTestCase {
  func testDefaultsAndRangeConstants() {
    let settings = RepositoryAutoSyncSettings.default

    XCTAssertFalse(settings.isEnabled)
    XCTAssertEqual(settings.intervalMinutes, 15)
    XCTAssertTrue(settings.fetchBeforeScan)
    XCTAssertFalse(settings.autoImportRemoteArticles)
    XCTAssertEqual(settings.normalizedIntervalMinutes, 15)
    XCTAssertEqual(settings.interval, 900)
    XCTAssertEqual(RepositoryAutoSyncSettings.minimumIntervalMinutes, 5)
    XCTAssertEqual(RepositoryAutoSyncSettings.maximumIntervalMinutes, 120)
  }

  func testInitializerClampsOnlyBelowMinimumAndNormalizationClampsAboveMaximum() {
    let belowMinimum = RepositoryAutoSyncSettings(intervalMinutes: 1)
    XCTAssertEqual(belowMinimum.intervalMinutes, 5)
    XCTAssertEqual(belowMinimum.normalizedIntervalMinutes, 5)

    let aboveMaximum = RepositoryAutoSyncSettings(intervalMinutes: 240)
    XCTAssertEqual(aboveMaximum.intervalMinutes, 240)
    XCTAssertEqual(aboveMaximum.normalizedIntervalMinutes, 120)
    XCTAssertEqual(aboveMaximum.interval, 7_200)
  }

  func testDueDecisionsCoverDisabledNeverRunElapsedAndNotElapsed() {
    let now = Date(timeIntervalSince1970: 10_000)
    let lastRun = now.addingTimeInterval(-900)

    XCTAssertFalse(
      RepositoryAutoSyncSettings(isEnabled: false).isDue(lastRunAt: nil, now: now)
    )
    XCTAssertTrue(
      RepositoryAutoSyncSettings(isEnabled: true, intervalMinutes: 15)
        .isDue(lastRunAt: nil, now: now)
    )
    XCTAssertTrue(
      RepositoryAutoSyncSettings(isEnabled: true, intervalMinutes: 15)
        .isDue(lastRunAt: lastRun, now: now)
    )
    XCTAssertFalse(
      RepositoryAutoSyncSettings(isEnabled: true, intervalMinutes: 15)
        .isDue(lastRunAt: now.addingTimeInterval(-899), now: now)
    )
  }

  func testNextRunDateUsesNormalizedInterval() {
    let start = Date(timeIntervalSince1970: 42)
    let settings = RepositoryAutoSyncSettings(intervalMinutes: 999)

    XCTAssertEqual(settings.nextRunDate(after: start), Date(timeIntervalSince1970: 42 + 7_200))
  }

  func testCodableRoundTripPreservesAllFields() throws {
    let original = RepositoryAutoSyncSettings(
      isEnabled: true,
      intervalMinutes: 30,
      fetchBeforeScan: false,
      autoImportRemoteArticles: true
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(RepositoryAutoSyncSettings.self, from: data)

    XCTAssertEqual(decoded, original)
  }

  func testDecodingMissingKeysUsesLegacyDefaults() throws {
    let decoded = try JSONDecoder().decode(
      RepositoryAutoSyncSettings.self,
      from: Data("{}".utf8)
    )

    XCTAssertEqual(decoded, .default)
  }

  func testDecodingBelowMinimumAndMissingOptionalKeysPreservesDefaults() throws {
    let decoded = try JSONDecoder().decode(
      RepositoryAutoSyncSettings.self,
      from: Data(#"{"isEnabled":true,"intervalMinutes":2}"#.utf8)
    )

    XCTAssertTrue(decoded.isEnabled)
    XCTAssertEqual(decoded.intervalMinutes, 5)
    XCTAssertTrue(decoded.fetchBeforeScan)
    XCTAssertFalse(decoded.autoImportRemoteArticles)
  }
}
