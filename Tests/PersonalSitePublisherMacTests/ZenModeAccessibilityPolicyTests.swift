import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class ZenModeToolbarVisibilityPolicyTests: XCTestCase {
  func testNormalModeAlwaysKeepsToolbarVisible() {
    XCTAssertEqual(
      policy(isZenModeActive: false, isRecentlyTyped: true).toolbarOpacity,
      1.0
    )
  }

  func testZenModeUsesPointerHoverAndRecentTypingStates() {
    XCTAssertEqual(
      policy(isPointerHovering: true, isRecentlyTyped: true).toolbarOpacity,
      1.0
    )
    XCTAssertEqual(
      policy(isRecentlyTyped: true).toolbarOpacity,
      0.08
    )
    XCTAssertEqual(
      policy().toolbarOpacity,
      0.40
    )
  }

  func testKeyboardNavigationAndVoiceOverNeverFadeToolbar() {
    XCTAssertEqual(
      policy(isKeyboardNavigationActive: true, isRecentlyTyped: true).toolbarOpacity,
      1.0
    )
    XCTAssertEqual(
      policy(isVoiceOverEnabled: true, isRecentlyTyped: true).toolbarOpacity,
      1.0
    )
  }

  func testReduceMotionDisablesAnimatedTransitions() {
    XCTAssertFalse(policy(reduceMotion: true).usesAnimatedTransitions)
    XCTAssertTrue(policy(reduceMotion: false).usesAnimatedTransitions)
  }

  private func policy(
    isZenModeActive: Bool = true,
    isPointerHovering: Bool = false,
    isKeyboardNavigationActive: Bool = false,
    isVoiceOverEnabled: Bool = false,
    isRecentlyTyped: Bool = false,
    reduceMotion: Bool = false
  ) -> ZenModeToolbarVisibilityPolicy {
    ZenModeToolbarVisibilityPolicy(
      isZenModeActive: isZenModeActive,
      isPointerHovering: isPointerHovering,
      isKeyboardNavigationActive: isKeyboardNavigationActive,
      isVoiceOverEnabled: isVoiceOverEnabled,
      isRecentlyTyped: isRecentlyTyped,
      reduceMotion: reduceMotion
    )
  }
}

@MainActor
final class ZenModeControllerAccessibilityTests: XCTestCase {
  func testKeyboardNavigationSessionEndsWhenTypingResumes() {
    let controller = ZenModeController(
      voiceOverEnabled: false,
      reduceMotionEnabled: true
    )
    controller.toggleZenMode()
    controller.beginKeyboardNavigation()
    controller.isRecentlyTyped = true

    XCTAssertEqual(controller.toolbarOpacity, 1.0)
    controller.handleTypingActivity()
    XCTAssertFalse(controller.isKeyboardNavigationActive)
    XCTAssertEqual(controller.toolbarOpacity, 0.08)
  }

  func testExitingZenEndsKeyboardNavigationSession() {
    let controller = ZenModeController(
      voiceOverEnabled: false,
      reduceMotionEnabled: true
    )
    controller.toggleZenMode()
    controller.beginKeyboardNavigation()
    controller.toggleZenMode()

    XCTAssertFalse(controller.isZenModeActive)
    XCTAssertFalse(controller.isKeyboardNavigationActive)
    XCTAssertEqual(controller.toolbarOpacity, 1.0)
  }

  func testVoiceOverStateKeepsControllerVisibleAndReduceMotionIsStored() {
    let controller = ZenModeController(
      voiceOverEnabled: true,
      reduceMotionEnabled: true
    )
    controller.toggleZenMode()
    controller.isRecentlyTyped = true

    XCTAssertTrue(controller.isVoiceOverEnabled)
    XCTAssertTrue(controller.isReduceMotionEnabled)
    XCTAssertEqual(controller.toolbarOpacity, 1.0)

    controller.setAccessibilityState(voiceOverEnabled: false, reduceMotionEnabled: true)
    XCTAssertEqual(controller.toolbarOpacity, 0.08)
  }

  func testEnablingReduceMotionCancelsPendingHoverExitAndSettlesImmediately() async {
    let controller = ZenModeController(
      voiceOverEnabled: false,
      reduceMotionEnabled: false,
      hoverExitDelayNanoseconds: 20_000_000
    )
    controller.updateHovered(true)
    controller.updateHovered(false)
    XCTAssertTrue(controller.isHovered)

    controller.setAccessibilityState(voiceOverEnabled: false, reduceMotionEnabled: true)
    XCTAssertFalse(controller.isHovered)

    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(controller.isHovered)
  }
}

final class ScreenshotCaptureWindowSizingPolicyTests: XCTestCase {
  func testRequestedContentSizeClampsToProductMinimumAndVisibleFrame() {
    let minimum = CGSize(width: 900, height: 620)
    let visible = CGSize(width: 1_600, height: 900)

    XCTAssertEqual(
      ScreenshotCaptureWindowSizingPolicy.clampedContentSize(
        requestedWidth: 100,
        requestedHeight: 200,
        visibleFrameSize: visible
      ),
      minimum
    )
    XCTAssertEqual(
      ScreenshotCaptureWindowSizingPolicy.clampedContentSize(
        requestedWidth: 2_000,
        requestedHeight: 2_000,
        visibleFrameSize: visible
      ),
      CGSize(width: 1_560, height: 860)
    )
  }

  func testInvalidEnvironmentValuesFallBackToDefaultSize() {
    XCTAssertEqual(
      ScreenshotCaptureWindowSizingPolicy.contentSizeFromEnvironment(
        environment: [
          ScreenshotCaptureWindowSizingPolicy.contentWidthEnvironmentKey: "nan",
          ScreenshotCaptureWindowSizingPolicy.contentHeightEnvironmentKey: "-1",
        ],
        visibleFrameSize: CGSize(width: 2_000, height: 1_200)
      ),
      CGSize(
        width: WorkbenchLayoutMode.defaultWindowWidth,
        height: WorkbenchLayoutMode.defaultWindowHeight
      )
    )
  }

  func testDynamicTypeOverrideAcceptsAccessibilitySizesOnly() {
    XCTAssertEqual(
      ScreenshotCaptureWindowSizingPolicy.dynamicTypeSize(from: "accessibility-3"),
      DynamicTypeSize.accessibility3
    )
    XCTAssertEqual(
      ScreenshotCaptureWindowSizingPolicy.dynamicTypeSize(from: "xxxLarge"),
      DynamicTypeSize.xxxLarge
    )
    XCTAssertNil(ScreenshotCaptureWindowSizingPolicy.dynamicTypeSize(from: "giant"))
  }
}
