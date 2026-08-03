import Foundation

enum WorkspaceModalPresentation: String, CaseIterable, Identifiable {
  case publishDrawer
  case taskCenter
  case localSitePreview
  case firstRunSetup
  case commandPalette
  case draftFullTextSearch

  var id: String { rawValue }
}

struct WorkspaceModalPresentationState: Equatable {
  private(set) var presented: WorkspaceModalPresentation?

  mutating func present(_ presentation: WorkspaceModalPresentation) {
    presented = presentation
  }

  mutating func dismiss(_ presentation: WorkspaceModalPresentation? = nil) {
    guard presentation == nil || presented == presentation else { return }
    presented = nil
  }

  mutating func replace(with presentation: WorkspaceModalPresentation?) {
    presented = presentation
  }
}
