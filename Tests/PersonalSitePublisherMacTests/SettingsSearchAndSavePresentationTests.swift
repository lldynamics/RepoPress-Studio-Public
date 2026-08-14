import XCTest
@testable import PersonalSitePublisherMac

final class SettingsSearchAndSavePresentationTests: XCTestCase {
  func testSearchMatchesPageTitlesAndDetailedKeywords() {
    XCTAssertTrue(SettingsTab.defaultRules.matchesSearch("Front Matter"))
    XCTAssertTrue(SettingsTab.token.matchesSearch("GitHub"))
    XCTAssertTrue(SettingsTab.ai.matchesSearch("授权"))
    XCTAssertTrue(SettingsTab.editor.matchesSearch("拼写"))
    XCTAssertTrue(SettingsTab.editor.matchesSearch("同步滚动"))
    XCTAssertTrue(SettingsTab.rss.matchesSearch("OPML"))
    XCTAssertTrue(SettingsTab.rss.matchesSearch("远程图片"))
    XCTAssertTrue(SettingsTab.rss.matchesSearch("自动翻译"))
    XCTAssertTrue(SettingsTab.dataManagement.matchesSearch("迁移"))
    XCTAssertFalse(SettingsTab.appearance.matchesSearch("仓库权限"))
  }

  func testBlankSearchKeepsEverySettingsTabVisible() {
    XCTAssertTrue(SettingsTab.allCases.allSatisfy { $0.matchesSearch("  ") })
  }

  func testSaveStatusDistinguishesIdleSavingAndFailure() {
    XCTAssertEqual(
      SettingsSaveStatusPresentation(
        hasUnsavedChanges: false,
        lastSaveError: nil,
        isRecoveryWriteProtected: false,
        recoveryMessage: nil
      ).kind,
      .idle
    )
    XCTAssertEqual(
      SettingsSaveStatusPresentation(
        hasUnsavedChanges: true,
        lastSaveError: nil,
        isRecoveryWriteProtected: false,
        recoveryMessage: nil
      ).kind,
      .saving
    )
    let failure = SettingsSaveStatusPresentation(
      hasUnsavedChanges: true,
      lastSaveError: "磁盘已满",
      isRecoveryWriteProtected: false,
      recoveryMessage: nil
    )
    XCTAssertEqual(failure.kind, .error)
    XCTAssertTrue(failure.canRetry)
  }

  func testRecoveryProtectionDoesNotOfferAnIneffectiveRetry() {
    let presentation = SettingsSaveStatusPresentation(
      hasUnsavedChanges: true,
      lastSaveError: "不会覆盖原始数据",
      isRecoveryWriteProtected: true,
      recoveryMessage: "请先恢复备份或明确重置。"
    )

    XCTAssertEqual(presentation.kind, .error)
    XCTAssertEqual(presentation.title, "请先恢复备份或明确重置。")
    XCTAssertFalse(presentation.canRetry)
  }

  func testBackupWarningDoesNotClaimThePrimarySettingsSaveFailed() {
    let presentation = SettingsSaveStatusPresentation(
      hasUnsavedChanges: false,
      lastSaveError: "无法创建备份副本",
      isRecoveryWriteProtected: false,
      recoveryMessage: nil
    )

    XCTAssertEqual(presentation.kind, .warning)
    XCTAssertEqual(presentation.title, "设置已保存，但备份副本失败：无法创建备份副本")
    XCTAssertFalse(presentation.canRetry)
  }

  func testLegacyDataSectionsStillOpenTheirEquivalentTask() {
    XCTAssertEqual(DataManagementTask(section: .drafts), .drafts)
    XCTAssertEqual(DataManagementTask(section: .backup), .backup)
    XCTAssertEqual(DataManagementTask(section: .migration), .migration)
  }
}
