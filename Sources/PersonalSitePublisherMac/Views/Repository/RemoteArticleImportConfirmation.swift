import Foundation
import PublishingGitCore
import PublishingWorkbenchCore

struct RemoteArticleImportConfirmation: Identifiable {
  var id: UUID { target.id }
  let target: SiteOperationConfirmationTarget
  let files: [RepositoryChangedFile]

  init(profile: SiteProfile, files: [RepositoryChangedFile]) {
    target = SiteOperationConfirmationTarget(profile: profile)
    self.files = files.filter { $0.kind != .deleted }
  }
}
