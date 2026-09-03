import Foundation

public enum BoundedFileReadError: Error, Equatable, LocalizedError, Sendable {
  case invalidByteLimit
  case unsafeRelativePath(String)
  case cannotOpen(String, Int32)
  case cannotInspect(String, Int32)
  case notRegularFile(String)
  case exceedsByteLimit(String, Int)
  case cannotRead(String, Int32)
  case invalidUTF8(String)

  public var errorDescription: String? {
    switch self {
    case .invalidByteLimit:
      return CoreL10n.text("文件读取上限必须大于 0。")
    case .unsafeRelativePath(let path):
      return CoreL10n.format("文件路径不安全：%@", path)
    case .cannotOpen(let path, let code):
      return CoreL10n.format("无法安全打开文件：%@（错误 %d）", path, code)
    case .cannotInspect(let path, let code):
      return CoreL10n.format("无法检查文件：%@（错误 %d）", path, code)
    case .notRegularFile(let path):
      return CoreL10n.format("只允许读取普通文件：%@", path)
    case .exceedsByteLimit(let path, let limit):
      return CoreL10n.format("文件超过允许的 %d 字节：%@", limit, path)
    case .cannotRead(let path, let code):
      return CoreL10n.format("读取文件失败：%@（错误 %d）", path, code)
    case .invalidUTF8(let path):
      return CoreL10n.format("文件不是有效的 UTF-8 文本：%@", path)
    }
  }

  fileprivate init(_ error: SafeFileReadError) {
    switch error {
    case .invalidByteLimit:
      self = .invalidByteLimit
    case .unsafeRelativePath(let path):
      self = .unsafeRelativePath(path)
    case .cannotOpen(let path, let code):
      self = .cannotOpen(path, code)
    case .cannotInspect(let path, let code):
      self = .cannotInspect(path, code)
    case .notRegularFile(let path):
      self = .notRegularFile(path)
    case .exceedsByteLimit(let path, let limit):
      self = .exceedsByteLimit(path, limit)
    case .cannotRead(let path, let code):
      self = .cannotRead(path, code)
    case .invalidUTF8(let path):
      self = .invalidUTF8(path)
    }
  }
}

/// Localized compatibility facade over the domain-neutral support reader.
public enum BoundedFileReader {
  public static func data(at url: URL, maximumByteCount: Int) throws -> Data {
    try translated {
      try SafeFileReader.data(at: url, maximumByteCount: maximumByteCount)
    }
  }

  public static func data(
    relativePath: String,
    under rootURL: URL,
    maximumByteCount: Int
  ) throws -> Data {
    try translated {
      try SafeFileReader.data(
        relativePath: relativePath,
        under: rootURL,
        maximumByteCount: maximumByteCount
      )
    }
  }

  public static func utf8String(at url: URL, maximumByteCount: Int) throws -> String {
    try translated {
      try SafeFileReader.utf8String(at: url, maximumByteCount: maximumByteCount)
    }
  }

  public static func utf8String(
    relativePath: String,
    under rootURL: URL,
    maximumByteCount: Int
  ) throws -> String {
    try translated {
      try SafeFileReader.utf8String(
        relativePath: relativePath,
        under: rootURL,
        maximumByteCount: maximumByteCount
      )
    }
  }

  public static func sha256(at url: URL, maximumByteCount: Int) throws -> Data {
    try translated {
      try SafeFileReader.sha256(at: url, maximumByteCount: maximumByteCount)
    }
  }

  private static func translated<Value>(_ operation: () throws -> Value) throws -> Value {
    do {
      return try operation()
    } catch let error as SafeFileReadError {
      throw BoundedFileReadError(error)
    }
  }
}
