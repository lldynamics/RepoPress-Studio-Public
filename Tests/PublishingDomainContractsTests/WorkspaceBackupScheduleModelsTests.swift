import Foundation
import XCTest

@testable import PublishingDomainContracts

final class WorkspaceBackupScheduleModelsTests: XCTestCase {
  func testFrequencyIntervalsDescribeSupportedSchedules() {
    XCTAssertNil(WorkspaceBackupFrequency.off.interval)
    XCTAssertEqual(WorkspaceBackupFrequency.daily.interval, 24 * 60 * 60)
    XCTAssertEqual(WorkspaceBackupFrequency.weekly.interval, 7 * 24 * 60 * 60)
  }

  func testScheduleSettingsRoundTripWithoutLosingRestoreMetadata() throws {
    let settings = WorkspaceBackupScheduleSettings(
      frequency: .weekly,
      destinationPath: "/Volumes/Backups/RepoPress",
      lastBackupAt: Date(timeIntervalSince1970: 1_756_416_000),
      lastValidationAt: Date(timeIntervalSince1970: 1_756_419_600),
      lastBackupPath: "/Volumes/Backups/RepoPress/workspace.zip",
      lastError: "validation warning"
    )

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(WorkspaceBackupScheduleSettings.self, from: encoded)

    XCTAssertEqual(decoded, settings)
  }

  func testDefaultScheduleIsDisabledAndHasNoDestination() {
    let settings = WorkspaceBackupScheduleSettings()

    XCTAssertEqual(settings.frequency, .off)
    XCTAssertNil(settings.destinationPath)
    XCTAssertNil(settings.lastBackupAt)
    XCTAssertNil(settings.lastValidationAt)
    XCTAssertNil(settings.lastBackupPath)
    XCTAssertNil(settings.lastError)
    XCTAssertFalse(settings.preserveAutomaticBackupHistoryOnSelectedDisk)
    XCTAssertFalse(settings.destinationIsICloud)
    XCTAssertNil(settings.destinationVolumeUUID)
    XCTAssertFalse(settings.deferAutomaticBackupPruningUntilNextBackup)
  }

  func testLegacyScheduleSettingsDecodeWithSafeBackupPolicyDefaults() throws {
    let data = Data(#"{"frequency":"weekly","destinationPath":"/Volumes/Backups"}"#.utf8)
    let decoded = try JSONDecoder().decode(WorkspaceBackupScheduleSettings.self, from: data)

    XCTAssertEqual(decoded.frequency, .weekly)
    XCTAssertFalse(decoded.preserveAutomaticBackupHistoryOnSelectedDisk)
    XCTAssertFalse(decoded.destinationIsICloud)
    XCTAssertNil(decoded.destinationVolumeUUID)
    XCTAssertFalse(decoded.deferAutomaticBackupPruningUntilNextBackup)
  }
}
