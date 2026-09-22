import AppKit
import PublishingAICore
import PublishingWorkbenchCore
import SwiftUI

@MainActor
final class LocalAIEngineSetupCoordinator: ObservableObject {
  @Published private(set) var message: String?

  static func applicationIsInstalled(kind: LocalAIEngineKind) -> Bool {
    LocalAIEngineSetupActions.isInstalled(kind: kind)
  }

  func startEngine(_ kind: LocalAIEngineKind) {
    let setupService = LocalAIEngineSetupService()
    let recommendation = setupService.recommendation(
      for: kind,
      applicationIsInstalled: LocalAIEngineSetupActions.isInstalled(kind: kind)
    )
    switch recommendation {
    case .launchApplication(let bundleIdentifier):
      Task { [weak self] in
        let didLaunch = await LocalAIEngineSetupActions.launch(bundleIdentifier: bundleIdentifier)
        self?.message =
          didLaunch
          ? String(format: String(localized: "已请求启动 %@，请稍后重新检测。"), kind.localizedTitle)
          : String(format: String(localized: "无法启动 %@。"), kind.localizedTitle)
      }
    case .openOfficialDownloadPage(let url):
      message =
        LocalAIEngineSetupActions.openOfficialDownloadPage(url)
        ? String(format: String(localized: "已打开 %@ 官方下载页面。"), kind.localizedTitle)
        : String(localized: "无法打开官方下载页面。")
    case .unavailable:
      message = String(localized: "该本地服务需要手动启动后再检测。")
    }
  }

  private enum LocalAIEngineSetupActions {
    static func isInstalled(kind: LocalAIEngineKind) -> Bool {
      guard let target = LocalAIEngineSetupService.applicationTarget(for: kind) else {
        return false
      }
      return NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleIdentifier)
        != nil
    }

    static func launch(bundleIdentifier: String) async -> Bool {
      guard
        let applicationURL = NSWorkspace.shared.urlForApplication(
          withBundleIdentifier: bundleIdentifier
        )
      else { return false }
      do {
        _ = try await NSWorkspace.shared.openApplication(
          at: applicationURL,
          configuration: NSWorkspace.OpenConfiguration()
        )
        return true
      } catch {
        return false
      }
    }

    static func openOfficialDownloadPage(_ url: URL) -> Bool {
      guard url.scheme?.lowercased() == "https",
        url.user == nil,
        url.password == nil,
        url.query == nil,
        url.fragment == nil
      else {
        return false
      }
      return NSWorkspace.shared.open(url)
    }
  }
}
