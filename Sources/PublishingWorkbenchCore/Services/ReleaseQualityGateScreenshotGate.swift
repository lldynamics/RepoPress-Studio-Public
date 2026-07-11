import Foundation

struct ReleaseQualityGateScreenshotGate {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func evaluate(
    root: URL,
    files: [URL],
    requiredScreenshotIDs: [String]
  ) -> (items: [ReleaseQualityGateItem], requirements: [ReleaseScreenshotRequirement]) {
    let requirements = screenshotRequirements(
      root: root,
      files: files,
      requiredScreenshotIDs: requiredScreenshotIDs
    )
    let items: [ReleaseQualityGateItem] = [
      screenshotGateItem(
        root: root,
        files: files,
        requirements: requirements
      ),
      screenshotPrivacyItem(root: root, files: files),
    ]
    return (items, requirements)
  }
    private func screenshotGateItem(
      root: URL,
      files: [URL],
      requirements: [ReleaseScreenshotRequirement]
    ) -> ReleaseQualityGateItem {
      let scriptCandidates = [
        "script/capture_app_screenshots.sh",
        "script/check_screenshots.sh",
        "script/check_release_gate.sh"
      ]
      let screenshotFiles = screenshotImageFiles(root: root, files: files)
      let missingManifestIDs = requirements.filter { $0.screenTitle.isEmpty && !$0.hasManifestTarget }.map(\.id)
      let missingManifestTargetFiles = requirements.filter { !$0.hasManifestTarget }.map(\.id)
      let missingScreenshotIDs = requirements.filter { !$0.isCaptured }.map(\.id)
  
      if let found = scriptCandidates.first(where: { fileManager.fileExists(atPath: root.appendingPathComponent($0).path) }) {
        if !missingManifestIDs.isEmpty {
          return ReleaseQualityGateItem(
            id: "screenshot-gate",
            category: .screenshots,
            title: "截图 Gate",
            status: .blocked,
            message: "截图 manifest 缺少 \(missingManifestIDs.count) 个必需场景：\(missingManifestIDs.joined(separator: ", "))。",
            evidence: "docs/app-store-screenshots/SCREENSHOT_MANIFEST.md"
          )
        }
  
        if !missingManifestTargetFiles.isEmpty {
          return ReleaseQualityGateItem(
            id: "screenshot-gate",
            category: .screenshots,
            title: "截图 Gate",
            status: .blocked,
            message: "截图 manifest 缺少 \(missingManifestTargetFiles.count) 个目标文件名：\(missingManifestTargetFiles.joined(separator: ", "))。",
            evidence: "docs/app-store-screenshots/SCREENSHOT_MANIFEST.md"
          )
        }
  
        if screenshotFiles.isEmpty {
          return ReleaseQualityGateItem(
            id: "screenshot-gate",
            category: .screenshots,
            title: "截图 Gate",
            status: .warning,
            message: "已发现截图校验脚本，但还没有真实截图文件可供上架前复核。",
            evidence: found
          )
        }
  
        if !missingScreenshotIDs.isEmpty {
          return ReleaseQualityGateItem(
            id: "screenshot-gate",
            category: .screenshots,
            title: "截图 Gate",
            status: .warning,
            message: "截图 manifest 覆盖必需场景，但还缺 \(missingScreenshotIDs.count) 个真实截图：\(missingScreenshotIDs.joined(separator: ", "))。",
            evidence: ([found] + screenshotFiles.map { relativePath($0, from: root) }.sorted()).joined(separator: ", ")
          )
        }
  
        let sourceChecks: [(relativePath: String, needle: String, label: String)] = [
          ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "recordAppStoreScreenshotExternalVerificationEvidence", "Store 截图证据记录入口"),
          ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "canRecordAppStoreScreenshotEvidence", "截图证据可记录判断"),
          ("Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift", "store.recordAppStoreScreenshotExternalVerificationEvidence", "上架页截图证据按钮"),
          ("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift", "testStoreRecordsAppStoreScreenshotExternalVerificationEvidenceWhenGateIsReady", "截图证据记录测试"),
          ("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift", "testStoreBlocksScreenshotExternalVerificationEvidenceUntilCapturedAndPrivacyPassed", "截图证据未齐阻断测试"),
        ]
        let missingSourceChecks = sourceChecks.compactMap { check -> String? in
          let sourceText = (try? String(contentsOf: root.appendingPathComponent(check.relativePath), encoding: .utf8)) ?? ""
          return sourceText.contains(check.needle) ? nil : check.label
        }
        if !missingSourceChecks.isEmpty {
          return ReleaseQualityGateItem(
            id: "screenshot-gate",
            category: .screenshots,
            title: "截图 Gate",
            status: .blocked,
            message: "截图证据闭环缺少 \(missingSourceChecks.joined(separator: "、"))。",
            evidence: "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift, Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift"
          )
        }
  
        return ReleaseQualityGateItem(
          id: "screenshot-gate",
          category: .screenshots,
          title: "截图 Gate",
          status: .passed,
          message: "已发现截图生成/校验脚本，并且 \(requirements.count) 个上架场景都有截图证据。",
          evidence: ([found] + screenshotFiles.map { relativePath($0, from: root) }.sorted()).joined(separator: ", ")
        )
      }
  
      return ReleaseQualityGateItem(
        id: "screenshot-gate",
        category: .screenshots,
        title: "截图 Gate",
        status: screenshotFiles.isEmpty ? .blocked : .warning,
        message: screenshotFiles.isEmpty ? "缺少 App Store 截图生成/校验脚本和截图证据。" : "发现截图相关文件，但缺少统一校验脚本。",
        evidence: screenshotFiles.map { relativePath($0, from: root) }.sorted().joined(separator: ", ").nilIfEmpty
      )
    }
  
    private struct ScreenshotManifestRow {
      var id: String
      var targetFileName: String
      var screenTitle: String
      var purpose: String
      var status: String
    }
  
    private func screenshotRequirements(
      root: URL,
      files: [URL],
      requiredScreenshotIDs: [String]
    ) -> [ReleaseScreenshotRequirement] {
      let manifestURL = root.appendingPathComponent("docs/app-store-screenshots/SCREENSHOT_MANIFEST.md")
      let manifestText = (try? String(contentsOf: manifestURL, encoding: .utf8)) ?? ""
      let rows = screenshotManifestRows(in: manifestText, requiredScreenshotIDs: requiredScreenshotIDs)
      let capturedPathsByID = screenshotCapturedPathsByRequiredID(
        root: root,
        files: files,
        requiredScreenshotIDs: requiredScreenshotIDs
      )
  
      return requiredScreenshotIDs.map { id in
        let row = rows[id]
        return ReleaseScreenshotRequirement(
          id: id,
          targetFileName: row?.targetFileName ?? "",
          screenTitle: row?.screenTitle ?? "",
          purpose: row?.purpose ?? "",
          manifestStatus: row?.status ?? "Manifest 缺少该截图场景",
          capturedFilePath: capturedPathsByID[id]
        )
      }
    }
  
    private func screenshotManifestRows(
      in text: String,
      requiredScreenshotIDs: [String]
    ) -> [String: ScreenshotManifestRow] {
      var rows: [String: ScreenshotManifestRow] = [:]
      for line in text.components(separatedBy: "\n") {
        let columns = markdownTableColumns(in: line)
        guard columns.count >= 3,
              let id = markdownCodeValue(in: columns[0]),
              requiredScreenshotIDs.contains(id) else {
          continue
        }
  
        rows[id] = ScreenshotManifestRow(
          id: id,
          targetFileName: markdownCodeValue(in: columns[1]) ?? "",
          screenTitle: markdownCellText(columns[2]),
          purpose: columns.count > 3 ? markdownCellText(columns[3]) : "",
          status: columns.count > 4 ? markdownCellText(columns[4]) : ""
        )
      }
      return rows
    }
  
    private func markdownTableColumns(in line: String) -> [String] {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else {
        return []
      }
      return trimmed
        .dropFirst()
        .dropLast()
        .split(separator: "|", omittingEmptySubsequences: false)
        .map { String($0).trimmingCharacters(in: .whitespaces) }
    }
  
    private func markdownCodeValue(in text: String) -> String? {
      guard let firstTick = text.firstIndex(of: "`") else {
        return nil
      }
      let afterFirstTick = text.index(after: firstTick)
      guard let secondTick = text[afterFirstTick...].firstIndex(of: "`") else {
        return nil
      }
      return String(text[afterFirstTick..<secondTick]).trimmedForPublishing.nilIfEmpty
    }
  
    private func markdownCellText(_ text: String) -> String {
      text
        .replacingOccurrences(of: "`", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
  
    private func screenshotCapturedPathsByRequiredID(
      root: URL,
      files: [URL],
      requiredScreenshotIDs: [String]
    ) -> [String: String] {
      var pathsByID: [String: String] = [:]
      for file in screenshotImageFiles(root: root, files: files) {
        let stem = file.deletingPathExtension().lastPathComponent.lowercased()
        guard let id = requiredScreenshotIDs.first(where: { id in
          stem == id || stem.hasPrefix("\(id)-") || stem.hasSuffix("-\(id)")
        }) else {
          continue
        }
        pathsByID[id] = relativePath(file, from: root)
      }
      return pathsByID
    }
  
    private func screenshotPrivacyItem(root: URL, files: [URL]) -> ReleaseQualityGateItem {
      let script = root.appendingPathComponent("script/check_screenshot_privacy.sh")
      let scriptExists = fileManager.fileExists(atPath: script.path)
      let screenshotFiles = screenshotImageFiles(root: root, files: files)
      let riskyFindings = screenshotFiles.flatMap { screenshotPrivacyFindings(in: $0, root: root) }
  
      if !riskyFindings.isEmpty {
        return ReleaseQualityGateItem(
          id: "screenshot-privacy",
          category: .screenshots,
          title: "截图隐私审计",
          status: .blocked,
          message: "截图中可能包含本地路径、Token 或授权头：\(riskyFindings.joined(separator: ", "))。",
          evidence: scriptExists ? "script/check_screenshot_privacy.sh" : nil
        )
      }
  
      if scriptExists {
        return ReleaseQualityGateItem(
          id: "screenshot-privacy",
          category: .screenshots,
          title: "截图隐私审计",
          status: .passed,
          message: screenshotFiles.isEmpty ? "已提供截图隐私审计脚本；当前还没有截图文件可审计。" : "截图隐私审计未发现本地路径、Token 或授权头。",
          evidence: ([relativePath(script, from: root)] + screenshotFiles.map { relativePath($0, from: root) }.sorted()).joined(separator: ", ")
        )
      }
  
      return ReleaseQualityGateItem(
        id: "screenshot-privacy",
        category: .screenshots,
        title: "截图隐私审计",
        status: .blocked,
        message: "缺少截图隐私审计脚本，无法自动拦截截图中的本地路径、Token 或授权头。",
        evidence: screenshotFiles.map { relativePath($0, from: root) }.sorted().joined(separator: ", ").nilIfEmpty
      )
    }
  
    private func screenshotImageFiles(root: URL, files: [URL]) -> [URL] {
      files.filter { file in
        let path = relativePath(file, from: root).lowercased()
        let extensionName = file.pathExtension.lowercased()
        return (path.contains("screenshot") || path.contains("screenshots"))
          && ["png", "jpg", "jpeg"].contains(extensionName)
      }
    }
  
    private func screenshotPrivacyFindings(in file: URL, root: URL) -> [String] {
      guard let data = try? Data(contentsOf: file) else {
        return []
      }
      let text = String(decoding: data, as: UTF8.self)
      var findings: [String] = []
      let filename = file.lastPathComponent
  
      if text.contains("/Users/")
        || text.contains("/Volumes/")
        || text.contains("file:///Users/")
        || text.contains("file:///Volumes/") {
        findings.append("\(filename): local path")
      }
  
      let secretPatterns = [
        #"github_pat_"#,
        #"ghp_[A-Za-z0-9_]{20,}"#,
        #"glpat-[A-Za-z0-9_-]{20,}"#,
        #"sk-[A-Za-z0-9_-]{20,}"#,
        #"Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{20,}"#,
      ]
      if secretPatterns.contains(where: { pattern in
        text.range(of: pattern, options: .regularExpression) != nil
      }) {
        findings.append("\(filename): token-like secret")
      }
  
      return findings
    }

  private func relativePath(_ url: URL, from root: URL) -> String {
    let rootPath = root.path
    let path = url.path
    if path == rootPath || path.hasPrefix(rootPath + "/") {
      return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    let normalizedRootPath = root.standardizedFileURL.path
    let normalizedPath = url.standardizedFileURL.path
    guard normalizedPath == normalizedRootPath
      || normalizedPath.hasPrefix(normalizedRootPath + "/") else {
      return normalizedPath
    }
    return String(normalizedPath.dropFirst(normalizedRootPath.count))
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }
}
