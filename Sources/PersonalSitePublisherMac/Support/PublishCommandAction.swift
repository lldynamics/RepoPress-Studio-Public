import SwiftUI

/// The window's two publish actions, shared by the toolbar, the menu bar,
/// the publish checks panel and the site overview.
struct PublishCommandAction: Sendable {
  let currentArticleID: UUID?
  /// A preparation, commit or push of this window is still running.
  let isBusy: Bool
  private let publishArticle: (@MainActor @Sendable () -> Void)?
  private let publishEverything: @MainActor @Sendable () -> Void

  init(
    currentArticleID: UUID? = nil,
    isBusy: Bool = false,
    publishArticle: (@MainActor @Sendable () -> Void)? = nil,
    publishAll: @escaping @MainActor @Sendable () -> Void
  ) {
    self.currentArticleID = currentArticleID
    self.isBusy = isBusy
    self.publishArticle = publishArticle
    publishEverything = publishAll
  }

  var canPublishCurrentArticle: Bool {
    currentArticleID != nil && publishArticle != nil && !isBusy
  }

  var canPublishAll: Bool { !isBusy }

  @MainActor
  func publishCurrentArticle() {
    guard canPublishCurrentArticle else { return }
    publishArticle?()
  }

  @MainActor
  func publishAll() {
    guard canPublishAll else { return }
    publishEverything()
  }
}

private struct PublishCommandActionEnvironmentKey: EnvironmentKey {
  static let defaultValue: PublishCommandAction? = nil
}

extension EnvironmentValues {
  var publishCommandAction: PublishCommandAction? {
    get { self[PublishCommandActionEnvironmentKey.self] }
    set { self[PublishCommandActionEnvironmentKey.self] = newValue }
  }
}
