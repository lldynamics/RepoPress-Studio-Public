import CryptoKit
import Darwin
import Foundation
import KnowledgeNativeMessagingSupport
import Security

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
    switch self {
    case .firefox: .firefox
    case .chrome: .chrome
    case .edge: .edge
    }
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

enum BrowserNativeMessagingInstallationHealth: Equatable {
  case notInstalled
  case invalidManifest
  case staleHostPath
  case hostUnavailable
  case invalidHostSignature
  case protocolMismatch
  case staleReceipt
  case healthy
}

struct BrowserNativeMessagingInstallationState: Equatable {
  var browser: BrowserNativeMessagingBrowser
  var health: BrowserNativeMessagingInstallationHealth
  var manifestURL: URL
  var receiptURL: URL
  var hostExecutableURL: URL?
  var detail: String

  var isInstalled: Bool { health == .healthy }
  var hasManifest: Bool { health != .notInstalled }
}

struct BrowserNativeMessagingRepairResult: Equatable {
  var browser: BrowserNativeMessagingBrowser
  var didRepair: Bool
  var detail: String
}

enum BrowserNativeMessagingInstaller {
  private static let receiptSuffix = ".installation-receipt.json"

  static func detectAll(
    fileManager: FileManager = .default
  ) -> [BrowserNativeMessagingBrowser: BrowserNativeMessagingInstallationState] {
    let currentHost = inspectCurrentHost(fileManager: fileManager)
    return Dictionary(uniqueKeysWithValues: BrowserNativeMessagingBrowser.allCases.map {
      ($0, detect(browser: $0, currentHost: currentHost, fileManager: fileManager))
    })
  }

  static func detect(
    browser: BrowserNativeMessagingBrowser,
    fileManager: FileManager = .default
  ) -> BrowserNativeMessagingInstallationState {
    detect(
      browser: browser,
      currentHost: inspectCurrentHost(fileManager: fileManager),
      fileManager: fileManager
    )
  }

  @discardableResult
  static func install(
    browser: BrowserNativeMessagingBrowser,
    fileManager: FileManager = .default
  ) throws -> URL {
    let currentHost = inspectCurrentHost(fileManager: fileManager)
    let inspection = try currentHost.get()
    let manifestURL = userManifestURL(browser: browser, fileManager: fileManager)
    let receiptURL = installationReceiptURL(browser: browser, fileManager: fileManager)
    try fileManager.createDirectory(
      at: manifestURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let hostPath = inspection.executableURL.resolvingSymlinksInPath().path
    let manifest = KnowledgeNativeMessagingProtocol.HostManifest(
      browserFamily: browser.family,
      hostPath: hostPath
    )
    let receipt = NativeMessagingInstallationReceipt(
      manifestPath: manifestURL.path,
      hostPath: hostPath,
      hostSHA256: inspection.sha256,
      hostProtocolVersion: inspection.handshake.payload.protocolVersion,
      applicationBundlePath: inspection.applicationBundleURL.path,
      applicationVersion: inspection.applicationVersion,
      applicationBuild: inspection.applicationBuild,
      hostSigningIdentifier: inspection.signature.signingIdentifier,
      teamIdentifier: inspection.signature.teamIdentifier
    )

    // Write the receipt first. If the manifest write then fails, detection reports a stale
    // installation instead of trusting a manifest that has no matching integrity record.
    try receipt.encodedData().write(to: receiptURL, options: .atomic)
    try manifest.encodedData().write(to: manifestURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    return manifestURL
  }

  static func uninstall(
    browser: BrowserNativeMessagingBrowser,
    fileManager: FileManager = .default
  ) throws {
    let manifestURL = userManifestURL(browser: browser, fileManager: fileManager)
    let receiptURL = installationReceiptURL(browser: browser, fileManager: fileManager)
    for url in [manifestURL, receiptURL] where fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }

  /// Repairs only connections that a previous version already installed. Missing manifests
  /// remain opt-in so launching the app never silently grants a browser a new native host.
  static func repairInstalledConnectionsAfterUpgrade(
    fileManager: FileManager = .default
  ) -> [BrowserNativeMessagingRepairResult] {
    let currentHost = inspectCurrentHost(fileManager: fileManager)
    return BrowserNativeMessagingBrowser.allCases.compactMap { browser in
      let manifestURL = userManifestURL(browser: browser, fileManager: fileManager)
      guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
      let state = detect(browser: browser, currentHost: currentHost, fileManager: fileManager)
      guard !state.isInstalled else {
        return .init(browser: browser, didRepair: false, detail: state.detail)
      }
      do {
        _ = try install(browser: browser, fileManager: fileManager)
        return .init(
          browser: browser,
          didRepair: true,
          detail: String(localized: "已自动修复旧版本原生连接。")
        )
      } catch {
        return .init(browser: browser, didRepair: false, detail: error.localizedDescription)
      }
    }
  }

  private static func detect(
    browser: BrowserNativeMessagingBrowser,
    currentHost: Result<HostInspection, InstallationError>,
    fileManager: FileManager
  ) -> BrowserNativeMessagingInstallationState {
    let manifestURL = userManifestURL(browser: browser, fileManager: fileManager)
    let receiptURL = installationReceiptURL(browser: browser, fileManager: fileManager)
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      return state(
        browser: browser,
        health: .notInstalled,
        manifestURL: manifestURL,
        receiptURL: receiptURL,
        hostURL: (try? currentHost.get())?.executableURL,
        detail: String(localized: "尚未安装原生连接。")
      )
    }
    guard
      let data = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(
        KnowledgeNativeMessagingProtocol.HostManifest.self,
        from: data
      ),
      manifest.name == KnowledgeNativeMessagingProtocol.hostName,
      manifest.type == "stdio",
      manifest.path.hasPrefix("/"),
      !manifest.path.contains("\0"),
      manifestAllowsExpectedExtension(manifest, browser: browser)
    else {
      return state(
        browser: browser,
        health: .invalidManifest,
        manifestURL: manifestURL,
        receiptURL: receiptURL,
        hostURL: (try? currentHost.get())?.executableURL,
        detail: String(localized: "宿主清单内容无效，需要修复。")
      )
    }

    let installedHostURL = URL(fileURLWithPath: manifest.path).resolvingSymlinksInPath()
    guard fileManager.isExecutableFile(atPath: installedHostURL.path) else {
      return state(
        browser: browser,
        health: .hostUnavailable,
        manifestURL: manifestURL,
        receiptURL: receiptURL,
        hostURL: installedHostURL,
        detail: String(localized: "宿主清单存在，但可执行文件已移动或不可执行。")
      )
    }
    guard case .success(let inspection) = currentHost else {
      return state(
        browser: browser,
        health: currentHost.failureHealth,
        manifestURL: manifestURL,
        receiptURL: receiptURL,
        hostURL: installedHostURL,
        detail: currentHost.failureDescription
      )
    }
    guard installedHostURL == inspection.executableURL.resolvingSymlinksInPath() else {
      return state(
        browser: browser,
        health: .staleHostPath,
        manifestURL: manifestURL,
        receiptURL: receiptURL,
        hostURL: installedHostURL,
        detail: String(localized: "清单仍指向旧应用宿主，将在应用升级后自动修复。")
      )
    }

    guard let receiptData = try? Data(contentsOf: receiptURL),
          let receipt = try? NativeMessagingInstallationReceipt.decode(receiptData),
          receipt.matches(
            manifestPath: manifestURL.path,
            hostPath: inspection.executableURL.resolvingSymlinksInPath().path,
            hostSHA256: inspection.sha256,
            hostProtocolVersion: inspection.handshake.payload.protocolVersion,
            applicationBundlePath: inspection.applicationBundleURL.path,
            applicationVersion: inspection.applicationVersion,
            applicationBuild: inspection.applicationBuild,
            hostSigningIdentifier: inspection.signature.signingIdentifier,
            teamIdentifier: inspection.signature.teamIdentifier
          ) else {
      return state(
        browser: browser,
        health: .staleReceipt,
        manifestURL: manifestURL,
        receiptURL: receiptURL,
        hostURL: installedHostURL,
        detail: String(localized: "宿主版本或完整性收据已变化，需要重新验证并修复。")
      )
    }

    return state(
      browser: browser,
      health: .healthy,
      manifestURL: manifestURL,
      receiptURL: receiptURL,
      hostURL: installedHostURL,
      detail: String(
        localized: "签名与 SHA-256 已验证；Native Messaging 协议版本 \(inspection.handshake.payload.protocolVersion) 握手成功。"
      )
    )
  }

  private static func state(
    browser: BrowserNativeMessagingBrowser,
    health: BrowserNativeMessagingInstallationHealth,
    manifestURL: URL,
    receiptURL: URL,
    hostURL: URL?,
    detail: String
  ) -> BrowserNativeMessagingInstallationState {
    .init(
      browser: browser,
      health: health,
      manifestURL: manifestURL,
      receiptURL: receiptURL,
      hostExecutableURL: hostURL,
      detail: detail
    )
  }

  private static func inspectCurrentHost(
    fileManager: FileManager
  ) -> Result<HostInspection, InstallationError> {
    do {
      guard let executableURL = locateHostExecutable(fileManager: fileManager),
            fileManager.isExecutableFile(atPath: executableURL.path) else {
        throw InstallationError.hostExecutableMissing
      }
      let applicationBundleURL = locateApplicationBundle(containing: executableURL)
      let signature = try verifiedHostSignature(
        hostURL: executableURL,
        applicationBundleURL: applicationBundleURL
      )
      let handshake: KnowledgeNativeMessagingProtocol.HandshakeResponse
      do {
        handshake = try performHandshake(hostURL: executableURL)
        try handshake.validate(
          clientProtocolVersion: KnowledgeNativeMessagingProtocol.schemaVersion
        )
      } catch {
        throw InstallationError.protocolHandshakeFailed(error.localizedDescription)
      }
      let metadata = applicationMetadata(bundleURL: applicationBundleURL)
      guard handshake.payload.applicationVersion == metadata.version,
            handshake.payload.applicationBuild == metadata.build else {
        throw InstallationError.hostApplicationVersionMismatch(
          expected: "\(metadata.version) (\(metadata.build))",
          actual: "\(handshake.payload.applicationVersion) (\(handshake.payload.applicationBuild))"
        )
      }
      return .success(
        .init(
          executableURL: executableURL,
          applicationBundleURL: applicationBundleURL,
          applicationVersion: metadata.version,
          applicationBuild: metadata.build,
          sha256: try sha256(of: executableURL),
          signature: signature,
          handshake: handshake
        )
      )
    } catch let error as InstallationError {
      return .failure(error)
    } catch {
      return .failure(.hostInspectionFailed(error.localizedDescription))
    }
  }

  private static func verifiedHostSignature(
    hostURL: URL,
    applicationBundleURL: URL
  ) throws -> NativeCodeSignatureIdentity {
    let host = try codeSignatureIdentity(at: hostURL)
    guard applicationBundleURL.pathExtension == "app" else {
      // SwiftPM development products are not inside an application bundle. They must still
      // have a structurally valid signature before the installer may execute the handshake.
      return host
    }
    let application = try codeSignatureIdentity(at: applicationBundleURL)
    let applicationIdentifier = Bundle(url: applicationBundleURL)?.bundleIdentifier
      ?? application.signingIdentifier
    let expectedHostIdentifier = "\(applicationIdentifier).KnowledgeNativeMessagingHost"
    let requiresTeamIdentifier =
      Bundle(url: applicationBundleURL)?
        .object(forInfoDictionaryKey: "PersonalSitePublisherHardenedRuntimeEnabled") as? Bool
      == true
    do {
      try NativeHostSignatureTrustPolicy.validate(
        host: host,
        application: application,
        expectedHostSigningIdentifier: expectedHostIdentifier,
        requiresTeamIdentifier: requiresTeamIdentifier
      )
    } catch {
      throw InstallationError.invalidHostSignature(error.localizedDescription)
    }
    return host
  }

  private static func codeSignatureIdentity(at url: URL) throws -> NativeCodeSignatureIdentity {
    var code: SecStaticCode?
    let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
    guard createStatus == errSecSuccess, let code else {
      throw InstallationError.invalidHostSignature(securityError(createStatus))
    }
    let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
    let validityStatus = SecStaticCodeCheckValidity(code, validationFlags, nil)
    guard validityStatus == errSecSuccess else {
      throw InstallationError.invalidHostSignature(securityError(validityStatus))
    }
    var signingInformation: CFDictionary?
    let informationStatus = SecCodeCopySigningInformation(
      code,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &signingInformation
    )
    guard informationStatus == errSecSuccess,
          let dictionary = signingInformation as? [String: Any],
          let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
          !identifier.isEmpty else {
      throw InstallationError.invalidHostSignature(securityError(informationStatus))
    }
    return NativeCodeSignatureIdentity(
      signingIdentifier: identifier,
      teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    )
  }

  private static func performHandshake(
    hostURL: URL,
    timeout: TimeInterval = 3
  ) throws -> KnowledgeNativeMessagingProtocol.HandshakeResponse {
    let requestData = try JSONEncoder().encode(
      KnowledgeNativeMessagingProtocol.Request.handshake()
    )
    let framedRequest = try KnowledgeNativeMessagingProtocol.frame(requestData)
    let input = Pipe()
    let output = Pipe()
    let errorOutput = Pipe()
    let process = Process()
    process.executableURL = hostURL
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errorOutput

    let outputBox = LockedDataBox()
    let errorBox = LockedDataBox()
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      outputBox.set(readLimited(
        from: output.fileHandleForReading,
        maximumBytes: KnowledgeNativeMessagingProtocol.maximumOutputBytes
      ))
      readers.leave()
    }
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      errorBox.set(readLimited(from: errorOutput.fileHandleForReading, maximumBytes: 64 * 1_024))
      readers.leave()
    }

    do {
      try process.run()
      try input.fileHandleForWriting.write(contentsOf: framedRequest)
      try input.fileHandleForWriting.close()
    } catch {
      if process.isRunning { process.terminate() }
      throw InstallationError.protocolHandshakeFailed(error.localizedDescription)
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
      process.terminate()
      Thread.sleep(forTimeInterval: 0.05)
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      throw InstallationError.protocolHandshakeTimedOut
    }
    guard readers.wait(timeout: .now() + 1) == .success else {
      throw InstallationError.protocolHandshakeTimedOut
    }
    let responseData = outputBox.value
    guard responseData.count <= KnowledgeNativeMessagingProtocol.maximumOutputBytes else {
      throw InstallationError.invalidHandshakeResponse(
        String(localized: "宿主握手响应超过协议大小上限。")
      )
    }
    guard responseData.count >= 4 else {
      let errorMessage = String(data: errorBox.value, encoding: .utf8) ?? ""
      throw InstallationError.invalidHandshakeResponse(errorMessage)
    }
    let payloadLength = try KnowledgeNativeMessagingProtocol.decodeLength(responseData.prefix(4))
    guard responseData.count == payloadLength + 4 else {
      throw InstallationError.invalidHandshakeResponse(
        String(localized: "宿主返回了长度不一致的握手数据。")
      )
    }
    return try JSONDecoder().decode(
      KnowledgeNativeMessagingProtocol.HandshakeResponse.self,
      from: responseData.dropFirst(4)
    )
  }

  private static func manifestAllowsExpectedExtension(
    _ manifest: KnowledgeNativeMessagingProtocol.HostManifest,
    browser: BrowserNativeMessagingBrowser
  ) -> Bool {
    switch browser.family {
    case .firefox:
      manifest.allowedExtensions == [KnowledgeNativeMessagingProtocol.firefoxExtensionID]
        && manifest.allowedOrigins == nil
    case .chrome:
      manifest.allowedExtensions == nil
        && manifest.allowedOrigins == KnowledgeNativeMessagingProtocol.chromeAllowedOrigins
    case .edge:
      manifest.allowedExtensions == nil
        && manifest.allowedOrigins == KnowledgeNativeMessagingProtocol.edgeAllowedOrigins
    }
  }

  private static func readLimited(from handle: FileHandle, maximumBytes: Int) -> Data {
    var data = Data()
    while data.count <= maximumBytes {
      let remaining = maximumBytes + 1 - data.count
      let chunk = handle.readData(ofLength: min(64 * 1_024, remaining))
      if chunk.isEmpty { break }
      data.append(chunk)
    }
    return data
  }

  private static func userManifestURL(
    browser: BrowserNativeMessagingBrowser,
    fileManager: FileManager
  ) -> URL {
    fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent(browser.userManifestDirectory, isDirectory: true)
      .appendingPathComponent("\(KnowledgeNativeMessagingProtocol.hostName).json")
  }

  private static func installationReceiptURL(
    browser: BrowserNativeMessagingBrowser,
    fileManager: FileManager
  ) -> URL {
    userManifestURL(browser: browser, fileManager: fileManager)
      .deletingLastPathComponent()
      .appendingPathComponent(
        "\(KnowledgeNativeMessagingProtocol.hostName)\(receiptSuffix)"
      )
  }

  private static func locateHostExecutable(fileManager: FileManager) -> URL? {
    let executableName = "KnowledgeNativeMessagingHost"
    let candidates = [
      Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(executableName),
      Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(executableName)"),
    ].compactMap { $0 }
    return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
  }

  private static func locateApplicationBundle(containing executableURL: URL) -> URL {
    let standardizedExecutable = executableURL.standardizedFileURL
    if Bundle.main.bundleURL.pathExtension == "app",
       standardizedExecutable.path.hasPrefix(Bundle.main.bundleURL.standardizedFileURL.path + "/") {
      return Bundle.main.bundleURL.resolvingSymlinksInPath()
    }
    return executableURL.deletingLastPathComponent().resolvingSymlinksInPath()
  }

  private static func applicationMetadata(bundleURL: URL) -> (version: String, build: String) {
    guard bundleURL.pathExtension == "app", let bundle = Bundle(url: bundleURL) else {
      return ("development", "0")
    }
    return (
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
      bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    )
  }

  private static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func securityError(_ status: OSStatus) -> String {
    SecCopyErrorMessageString(status, nil) as String?
      ?? String(localized: "代码签名验证失败（错误码 \(status)）。")
  }

  enum InstallationError: Error, LocalizedError {
    case hostExecutableMissing
    case invalidHostSignature(String)
    case protocolHandshakeFailed(String)
    case protocolHandshakeTimedOut
    case invalidHandshakeResponse(String)
    case hostApplicationVersionMismatch(expected: String, actual: String)
    case hostInspectionFailed(String)

    var errorDescription: String? {
      switch self {
      case .hostExecutableMissing:
        String(localized: "当前应用包没有包含浏览器原生连接宿主，请重新构建或安装完整的直接分发版本。")
      case .invalidHostSignature(let detail):
        String(localized: "原生宿主签名验证失败：\(detail)")
      case .protocolHandshakeFailed(let detail):
        String(localized: "原生宿主协议握手失败：\(detail)")
      case .protocolHandshakeTimedOut:
        String(localized: "原生宿主协议握手超时。")
      case .invalidHandshakeResponse(let detail):
        detail.isEmpty
          ? String(localized: "原生宿主返回了无效的版本握手。")
          : String(localized: "原生宿主返回了无效的版本握手：\(detail)")
      case .hostApplicationVersionMismatch(let expected, let actual):
        String(localized: "原生宿主来自旧应用版本：当前为 \(expected)，宿主报告 \(actual)。")
      case .hostInspectionFailed(let detail):
        String(localized: "无法验证当前原生宿主：\(detail)")
      }
    }
  }
}

private struct HostInspection {
  var executableURL: URL
  var applicationBundleURL: URL
  var applicationVersion: String
  var applicationBuild: String
  var sha256: String
  var signature: NativeCodeSignatureIdentity
  var handshake: KnowledgeNativeMessagingProtocol.HandshakeResponse
}

private final class LockedDataBox: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  var value: Data {
    lock.withLock { data }
  }

  func set(_ data: Data) {
    lock.withLock { self.data = data }
  }
}

private extension Result where Success == HostInspection, Failure == BrowserNativeMessagingInstaller.InstallationError {
  var failureDescription: String {
    switch self {
    case .success:
      String(localized: "当前原生宿主可用。")
    case .failure(let error):
      error.localizedDescription
    }
  }

  var failureHealth: BrowserNativeMessagingInstallationHealth {
    switch self {
    case .success:
      .healthy
    case .failure(let error):
      switch error {
      case .invalidHostSignature:
        .invalidHostSignature
      case .protocolHandshakeFailed, .protocolHandshakeTimedOut,
           .invalidHandshakeResponse, .hostApplicationVersionMismatch:
        .protocolMismatch
      case .hostExecutableMissing, .hostInspectionFailed:
        .hostUnavailable
      }
    }
  }
}
