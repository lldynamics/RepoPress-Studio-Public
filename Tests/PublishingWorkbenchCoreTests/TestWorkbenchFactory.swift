import Foundation
@testable import PublishingWorkbenchCore

enum TestWorkbenchFactory {
  static func temporaryDirectoryURL(prefix: String = "PersonalSitePublisherMacTests") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func temporaryPersistenceURL(prefix: String = "PersonalSitePublisherMacTests") throws -> URL {
    try temporaryDirectoryURL(prefix: prefix).appendingPathComponent("workbench.json")
  }

  static func persistence(
    fileURL: URL? = nil,
    prefix: String = "PersonalSitePublisherMacTests"
  ) throws -> WorkbenchPersistence {
    if let fileURL {
      return WorkbenchPersistence(fileURL: fileURL)
    }
    return WorkbenchPersistence(fileURL: try temporaryPersistenceURL(prefix: prefix))
  }

  @MainActor
  static func makeStore(
    fileURL: URL? = nil,
    prefix: String = "PersonalSitePublisherMacTests"
  ) throws -> WorkbenchStore {
    WorkbenchStore(persistence: try persistence(fileURL: fileURL, prefix: prefix))
  }
}

func temporaryDirectoryURL(prefix: String = "PersonalSitePublisherMacTests") throws -> URL {
  try TestWorkbenchFactory.temporaryDirectoryURL(prefix: prefix)
}

func temporaryPersistenceURL(prefix: String = "PersonalSitePublisherMacTests") throws -> URL {
  try TestWorkbenchFactory.temporaryPersistenceURL(prefix: prefix)
}
