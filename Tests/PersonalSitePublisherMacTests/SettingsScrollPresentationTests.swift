import AppKit
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class SettingsScrollPresentationTests: XCTestCase {
  func testDetailStylingHonorsTheSystemScrollerPreferenceWithoutRemovingTheDocumentView() {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 960))
    scrollView.documentView = documentView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true

    SettingsDetailScrollViewStyling.install(on: scrollView)

    XCTAssertTrue(scrollView.hasVerticalScroller)
    XCTAssertFalse(scrollView.hasHorizontalScroller)
    XCTAssertEqual(scrollView.scrollerStyle, NSScroller.preferredScrollerStyle)
    XCTAssertEqual(
      scrollView.autohidesScrollers,
      NSScroller.preferredScrollerStyle == .overlay
    )
    XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)
    XCTAssertTrue(scrollView.documentView === documentView)
  }

  func testSettingsStylingAppliesOnlyInsideTheProvidedSettingsView() {
    let settingsRoot = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    let settingsScrollView = NSScrollView(
      frame: NSRect(x: 0, y: 0, width: 640, height: 480)
    )
    settingsScrollView.hasVerticalScroller = true
    settingsScrollView.hasHorizontalScroller = true
    settingsRoot.addSubview(settingsScrollView)

    let unrelatedScrollView = NSScrollView(
      frame: NSRect(x: 0, y: 0, width: 320, height: 240)
    )
    unrelatedScrollView.hasVerticalScroller = true

    SettingsScrollViewStyling.install(in: settingsRoot)

    XCTAssertTrue(settingsScrollView.hasVerticalScroller)
    XCTAssertFalse(settingsScrollView.hasHorizontalScroller)
    XCTAssertTrue(unrelatedScrollView.hasVerticalScroller)
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
    XCTAssertFalse(
      SettingsScrollViewStyling.belongs(candidate: unrelatedWindow, to: settingsWindow))
  }

  func testVisibleSubsectionUsesTheLastAnchorPastTheActivationLine() {
    let frames: [SettingsSubsection: CGRect] = [
      .rulesBasics: CGRect(x: 0, y: -160, width: 1, height: 0),
      .rulesDiscovery: CGRect(x: 0, y: -8, width: 1, height: 0),
      .rulesFrontMatter: CGRect(x: 0, y: 188, width: 1, height: 0),
      .rulesPaths: CGRect(x: 0, y: 440, width: 1, height: 0),
    ]

    XCTAssertEqual(
      SettingsSubsectionVisibilityPolicy.visibleSubsection(
        in: .defaultRules,
        anchorFrames: frames
      ),
      .rulesDiscovery
    )
  }

  func testVisibleSubsectionCoversTopAndShortFinalSection() {
    let atTop: [SettingsSubsection: CGRect] = [
      .tokenRepository: CGRect(x: 0, y: 6, width: 1, height: 0),
      .tokenDeployment: CGRect(x: 0, y: 280, width: 1, height: 0),
      .tokenAnalytics: CGRect(x: 0, y: 540, width: 1, height: 0),
    ]
    let atShortFinalSection: [SettingsSubsection: CGRect] = [
      .tokenRepository: CGRect(x: 0, y: -720, width: 1, height: 0),
      .tokenDeployment: CGRect(x: 0, y: -260, width: 1, height: 0),
      // The final group is shorter than the viewport, so it stops below 0.
      .tokenAnalytics: CGRect(x: 0, y: 12, width: 1, height: 0),
    ]

    XCTAssertEqual(
      SettingsSubsectionVisibilityPolicy.visibleSubsection(in: .token, anchorFrames: atTop),
      .tokenRepository
    )
    XCTAssertEqual(
      SettingsSubsectionVisibilityPolicy.visibleSubsection(
        in: .token,
        anchorFrames: atShortFinalSection
      ),
      .tokenAnalytics
    )
  }

  func testVisibleSubsectionUsesFinalAnchorAtTheNativeBottomEdge() {
    let frames: [SettingsSubsection: CGRect] = [
      .tokenRepository: CGRect(x: 0, y: -720, width: 1, height: 0),
      .tokenDeployment: CGRect(x: 0, y: -260, width: 1, height: 0),
      .tokenAnalytics: CGRect(x: 0, y: 120, width: 1, height: 0),
    ]

    XCTAssertEqual(
      SettingsSubsectionVisibilityPolicy.visibleSubsection(
        in: .token,
        anchorFrames: frames,
        isAtBottom: true
      ),
      .tokenAnalytics
    )
  }

  func testVisibilityPolicyNeverSelectsAnAnchorFromAnotherTab() {
    XCTAssertNil(
      SettingsSubsectionVisibilityPolicy.visibleSubsection(
        in: .appearance,
        anchorFrames: [.rulesBasics: CGRect(x: 0, y: -4, width: 1, height: 0)]
      )
    )
  }

  func testAnchorScrollRequestsAreIndependentForRepeatedSelection() {
    let first = SettingsSubsectionScrollRequest(subsection: .rssCleanup)
    let second = SettingsSubsectionScrollRequest(subsection: .rssCleanup)

    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(first.subsection, second.subsection)
  }
}
