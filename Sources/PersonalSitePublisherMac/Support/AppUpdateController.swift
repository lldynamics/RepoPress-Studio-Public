import Combine
import Foundation
import Sparkle
import SwiftUI

struct AppUpdateConfiguration: Equatable {
  let feedURL: URL?
  let publicEdKey: String
  let channel: String

  init(infoDictionary: [String: Any]) {
    if let rawFeedURL = infoDictionary["SUFeedURL"] as? String {
      feedURL = URL(string: rawFeedURL.trimmingCharacters(in: .whitespacesAndNewlines))
    } else {
      feedURL = nil
    }
    publicEdKey = (infoDictionary["SUPublicEDKey"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let requestedChannel = (infoDictionary["RepoPressUpdateChannel"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    channel = requestedChannel == "beta" ? "beta" : "stable"
  }

  init(bundle: Bundle = .main) {
    self.init(infoDictionary: bundle.infoDictionary ?? [:])
  }

  var isReady: Bool {
    feedURL?.scheme?.lowercased() == "https" && !publicEdKey.isEmpty
  }
}

@MainActor
private final class AppUpdateChannelDelegate: NSObject, SPUUpdaterDelegate {
  let channel: String

  init(channel: String) {
    self.channel = channel
  }

  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    channel == "beta" ? ["beta"] : []
  }
}

@MainActor
final class AppUpdateController: ObservableObject {
  @Published private(set) var canCheckForUpdates = false

  let configuration: AppUpdateConfiguration
  private let channelDelegate: AppUpdateChannelDelegate
  private let updaterController: SPUStandardUpdaterController

  init(configuration: AppUpdateConfiguration = AppUpdateConfiguration()) {
    self.configuration = configuration
    let channelDelegate = AppUpdateChannelDelegate(channel: configuration.channel)
    self.channelDelegate = channelDelegate
    updaterController = SPUStandardUpdaterController(
      startingUpdater: configuration.isReady,
      updaterDelegate: channelDelegate,
      userDriverDelegate: nil
    )

    if configuration.isReady {
      updaterController.updater.publisher(for: \.canCheckForUpdates)
        .receive(on: RunLoop.main)
        .assign(to: &$canCheckForUpdates)
    }
  }

  func checkForUpdates() {
    guard configuration.isReady else { return }
    updaterController.checkForUpdates(nil)
  }
}

struct AppUpdateCommands: Commands {
  @ObservedObject var controller: AppUpdateController

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button("检查更新…") {
        controller.checkForUpdates()
      }
      .disabled(!controller.canCheckForUpdates)
      .accessibilityHint(
        controller.configuration.isReady
          ? String(localized: "检查 RepoPress Studio 的新版本")
          : String(localized: "当前构建未配置安全更新源")
      )
    }
  }
}
