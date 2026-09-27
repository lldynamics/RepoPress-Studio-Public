import Foundation
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class WorkspaceWindowTitleRegistryTests: XCTestCase {
  func testOnlySameContentWindowsReceiveStableOrdinals() {
    let registry = WorkspaceWindowTitleRegistry()
    let firstRegistrationID = UUID()
    let secondRegistrationID = UUID()
    let thirdRegistrationID = UUID()
    let firstWindowID = UUID()
    let secondWindowID = UUID()
    let thirdWindowID = UUID()
    let title = "文章 — 工作台"

    registry.register(
      windowID: firstWindowID,
      registrationID: firstRegistrationID,
      baseTitle: title
    )
    XCTAssertEqual(registry.displayTitle(for: firstRegistrationID, baseTitle: title), title)

    registry.register(
      windowID: secondWindowID,
      registrationID: secondRegistrationID,
      baseTitle: title
    )
    XCTAssertEqual(registry.displayTitle(for: firstRegistrationID, baseTitle: title), title)
    XCTAssertEqual(registry.displayTitle(for: secondRegistrationID, baseTitle: title), "\(title) 2")

    registry.register(
      windowID: thirdWindowID,
      registrationID: thirdRegistrationID,
      baseTitle: "发布 — 工作台"
    )
    XCTAssertEqual(
      registry.displayTitle(for: thirdRegistrationID, baseTitle: "发布 — 工作台"),
      "发布 — 工作台"
    )

    registry.unregister(firstRegistrationID)
    XCTAssertEqual(registry.displayTitle(for: secondRegistrationID, baseTitle: title), title)
  }

  func testChangingContentAndStaleTeardownDoNotReuseRegistration() {
    let registry = WorkspaceWindowTitleRegistry()
    let persistentWindowID = UUID()
    let staleRegistrationID = UUID()
    let replacementRegistrationID = UUID()
    let anotherRegistrationID = UUID()
    let title = "文章 — 工作台"

    registry.register(
      windowID: persistentWindowID,
      registrationID: staleRegistrationID,
      baseTitle: title
    )
    registry.register(
      windowID: persistentWindowID,
      registrationID: replacementRegistrationID,
      baseTitle: title
    )
    registry.unregister(staleRegistrationID)
    XCTAssertEqual(registry.displayTitle(for: replacementRegistrationID, baseTitle: title), title)

    registry.register(
      windowID: UUID(),
      registrationID: anotherRegistrationID,
      baseTitle: title
    )
    XCTAssertEqual(
      registry.displayTitle(for: anotherRegistrationID, baseTitle: title),
      "\(title) 2"
    )

    registry.register(
      windowID: persistentWindowID,
      registrationID: replacementRegistrationID,
      baseTitle: "发布 — 工作台"
    )
    XCTAssertEqual(
      registry.displayTitle(for: replacementRegistrationID, baseTitle: "发布 — 工作台"),
      "发布 — 工作台"
    )
    XCTAssertEqual(registry.displayTitle(for: anotherRegistrationID, baseTitle: title), title)
  }
}
