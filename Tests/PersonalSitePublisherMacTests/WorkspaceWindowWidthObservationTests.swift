import AppKit
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class WorkspaceWindowWidthObservationTests: XCTestCase {
  private typealias ObservationView = WorkspaceWindowWidthBridge.WindowWidthObservationView

  func testInitialMeasurementUsesWindowContentLayoutWidthInsteadOfViewBounds() throws {
    let window = makeWindow(width: 1_180)
    defer { window.close() }
    let view = ObservationView(frame: NSRect(x: 0, y: 0, width: 1_501, height: 500))
    var snapshots: [WorkspaceResponsiveLayoutSnapshot] = []
    view.update { snapshots.append($0) }
    try XCTUnwrap(window.contentView).addSubview(view)
    defer { view.removeFromSuperview() }

    XCTAssertNotEqual(view.bounds.width, window.contentLayoutRect.width)
    XCTAssertTrue(snapshots.isEmpty, "Measurement must not mutate SwiftUI state during attachment.")
    drainRunLoop()
    XCTAssertEqual(snapshots.map(\.band), [.compactInspector])

    view.setBoundsSize(NSSize(width: 900, height: 500))
    view.update { snapshots.append($0) }
    drainRunLoop()
    XCTAssertEqual(snapshots.map(\.band), [.compactInspector])
  }

  func testWindowResizeDeliversOnlySemanticBandChanges() throws {
    let window = makeWindow(width: 1_473)
    defer { window.close() }
    let view = ObservationView()
    var snapshots: [WorkspaceResponsiveLayoutSnapshot] = []
    view.update { snapshots.append($0) }
    try XCTUnwrap(window.contentView).addSubview(view)
    defer { view.removeFromSuperview() }
    drainRunLoop()

    resize(window, width: 1_440)
    drainRunLoop()
    XCTAssertEqual(snapshots.map(\.band), [.standardInspector])

    resize(window, width: 1_180)
    drainRunLoop()
    resize(window, width: 1_000)
    drainRunLoop()
    resize(window, width: 900)
    drainRunLoop()
    XCTAssertEqual(snapshots.map(\.band), [.standardInspector, .compactInspector, .constrained])
  }

  func testPendingMeasurementUsesLatestCallback() throws {
    let window = makeWindow(width: 1_180)
    defer { window.close() }
    let view = ObservationView()
    var originalSnapshots: [WorkspaceResponsiveLayoutSnapshot] = []
    var latestSnapshots: [WorkspaceResponsiveLayoutSnapshot] = []
    view.update { originalSnapshots.append($0) }
    try XCTUnwrap(window.contentView).addSubview(view)
    defer { view.removeFromSuperview() }

    view.update { latestSnapshots.append($0) }
    drainRunLoop()
    XCTAssertTrue(originalSnapshots.isEmpty)
    XCTAssertEqual(latestSnapshots.map(\.band), [.compactInspector])
  }

  func testPendingResizeKeepsOnlyLatestBand() throws {
    let window = makeWindow(width: 1_180)
    defer { window.close() }
    let view = ObservationView()
    var snapshots: [WorkspaceResponsiveLayoutSnapshot] = []
    view.update { snapshots.append($0) }
    try XCTUnwrap(window.contentView).addSubview(view)
    defer { view.removeFromSuperview() }
    drainRunLoop()

    resize(window, width: 1_473)
    resize(window, width: 1_180)
    drainRunLoop()
    XCTAssertEqual(snapshots.map(\.band), [.compactInspector])
  }

  func testDetachCancelsPendingMeasurementAndReattachMeasuresAgain() throws {
    let window = makeWindow(width: 1_180)
    defer { window.close() }
    let content = try XCTUnwrap(window.contentView)
    let view = ObservationView()
    var snapshots: [WorkspaceResponsiveLayoutSnapshot] = []
    view.update { snapshots.append($0) }
    content.addSubview(view)
    view.removeFromSuperview()
    drainRunLoop()
    XCTAssertTrue(snapshots.isEmpty)

    content.addSubview(view)
    defer { view.removeFromSuperview() }
    drainRunLoop()
    XCTAssertEqual(snapshots.map(\.band), [.compactInspector])
  }

  func testWindowMigrationRejectsQueuedAndLaterNotificationsFromPreviousWindow() throws {
    let previousWindow = makeWindow(width: 1_473)
    let currentWindow = makeWindow(width: 1_180)
    defer {
      previousWindow.close()
      currentWindow.close()
    }
    let view = ObservationView()
    var snapshots: [WorkspaceResponsiveLayoutSnapshot] = []
    view.update { snapshots.append($0) }
    try XCTUnwrap(previousWindow.contentView).addSubview(view)
    view.removeFromSuperview()
    try XCTUnwrap(currentWindow.contentView).addSubview(view)
    defer { view.removeFromSuperview() }
    drainRunLoop()
    XCTAssertEqual(snapshots.map(\.band), [.compactInspector])

    resize(previousWindow, width: 900)
    drainRunLoop()
    XCTAssertEqual(snapshots.map(\.band), [.compactInspector])
    resize(currentWindow, width: 900)
    drainRunLoop()
    XCTAssertEqual(snapshots.map(\.band), [.compactInspector, .constrained])
  }

  func testDismantleCancelsPendingMeasurementAndStopsResizeObservation() throws {
    let window = makeWindow(width: 1_180)
    defer { window.close() }
    let view = ObservationView()
    var snapshots: [WorkspaceResponsiveLayoutSnapshot] = []
    view.update { snapshots.append($0) }
    try XCTUnwrap(window.contentView).addSubview(view)
    defer { view.removeFromSuperview() }

    WorkspaceWindowWidthBridge.dismantleNSView(view, coordinator: ())
    resize(window, width: 900)
    drainRunLoop()
    XCTAssertTrue(snapshots.isEmpty)
  }

  func testEachWindowObservesOnlyItsOwnResizeNotifications() throws {
    let firstWindow = makeWindow(width: 1_180)
    let secondWindow = makeWindow(width: 1_473)
    defer {
      firstWindow.close()
      secondWindow.close()
    }
    let firstView = ObservationView()
    let secondView = ObservationView()
    var firstSnapshots: [WorkspaceResponsiveLayoutSnapshot] = []
    var secondSnapshots: [WorkspaceResponsiveLayoutSnapshot] = []
    firstView.update { firstSnapshots.append($0) }
    secondView.update { secondSnapshots.append($0) }
    try XCTUnwrap(firstWindow.contentView).addSubview(firstView)
    try XCTUnwrap(secondWindow.contentView).addSubview(secondView)
    defer {
      firstView.removeFromSuperview()
      secondView.removeFromSuperview()
    }
    drainRunLoop()

    resize(firstWindow, width: 900)
    drainRunLoop()
    XCTAssertEqual(firstSnapshots.map(\.band), [.compactInspector, .constrained])
    XCTAssertEqual(secondSnapshots.map(\.band), [.standardInspector])

    resize(secondWindow, width: 1_180)
    drainRunLoop()
    XCTAssertEqual(firstSnapshots.map(\.band), [.compactInspector, .constrained])
    XCTAssertEqual(secondSnapshots.map(\.band), [.standardInspector, .compactInspector])
  }

  func testMeasurementIsDeliveredInEventTrackingMode() throws {
    let window = makeWindow(width: 1_180)
    defer { window.close() }
    let view = ObservationView()
    var snapshots: [WorkspaceResponsiveLayoutSnapshot] = []
    view.update { snapshots.append($0) }
    try XCTUnwrap(window.contentView).addSubview(view)
    defer { view.removeFromSuperview() }

    drainRunLoop(mode: RunLoop.Mode("NSEventTrackingRunLoopMode"))
    XCTAssertEqual(snapshots.map(\.band), [.compactInspector])
  }

  func testNonfiniteOrNonpositiveContentLayoutWidthIsRejected() throws {
    _ = NSApplication.shared
    let window = InvalidWidthWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 700),
      styleMask: [.titled, .resizable], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = ObservationView()
    var snapshots: [WorkspaceResponsiveLayoutSnapshot] = []
    view.update { snapshots.append($0) }
    window.reportedWidth = .nan
    try XCTUnwrap(window.contentView).addSubview(view)
    defer { view.removeFromSuperview() }
    for width: CGFloat in [.nan, .infinity, -.infinity, 0, -1] {
      window.reportedWidth = width
      view.update { snapshots.append($0) }
      drainRunLoop()
    }
    XCTAssertTrue(snapshots.isEmpty)

    window.reportedWidth = 1_180
    view.update { snapshots.append($0) }
    drainRunLoop()
    XCTAssertEqual(snapshots.map(\.band), [.compactInspector])
  }

  private func makeWindow(width: CGFloat) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
      styleMask: [.titled, .resizable], backing: .buffered, defer: true
    )
    window.isReleasedWhenClosed = false
    return window
  }

  private func resize(_ window: NSWindow, width: CGFloat) {
    window.setContentSize(NSSize(width: width, height: 700))
    // Unshown test windows need no WindowServer delivery to exercise the
    // exact notification that AppKit posts during a visible live resize.
    NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
  }

  private func drainRunLoop(mode: RunLoop.Mode = .default) {
    _ = RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.01))
  }
}

@MainActor
private final class InvalidWidthWindow: NSWindow {
  var reportedWidth: CGFloat = 1_180

  override var contentLayoutRect: NSRect {
    var rect = super.contentLayoutRect
    rect.size.width = reportedWidth
    return rect
  }
}
