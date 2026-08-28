import AppKit
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class SettingsScrollPresentationTests: XCTestCase {
  func testDetailBoundaryPolicyMapsOnlyOverscrollAtTheMatchingEdge() {
    XCTAssertEqual(
      SettingsDetailScrollBoundaryPolicy.direction(
        forVerticalDelta: 4, atTop: true, atBottom: false),
      .previous
    )
    XCTAssertEqual(
      SettingsDetailScrollBoundaryPolicy.direction(
        forVerticalDelta: -4, atTop: false, atBottom: true),
      .next
    )
    XCTAssertNil(
      SettingsDetailScrollBoundaryPolicy.direction(
        forVerticalDelta: 4, atTop: false, atBottom: true))
    XCTAssertNil(
      SettingsDetailScrollBoundaryPolicy.direction(
        forVerticalDelta: -4, atTop: true, atBottom: false))
    XCTAssertNil(
      SettingsDetailScrollBoundaryPolicy.direction(forVerticalDelta: 0, atTop: true, atBottom: true)
    )
    XCTAssertEqual(SettingsDetailScrollBoundaryDirection.previous.arrival, .bottom)
    XCTAssertEqual(SettingsDetailScrollBoundaryDirection.next.arrival, .top)
  }

  func testDetailStylingHidesBothIndicatorsWithoutDisablingScrolling() {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true

    SettingsDetailScrollViewStyling.install(on: scrollView)

    XCTAssertFalse(scrollView.hasVerticalScroller)
    XCTAssertFalse(scrollView.hasHorizontalScroller)
    XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)
  }

  func testDetailHandoffGatePreventsOneGestureFromCascadingAcrossPages() {
    let gate = SettingsDetailScrollHandoffGate()

    gate.prepareForEvent(phase: [.began], momentumPhase: [], timestamp: 1)
    XCTAssertTrue(gate.lock())

    gate.prepareForEvent(phase: [.changed], momentumPhase: [], timestamp: 1.1)
    XCTAssertFalse(gate.lock())

    gate.prepareForEvent(phase: [.ended], momentumPhase: [], timestamp: 1.2)
    gate.prepareForEvent(phase: [.began], momentumPhase: [], timestamp: 2)
    XCTAssertTrue(gate.lock())

    gate.prepareForEvent(phase: [], momentumPhase: [], timestamp: 2.1)
    XCTAssertFalse(gate.lock())
    gate.prepareForEvent(phase: [], momentumPhase: [], timestamp: 2.3)
    XCTAssertFalse(gate.lock())
    gate.prepareForEvent(phase: [], momentumPhase: [], timestamp: 2.5)
    XCTAssertFalse(gate.lock())

    gate.prepareForEvent(phase: [], momentumPhase: [], timestamp: 2.8)
    XCTAssertTrue(gate.lock())
  }

  func testDetailBridgeFindsCenteredDetailScrollViewWithoutStylingUnrelatedSidebar() {
    var boundaryCrossings: [SettingsDetailScrollBoundaryDirection] = []
    let handoffGate = SettingsDetailScrollHandoffGate()
    let rootView = HStack(spacing: 0) {
      ScrollView {
        LazyVStack {
          ForEach(0..<40, id: \.self) { index in
            Text("侧栏项 \(index)")
              .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
          }
        }
      }
      .frame(width: 160)

      Divider()

      ScrollView {
        LazyVStack {
          ForEach(0..<40, id: \.self) { index in
            Text("设置项 \(index)")
              .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
          }
        }
      }
      .frame(maxWidth: 520, maxHeight: .infinity)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .top) {
        SettingsDetailScrollBridge(handoffGate: handoffGate) { direction in
          boundaryCrossings.append(direction)
        }
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
      }
    }
    .frame(width: 1_000, height: 480)

    let hostingView = NSHostingView(rootView: rootView)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 480),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
    defer {
      window.contentView = nil
      window.orderOut(nil)
    }

    window.layoutIfNeeded()
    for _ in 0..<6 {
      RunLoop.main.run(until: Date().addingTimeInterval(0.1))
      window.layoutIfNeeded()
      hostingView.layoutSubtreeIfNeeded()
      hostingView.displayIfNeeded()
    }

    let scrollViews = descendantScrollViews(in: hostingView)
    let markerViews = descendantMarkerViews(in: hostingView)
    let debugSummary =
      "scrolls=\(scrollViews.map { $0.convert($0.bounds, to: nil).debugDescription }); markers=\(markerViews.map { $0.convert($0.bounds, to: nil).debugDescription })"
    guard scrollViews.count == 2 else {
      XCTFail(debugSummary)
      return
    }
    let scrollViewsByWidth = scrollViews.sorted { $0.frame.width < $1.frame.width }
    XCTAssertTrue(scrollViewsByWidth[0].hasVerticalScroller, debugSummary)
    XCTAssertFalse(scrollViewsByWidth[1].hasVerticalScroller, debugSummary)
    XCTAssertTrue(boundaryCrossings.isEmpty)
  }

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
    XCTAssertFalse(
      SettingsScrollViewStyling.belongs(candidate: unrelatedWindow, to: settingsWindow))
  }

  private func descendantScrollViews(in view: NSView) -> [NSScrollView] {
    var result: [NSScrollView] = []
    if let scrollView = view as? NSScrollView {
      result.append(scrollView)
    }
    for subview in view.subviews {
      result.append(contentsOf: descendantScrollViews(in: subview))
    }
    return result
  }

  private func descendantMarkerViews(in view: NSView) -> [SettingsDetailScrollBridge.MarkerView] {
    var result: [SettingsDetailScrollBridge.MarkerView] = []
    if let markerView = view as? SettingsDetailScrollBridge.MarkerView {
      result.append(markerView)
    }
    for subview in view.subviews {
      result.append(contentsOf: descendantMarkerViews(in: subview))
    }
    return result
  }
}
