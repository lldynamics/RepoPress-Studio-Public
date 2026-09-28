import SwiftUI

struct PublishDrawerCommandAction: Sendable {
  let currentArticleID: UUID?
  private let prepareCurrentArticle: (@MainActor @Sendable () -> Void)?
  let open: @MainActor @Sendable (_ message: String?) -> Void

  init(
    currentArticleID: UUID? = nil,
    prepareCurrentArticle: (@MainActor @Sendable () -> Void)? = nil,
    open: @escaping @MainActor @Sendable (_ message: String?) -> Void
  ) {
    self.currentArticleID = currentArticleID
    self.prepareCurrentArticle = prepareCurrentArticle
    self.open = open
  }

  var canPrepareCurrentArticle: Bool {
    currentArticleID != nil && prepareCurrentArticle != nil
  }

  @MainActor
  func openCurrentArticle() {
    guard canPrepareCurrentArticle else { return }
    prepareCurrentArticle?()
  }
}

private struct PublishDrawerCommandActionKey: FocusedValueKey {
  typealias Value = PublishDrawerCommandAction
}

private struct PublishDrawerCommandActionEnvironmentKey: EnvironmentKey {
  static let defaultValue: PublishDrawerCommandAction? = nil
}

extension FocusedValues {
  var publishDrawerCommandAction: PublishDrawerCommandAction? {
    get { self[PublishDrawerCommandActionKey.self] }
    set { self[PublishDrawerCommandActionKey.self] = newValue }
  }
}

extension EnvironmentValues {
  var publishDrawerCommandAction: PublishDrawerCommandAction? {
    get { self[PublishDrawerCommandActionEnvironmentKey.self] }
    set { self[PublishDrawerCommandActionEnvironmentKey.self] = newValue }
  }
}
