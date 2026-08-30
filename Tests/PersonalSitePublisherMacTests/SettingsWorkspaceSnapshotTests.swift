import AppKit
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

#if DEBUG || SCREENSHOT_CAPTURE_BUILD
  @MainActor
  final class SettingsWorkspaceSnapshotTests: XCTestCase {
    func testRenderUnifiedSettingsWorkspaceWhenSnapshotPathIsProvided() throws {
      guard
        let outputPath = ProcessInfo.processInfo.environment[
          "PERSONAL_SITE_PUBLISHER_SETTINGS_SNAPSHOT_PATH"
        ], !outputPath.isEmpty
      else {
        throw XCTSkip("Set PERSONAL_SITE_PUBLISHER_SETTINGS_SNAPSHOT_PATH to render the snapshot.")
      }

      let defaults = UserDefaults.standard
      let previousAccent = defaults.object(forKey: WorkbenchAccentPalette.storageKey)
      let previousDensity = defaults.object(forKey: WorkbenchInterfaceDensity.storageKey)
      defaults.set(
        WorkbenchAccentPalette.emerald.rawValue, forKey: WorkbenchAccentPalette.storageKey)
      defaults.set(
        WorkbenchInterfaceDensity.comfortable.rawValue,
        forKey: WorkbenchInterfaceDensity.storageKey
      )
      defer {
        if let previousAccent {
          defaults.set(previousAccent, forKey: WorkbenchAccentPalette.storageKey)
        } else {
          defaults.removeObject(forKey: WorkbenchAccentPalette.storageKey)
        }
        if let previousDensity {
          defaults.set(previousDensity, forKey: WorkbenchInterfaceDensity.storageKey)
        } else {
          defaults.removeObject(forKey: WorkbenchInterfaceDensity.storageKey)
        }
      }

      let environment = ProcessInfo.processInfo.environment
      let width =
        Double(environment["PERSONAL_SITE_PUBLISHER_SETTINGS_SNAPSHOT_WIDTH"] ?? "")
        ?? 1_487
      let height =
        Double(environment["PERSONAL_SITE_PUBLISHER_SETTINGS_SNAPSHOT_HEIGHT"] ?? "")
        ?? 1_030

      let persistence = ScreenshotDemoDataService.preparePersistenceIfEnabled()
      let store = WorkbenchStore(persistence: persistence)
      ScreenshotDemoDataService.applyRequestedSurfaceIfEnabled(to: store)
      let launchCoordinator = WorkbenchLaunchCoordinator()
      let contentSize = CGSize(width: width, height: height)
      let rootView = SettingsView(
        store: store,
        launchCoordinator: launchCoordinator,
        closeWorkspace: {},
        workspaceDestination: .tab(.appearance),
        workspaceSubsection: .appearanceTheme,
        workspaceNavigationRequestID: UUID()
      )
      .frame(width: contentSize.width, height: contentSize.height)
      .environment(\.colorScheme, .light)

      let hostingView = NSHostingView(rootView: rootView)
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: contentSize),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )
      window.appearance = NSAppearance(named: .aqua)
      window.contentView = hostingView
      window.layoutIfNeeded()

      for _ in 0..<5 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.displayIfNeeded()
        hostingView.displayIfNeeded()
      }

      let bounds = hostingView.bounds.integral
      guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: bounds) else {
        return XCTFail("Could not allocate the settings snapshot bitmap.")
      }
      bitmap.size = bounds.size
      hostingView.cacheDisplay(in: bounds, to: bitmap)
      guard let data = bitmap.representation(using: .png, properties: [:]) else {
        return XCTFail("Could not encode the settings snapshot as PNG.")
      }
      try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
      XCTAssertGreaterThan(data.count, 10_000)
    }
  }
#endif
