#if DEBUG || SCREENSHOT_CAPTURE_BUILD
  import Foundation

  extension ScreenshotDemoDataService {
    /// Foundation ignores a launch TMPDIR override, so without an explicit
    /// persistence root every UI-test run shares one system-temp fixture. A
    /// copy damaged by an interrupted run must not keep each later launch in
    /// persistence recovery; the caller reseeds the fixture anyway.
    static func loadFixture(
      _ persistence: WorkbenchPersistence, discardingUnreadable: Bool
    ) throws {
      do {
        _ = try persistence.loadWithRecovery()
      } catch  where discardingUnreadable {
        for url in [
          persistence.fileURL, persistence.lastKnownGoodURL, persistence.recordStoreDirectoryURL,
        ] where FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.removeItem(at: url)
        }
        _ = try persistence.loadWithRecovery()
      }
    }

    @MainActor
    static func prepareRepositoryFixture(in store: WorkbenchStore, isUITest: Bool) {
      let configuredPath =
        isUITest
        ? ProcessInfo.processInfo.environment[uiTestRepositoryRootEnvironmentKey]?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        : nil
      let rootURL =
        configuredPath.flatMap { path in
          path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        }
        ?? (isUITest
          ? FileManager.default.temporaryDirectory
            .appendingPathComponent(
              "PersonalSitePublisherMac-AccessibilityUITestRepository", isDirectory: true)
          : defaultRepositoryRootURL)

      do {
        // A local fixture satisfies the same repository and source-preservation
        // contracts as an imported article. Existing files remain untouched.
        for directory in [".git", "static/images"] {
          try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try writeFixtureFileIfMissing(
          at: rootURL.appendingPathComponent("config.toml"),
          contents: "base_url = \"https://demo.example.com\"\ntitle = \"截图演示站点\"\n"
        )
        for draft in store.drafts
        where draft.siteProfileID == store.activeProfileID
          && draft.repositoryPath != nil
        {
          let destination = rootURL.appendingPathComponent(
            store.activeProfile.markdownPath(for: draft))
          try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
          try writeFixtureFileIfMissing(
            at: destination,
            contents: FrontMatterRenderer().renderDocument(
              draft: draft, profile: store.activeProfile))
        }
      } catch {
        store.setPublishActionMessage(String(localized: "无法准备运行时辅助功能测试仓库。"), status: .failure)
        return
      }

      var profile = store.activeProfile
      profile.localRepositoryRootPath = rootURL.standardizedFileURL.path
      // The publish acceptance test owns only a local bare Git remote. It
      // explicitly disables the demo's public deployment endpoints.
      if isUITest,
        ProcessInfo.processInfo.environment["PERSONAL_SITE_PUBLISHER_UI_TEST_NO_DEPLOYMENT"] == "1"
      {
        profile.deploymentProvider = .custom
        profile.deploymentSiteURL = nil
        profile.deploymentStatusEndpointURL = nil
        profile.deploymentStatusEndpointUsesToken = false
      }
      store.updateActiveProfile(profile)
    }

    private static func writeFixtureFileIfMissing(at url: URL, contents: String) throws {
      guard !FileManager.default.fileExists(atPath: url.path) else { return }
      try Data(contents.utf8).write(to: url, options: .atomic)
    }

  }
#endif
