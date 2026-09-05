import Foundation

/// The immutable article and file content a person reviewed before confirming
/// a batch. Paths alone cannot detect an edit to an existing Markdown file.
public struct BatchPublishReviewExpectation: Equatable, Sendable {
  public let draftIDs: [UUID]
  public let files: [PublishPackageFile]

  public init(plan: BatchPublishPlan, package: PublishPackage) {
    draftIDs = plan.remotePublishableItems.map(\.draftID)
    files = package.files
  }

  public func matches(plan: BatchPublishPlan, package: PublishPackage) -> Bool {
    draftIDs == plan.remotePublishableItems.map(\.draftID) && files == package.files
  }
}
