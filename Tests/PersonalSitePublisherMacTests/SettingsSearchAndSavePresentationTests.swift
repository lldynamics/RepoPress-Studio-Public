import XCTest
@testable import PersonalSitePublisherMac

final class SettingsSearchAndSavePresentationTests: XCTestCase {
  func testSearchIndexMatchesDetailedKeywordsInTheirOwningTab() {
    let expectations: [(String, SettingsTab)] = [
      ("Front Matter", .defaultRules),
      ("GitHub", .token),
      ("拼写", .editor),
      ("OPML", .rss),
      ("远程图片", .rss),
      ("自动翻译", .rss),
      ("迁移", .dataManagement),
    ]
    for (query, tab) in expectations {
      XCTAssertTrue(
        SettingsSearchIndex.search(query: query).contains { $0.tab == tab },
        "\(query) should reach \(tab)"
      )
    }
  }

  func testBlankSearchReturnsNoIndexedResults() {
    XCTAssertTrue(SettingsSearchIndex.search(query: "  ").isEmpty)
  }

  @MainActor
  func testSearchResultAccessibilityIncludesTheDistinguishingDetail() throws {
    let item = try XCTUnwrap(
      SettingsSearchIndex.allItems.first { $0.id == "ai.credentials" }
    )

    let label = SettingsNavigationList.searchResultAccessibilityLabel(for: item)
    XCTAssertTrue(label.contains(item.sectionTitle))
    XCTAssertTrue(label.contains(item.tab.title))
    XCTAssertTrue(label.contains(item.detail))
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
