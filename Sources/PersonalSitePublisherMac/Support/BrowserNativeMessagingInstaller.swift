import Foundation
import KnowledgeNativeMessagingSupport

enum BrowserNativeMessagingBrowser: String, CaseIterable, Identifiable, Hashable {
  case firefox
  case chrome
  case edge

  var id: String { rawValue }

  var localizedDisplayName: String {
    switch self {
    case .firefox: "Firefox"
    case .chrome: "Google Chrome"
    case .edge: "Microsoft Edge"
    }
  }

  var family: KnowledgeNativeMessagingProtocol.BrowserFamily {
    self == .firefox ? .firefox : .chromium
  }

  fileprivate var userManifestDirectory: String {
    switch self {
    case .firefox:
      "Library/Application Support/Mozilla/NativeMessagingHosts"
    case .chrome:
      "Library/Application Support/Google/Chrome/NativeMessagingHosts"
    case .edge:
      "Library/Application Support/Microsoft Edge/NativeMessagingHosts"
    }
  }
}

struct BrowserNativeMessagingInstallationState: Equatable {
  var browser: BrowserNativeMessagingBrowser
  var isInstalled: Bool
  var manifestURL: URL
  var hostExecutableURL: URL?
  var detail: String
}

enum BrowserNativeMessagingInstaller {
  static func detectAll(
    fileManager: FileManager = .default
  ) -> [BrowserNativeMessagingBrowser: BrowserNativeMessagingInstallationState] {
    Dictionary(uniqueKeysWithValues: BrowserNativeMessagingBrowser.allCases.map {
      ($0, detect(browser: $0, fileManager: fileManager))
    })
  }

  static func detect(
    browser: BrowserNativeMessagingBrowser,
    fileManager: FileManager = .default
  ) -> BrowserNativeMessagingInstallationState {
    let manifestURL = userManifestURL(browser: browser, fileManager: fileManager)
    guard
      let data = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(
        KnowledgeNativeMessagingProtocol.HostManifest.self,
        from: data
      ),
      manifest.name == KnowledgeNativeMessagingProtocol.hostName,
      manifest.type == "stdio",
      manifestAllowsExpectedExtension(manifest, browser: browser)
    else {
      return .init(
        browser: browser,
        isInstalled: false,
        manifestURL: manifestURL,
        hostExecutableURL: locateHostExecutable(fileManager: fileManager),
        detail: String(localized: "尚未安装原生连接。")
      )
    }
    let hostURL = URL(fileURLWithPath: manifest.path)
    guard fileManager.isExecutableFile(atPath: hostURL.path) else {
      return .init(
        browser: browser,
        isInstalled: false,
        manifestURL: manifestURL,
        hostExecutableURL: locateHostExecutable(fileManager: fileManager),
        detail: String(localized: "宿主清单存在，但可执行文件已移动或不可执行。")
      )
    }
    return .init(
      browser: browser,
      isInstalled: true,
      manifestURL: manifestURL,
      hostExecutableURL: hostURL,
      detail: String(localized: "浏览器将通过原生宿主连接应用，不再直接访问本机 HTTP 端口。")
    )
  }

  @discardableResult
  static func install(
    browser: BrowserNativeMessagingBrowser,
    fileManager: FileManager = .default
  ) throws -> URL {
    guard let executableURL = locateHostExecutable(fileManager: fileManager),
          fileManager.isExecutableFile(atPath: executableURL.path) else {
      throw InstallationError.hostExecutableMissing
    }
    let manifestURL = userManifestURL(browser: browser, fileManager: fileManager)
    try fileManager.createDirectory(
      at: manifestURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let manifest = KnowledgeNativeMessagingProtocol.HostManifest(
      browserFamily: browser.family,
      hostPath: executableURL.resolvingSymlinksInPath().path
    )
    try manifest.encodedData().write(to: manifestURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    return manifestURL
  }

  private static func manifestAllowsExpectedExtension(
    _ manifest: KnowledgeNativeMessagingProtocol.HostManifest,
    browser: BrowserNativeMessagingBrowser
  ) -> Bool {
    switch browser.family {
    case .firefox:
      manifest.allowedExtensions == [KnowledgeNativeMessagingProtocol.firefoxExtensionID]
        && manifest.allowedOrigins == nil
    case .chromium:
      manifest.allowedExtensions == nil
        && manifest.allowedOrigins == [KnowledgeNativeMessagingProtocol.chromiumDevelopmentOrigin]
    }
  }

  private static func userManifestURL(
    browser: BrowserNativeMessagingBrowser,
    fileManager: FileManager
  ) -> URL {
    fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent(browser.userManifestDirectory, isDirectory: true)
      .appendingPathComponent("\(KnowledgeNativeMessagingProtocol.hostName).json")
  }

  private static func locateHostExecutable(fileManager: FileManager) -> URL? {
    let executableName = "KnowledgeNativeMessagingHost"
    let candidates = [
      Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(executableName),
      Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(executableName)"),
    ].compactMap { $0 }
    return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
  }

  enum InstallationError: Error, LocalizedError {
    case hostExecutableMissing

    var errorDescription: String? {
      switch self {
      case .hostExecutableMissing:
        String(localized: "当前应用包没有包含浏览器原生连接宿主，请重新构建或安装完整的直接分发版本。")
      }
    }
  }
}
