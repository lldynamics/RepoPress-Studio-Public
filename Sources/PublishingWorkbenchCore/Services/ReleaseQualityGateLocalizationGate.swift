import Foundation

struct ReleaseQualityGateLocalizationGate {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func items(root: URL, files: [URL]) -> [ReleaseQualityGateItem] {
    [
      localizationCatalogItem(root: root, files: files),
      localizationLanguageItem(root: root, files: files),
      localizationAutomationItem(root: root, files: files),
    ]
  }
    private func localizationCatalogItem(root: URL, files: [URL]) -> ReleaseQualityGateItem {
      let localizedFiles = files.filter { file in
        file.lastPathComponent == "Localizable.strings"
          || file.lastPathComponent == "InfoPlist.strings"
          || file.pathExtension == "xcstrings"
      }
      if localizedFiles.isEmpty {
        return ReleaseQualityGateItem(
          id: "localization-catalog",
          category: .localization,
          title: "本地化资源",
          status: .blocked,
          message: "未找到 Localizable.strings、InfoPlist.strings 或 .xcstrings，当前界面文案和 App 显示名无法做中英门禁。",
          evidence: "Sources/**/Resources"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "localization-catalog",
        category: .localization,
        title: "本地化资源",
        status: .passed,
        message: "已发现可检查的本地化资源。",
        evidence: localizedFiles.map { relativePath($0, from: root) }.sorted().joined(separator: ", ")
      )
    }
  
    private func localizationLanguageItem(root: URL, files: [URL]) -> ReleaseQualityGateItem {
      let packageURL = root.appendingPathComponent("Package.swift")
      let packageText = (try? String(contentsOf: packageURL, encoding: .utf8)) ?? ""
      let hasDefaultLocalization = packageText.contains("defaultLocalization")
      let languageCodes = Set(
        files.compactMap { file in
          file.pathComponents.first { $0.hasSuffix(".lproj") }?.replacingOccurrences(of: ".lproj", with: "")
        }
      )
      let hasChinese = languageCodes.contains { $0.hasPrefix("zh") }
      let hasEnglish = languageCodes.contains("en")
  
      if hasChinese && hasEnglish {
        return ReleaseQualityGateItem(
          id: "localization-languages",
          category: .localization,
          title: "中英语言覆盖",
          status: .passed,
          message: "已发现中文和英文本地化目录。",
          evidence: languageCodes.sorted().joined(separator: ", ")
        )
      }
  
      if hasDefaultLocalization {
        return ReleaseQualityGateItem(
          id: "localization-languages",
          category: .localization,
          title: "中英语言覆盖",
          status: .warning,
          message: "Package 已声明默认语言，但未发现中文/英文双语资源目录。",
          evidence: "Package.swift defaultLocalization"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "localization-languages",
        category: .localization,
        title: "中英语言覆盖",
        status: .blocked,
        message: "未发现默认语言声明或中英本地化目录。",
        evidence: nil
      )
    }
  
    private func localizationAutomationItem(root: URL, files: [URL]) -> ReleaseQualityGateItem {
      let candidates = [
        "script/check_localization_gate.sh",
        "script/check_release_gate.sh"
      ]
      if let found = candidates.first(where: { fileManager.fileExists(atPath: root.appendingPathComponent($0).path) }) {
        let scriptText = (try? String(contentsOf: root.appendingPathComponent(found), encoding: .utf8)) ?? ""
        let missingChecks = localizationAutomationMissingChecks(in: scriptText)
        guard missingChecks.isEmpty else {
          return ReleaseQualityGateItem(
            id: "localization-automation",
            category: .localization,
            title: "本地化自动门禁",
            status: .blocked,
            message: "本地化检查脚本缺少 \(missingChecks.joined(separator: "、")) 校验。",
            evidence: found
          )
        }
  
        return ReleaseQualityGateItem(
          id: "localization-automation",
          category: .localization,
          title: "本地化自动门禁",
          status: .passed,
          message: "已提供可复现的本地化检查脚本，覆盖默认语言、strings 语法、中英 key 一致性和 App 显示名。",
          evidence: found
        )
      }
  
      let evidenceFiles = files.filter { file in
        let name = file.lastPathComponent.lowercased()
        return name.contains("localization") || name.contains("localizable")
      }
      return ReleaseQualityGateItem(
        id: "localization-automation",
        category: .localization,
        title: "本地化自动门禁",
        status: .blocked,
        message: "缺少 script/check_localization_gate.sh 或总 release gate，无法稳定验证默认语言、双语资源、InfoPlist 显示名和 strings 语法。",
        evidence: evidenceFiles.map { relativePath($0, from: root) }.sorted().joined(separator: ", ").nilIfEmpty
      )
    }
  
    private func localizationAutomationMissingChecks(in scriptText: String) -> [String] {
      var missing: [String] = []
      if !scriptText.contains("defaultLocalization") {
        missing.append("默认语言")
      }
      if !scriptText.contains("plutil -lint") {
        missing.append("strings 语法")
      }
      if !scriptText.contains("comm -23") || !scriptText.contains("comm -13") {
        missing.append("中英 key 一致性")
      }
      if !scriptText.contains("uniq -d") {
        missing.append("重复 key")
      }
      if !scriptText.contains("InfoPlist.strings") || !scriptText.contains("CFBundleDisplayName") {
        missing.append("App 显示名")
      }
      if !scriptText.contains("Localizable.xcstrings") || !scriptText.contains("raw_ui_literal_count") {
        missing.append("源码 key / xcstrings 覆盖")
      }
      return missing
    }

  private func relativePath(_ url: URL, from root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath) else {
      return path
    }
    return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }
}
