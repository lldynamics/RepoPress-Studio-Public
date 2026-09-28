import Foundation
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class WorkspaceModuleVisibilityTests: XCTestCase {
  func testMissingDefaultsKeepEveryModuleEnabled() throws {
    let defaults = try isolatedDefaults()
    XCTAssertEqual(WorkspaceModuleVisibility.load(defaults: defaults), .init())
  }

  func testEachFlagFiltersOnlyItsPrimarySection() {
    let rss = WorkspaceModuleVisibility(rssEnabled: false)
    XCTAssertFalse(rss.allows(.rss))
    XCTAssertEqual(rss.primarySections, [.writing, .library, .images, .sync])

    let library = WorkspaceModuleVisibility(libraryEnabled: false)
    XCTAssertFalse(library.allows(.library))
    XCTAssertEqual(library.primarySections, [.writing, .rss, .images, .sync])

    let images = WorkspaceModuleVisibility(imagesEnabled: false)
    XCTAssertFalse(images.allows(.images))
    XCTAssertEqual(images.primarySections, [.writing, .library, .rss, .sync])
  }

  func testAllOffPreservesCoreSectionsAndFallsBackToWriting() {
    let visibility = WorkspaceModuleVisibility(
      rssEnabled: false, libraryEnabled: false, imagesEnabled: false)
    XCTAssertEqual(visibility.primarySections, [.writing, .sync])
    XCTAssertEqual(visibility.resolvedSection(.rss), .writing)
    XCTAssertEqual(visibility.resolvedSection(.library), .writing)
    XCTAssertEqual(visibility.resolvedSection(.images), .writing)
    XCTAssertTrue(visibility.allows(.writing))
    XCTAssertTrue(visibility.allows(.sync))
    XCTAssertTrue(visibility.allows(.contentHealth))
  }

  func testStoragePersistsAndReloadsUsingIsolatedDefaults() throws {
    let defaults = try isolatedDefaults()
    let storage = WorkspaceModuleVisibilityStorage(defaults: defaults)
    storage.wrappedValue = WorkspaceModuleVisibility(
      rssEnabled: false, libraryEnabled: true, imagesEnabled: false)

    XCTAssertEqual(WorkspaceModuleVisibility.load(defaults: defaults), storage.wrappedValue)
    XCTAssertFalse(defaults.bool(forKey: WorkspaceModuleVisibility.rssEnabledKey))
    XCTAssertTrue(defaults.bool(forKey: WorkspaceModuleVisibility.libraryEnabledKey))
    XCTAssertFalse(defaults.bool(forKey: WorkspaceModuleVisibility.imagesEnabledKey))
  }

  private func isolatedDefaults() throws -> UserDefaults {
    let suite = "WorkspaceModuleVisibilityTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
    return defaults
  }
}
