import XCTest
@testable import PersonalSitePublisherMac

final class DataManagementFlowPresentationTests: XCTestCase {
  func testDataManagementUsesFourTaskOrientedEntries() {
    XCTAssertEqual(
      DataManagementTask.allCases,
      [.drafts, .storage, .backup, .migration]
    )
    XCTAssertEqual(
      DataManagementTask.allCases.map(\.title),
      ["草稿与版本", "存储与清理", "备份与恢复", "内容迁移"]
    )
  }

  func testStructuredDataDestinationsLaunchTheExpectedTask() {
    XCTAssertEqual(DataManagementTask(destination: .drafts), .drafts)
    XCTAssertEqual(DataManagementTask(destination: .backup), .backup)
    XCTAssertEqual(DataManagementTask(destination: .migration), .migration)
  }

  func testEveryDataTaskUsesAnIndependentSheet() {
    XCTAssertEqual(
      DataManagementTask.allCases.map(\.presentation),
      [.sheet, .sheet, .sheet, .sheet]
    )
  }

  func testTaskCardsFitTheNarrowestSettingsContentWithoutEmbeddingWideTaskViews() {
    let narrowestContentWidth =
      WorkbenchSettingsMetrics.minimumWidth
      - WorkbenchSettingsMetrics.sidebarWidth
      - (WorkbenchSpacing.content * 2)

    XCTAssertGreaterThanOrEqual(
      narrowestContentWidth,
      DataManagementLayout.minimumTaskCardWidth
    )
    XCTAssertTrue(DataManagementTask.allCases.allSatisfy { $0.presentation == .sheet })
  }

  func testContentMigrationResponsiveMetricsFitNarrowSettingsContent() {
    let narrowestContentWidth =
      WorkbenchSettingsMetrics.minimumWidth
      - WorkbenchSettingsMetrics.sidebarWidth
      - (WorkbenchSpacing.content * 2)

    XCTAssertGreaterThanOrEqual(
      narrowestContentWidth,
      (ContentMigrationLayout.metricMinimumWidth * 2) + WorkbenchSpacing.card
    )
    XCTAssertLessThan(
      ContentMigrationLayout.emptyStateMinimumHeight,
      WorkbenchSettingsMetrics.minimumHeight
    )
  }
}
