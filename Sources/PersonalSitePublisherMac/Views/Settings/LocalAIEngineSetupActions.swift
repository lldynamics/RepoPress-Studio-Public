import AppKit
import PublishingWorkbenchCore
import SwiftUI

@MainActor
final class LocalAIEngineSetupCoordinator: ObservableObject {
  @Published var ollamaModelID = ""
  @Published private(set) var downloadProgress: LocalAIModelDownloadProgress?
  @Published private(set) var message: String?
  @Published private(set) var isDownloading = false

  private var downloadTask: Task<Void, Never>?

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

  func startOllamaDownload(onCompletion: @escaping @MainActor () -> Void) {
    let modelID = ollamaModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !modelID.isEmpty else {
      message = String(localized: "请输入要下载的精确模型 ID。")
      return
    }
    cancelDownload(announce: false)
    ollamaModelID = modelID
    downloadProgress = nil
    isDownloading = true
    message = String(localized: "正在请求本机 Ollama 下载模型。")

    downloadTask = Task { [weak self] in
      do {
        for try await progress in LocalAIModelDownloadService().pull(modelID: modelID) {
          guard !Task.isCancelled else { return }
          self?.downloadProgress = progress
        }
        guard !Task.isCancelled else { return }
        self?.isDownloading = false
        self?.downloadTask = nil
        self?.message = String(localized: "模型下载完成，正在刷新本地候选。")
        onCompletion()
      } catch is CancellationError {
        guard !Task.isCancelled else { return }
        self?.isDownloading = false
        self?.downloadTask = nil
        self?.message = String(localized: "已停止等待本机模型下载。")
      } catch {
        guard !Task.isCancelled else { return }
        self?.isDownloading = false
        self?.downloadTask = nil
        // Do not surface transport strings: a local proxy or engine could put
        // credentials in them. The typed download errors have safe summaries.
        self?.message =
          (error as? LocalAIModelDownloadError)?.localizedDescription
          ?? String(localized: "本机模型下载失败，请检查 Ollama 后重试。")
      }
    }
  }

  func openOllamaModelLibrary() {
    message =
      LocalAIEngineSetupActions.openOfficialDownloadPage(
        LocalAIEngineSetupService.ollamaModelLibraryURL
      )
      ? String(localized: "已打开 Ollama 官方模型库。")
      : String(localized: "无法打开 Ollama 官方模型库。")
  }

  func cancelDownload(announce: Bool = true) {
    guard downloadTask != nil else { return }
    downloadTask?.cancel()
    downloadTask = nil
    isDownloading = false
    if announce {
      message = String(localized: "已停止等待本机模型下载。")
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
