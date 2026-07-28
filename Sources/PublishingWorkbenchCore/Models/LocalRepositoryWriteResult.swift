import Foundation

public enum LocalRepositoryWriteResult: Equatable, Sendable {
  case succeeded(writtenPaths: [String], message: String)
  case writtenButRecordSaveFailed(writtenPaths: [String], message: String)
  case failed(message: String)

  public var writtenPaths: [String] {
    switch self {
    case .succeeded(let writtenPaths, _),
         .writtenButRecordSaveFailed(let writtenPaths, _):
      return writtenPaths
    case .failed:
      return []
    }
  }

  public var message: String {
    switch self {
    case .succeeded(_, let message),
         .writtenButRecordSaveFailed(_, let message),
         .failed(let message):
      return message
    }
  }
}
