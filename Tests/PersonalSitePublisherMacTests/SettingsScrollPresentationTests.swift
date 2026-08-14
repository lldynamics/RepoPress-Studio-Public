import AppKit
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class SettingsScrollPresentationTests: XCTestCase {
  func testSettingsStylingInstallsNativeVerticalScrollerAndSuppressesHorizontal() {
    let settingsScrollView = NSScrollView(
      frame: NSRect(x: 0, y: 0, width: 640, height: 480)
    )
    settingsScrollView.hasVerticalScroller = true
    settingsScrollView.hasHorizontalScroller = true

    let unrelatedScrollView = NSScrollView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 240)
    )
    unrelatedScrollView.hasVerticalScroller = true

    SettingsScrollViewStyling.install(on: settingsScrollView)

    XCTAssertTrue(settingsScrollView.verticalScroller is ThinRedScroller)
    XCTAssertEqual(settingsScrollView.verticalScroller?.scrollerStyle, .overlay)
    XCTAssertFalse(settingsScrollView.hasHorizontalScroller)
    XCTAssertEqual(settingsScrollView.horizontalScrollElasticity, .none)
    XCTAssertFalse(unrelatedScrollView.verticalScroller is ThinRedScroller)
  }

  func testSettingsStylingRecursesOnlyThroughTheProvidedSettingsView() {
    let settingsRoot = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    let settingsScrollView = NSScrollView(
      frame: NSRect(x: 0, y: 0, width: 640, height: 480)
    )
    settingsScrollView.hasVerticalScroller = true
    settingsRoot.addSubview(settingsScrollView)

    let unrelatedRoot = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    let unrelatedScrollView = NSScrollView(
      frame: NSRect(x: 0, y: 0, width: 640, height: 480)
    )
    unrelatedScrollView.hasVerticalScroller = true
    unrelatedRoot.addSubview(unrelatedScrollView)

    SettingsScrollViewStyling.install(in: settingsRoot)

    XCTAssertTrue(settingsScrollView.verticalScroller is ThinRedScroller)
    XCTAssertFalse(unrelatedScrollView.verticalScroller is ThinRedScroller)
  }

  func testThinScrollerPreservesNativeHitAreaWhileDrawingAThinKnob() {
    let nativeWidth = NSScroller.scrollerWidth(
      for: .regular,
      scrollerStyle: .overlay
    )
    let customWidth = ThinRedScroller.scrollerWidth(
      for: .regular,
      scrollerStyle: .overlay
    )

    XCTAssertEqual(customWidth, nativeWidth)
    XCTAssertGreaterThanOrEqual(ThinRedScroller.thinWidth, 2)
    XCTAssertLessThanOrEqual(ThinRedScroller.thinWidth, 3)
    XCTAssertLessThan(ThinRedScroller.thinWidth, nativeWidth)
  }

  func testSettingsTopLevelPagesDeclareOneNativeVerticalScrollOwner() {
    XCTAssertEqual(
      SettingsTab.siteSettings.map(\.scrollOwnership),
      Array(repeating: .nativeForm, count: SettingsTab.siteSettings.count)
    )
    XCTAssertEqual(
      SettingsTab.applicationSettings.map(\.scrollOwnership),
      [.nativeScrollView, .nativeForm, .nativeForm, .nativeForm, .nativeForm]
    )
    XCTAssertTrue(
      SettingsTab.allCases.allSatisfy {
        $0.scrollOwnership == .nativeForm || $0.scrollOwnership == .nativeScrollView
      }
    )
  }

  func testSettingsWindowScopeDoesNotIncludeAnUnrelatedWindow() {
    let settingsWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    let unrelatedWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )

    XCTAssertTrue(SettingsScrollViewStyling.belongs(candidate: settingsWindow, to: settingsWindow))
    XCTAssertFalse(SettingsScrollViewStyling.belongs(candidate: unrelatedWindow, to: settingsWindow))
  }
}
