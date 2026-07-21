import Foundation
#if canImport(Darwin)
import Darwin
#endif

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
      return "文件读取上限必须大于 0。"
    case let .unsafeRelativePath(path):
      return "文件路径不安全：\(path)"
    case let .cannotOpen(path, code):
      return "无法安全打开文件：\(path)（错误 \(code)）"
    case let .cannotInspect(path, code):
      return "无法检查文件：\(path)（错误 \(code)）"
    case let .notRegularFile(path):
      return "只允许读取普通文件：\(path)"
    case let .exceedsByteLimit(path, limit):
      return "文件超过允许的 \(limit) 字节：\(path)"
    case let .cannotRead(path, code):
      return "读取文件失败：\(path)（错误 \(code)）"
    case let .invalidUTF8(path):
      return "文件不是有效的 UTF-8 文本：\(path)"
    }
  }
}

public enum BoundedFileReader {
  public static func data(at url: URL, maximumByteCount: Int) throws -> Data {
    guard maximumByteCount > 0 else {
      throw BoundedFileReadError.invalidByteLimit
    }
#if canImport(Darwin)
    let path = url.path
    let descriptor = path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard descriptor >= 0 else {
      throw BoundedFileReadError.cannotOpen(path, errno)
    }
    defer { Darwin.close(descriptor) }
    return try readData(
      descriptor: descriptor,
      displayPath: path,
      maximumByteCount: maximumByteCount
    )
#else
    let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard resourceValues.isRegularFile == true else {
      throw BoundedFileReadError.notRegularFile(url.path)
    }
    if let fileSize = resourceValues.fileSize, fileSize > maximumByteCount {
      throw BoundedFileReadError.exceedsByteLimit(url.path, maximumByteCount)
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count <= maximumByteCount else {
      throw BoundedFileReadError.exceedsByteLimit(url.path, maximumByteCount)
    }
    return data
#endif
  }

  public static func data(
    relativePath: String,
    under rootURL: URL,
    maximumByteCount: Int
  ) throws -> Data {
    guard maximumByteCount > 0 else {
      throw BoundedFileReadError.invalidByteLimit
    }
    let components = try safeComponents(relativePath)
#if canImport(Darwin)
    let rootPath = rootURL.path
    var directoryDescriptor = rootPath.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else {
      throw BoundedFileReadError.cannotOpen(rootPath, errno)
    }
    defer { Darwin.close(directoryDescriptor) }

    for component in components.dropLast() {
      let nextDescriptor = component.withCString {
        Darwin.openat(
          directoryDescriptor,
          $0,
          O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
      }
      guard nextDescriptor >= 0 else {
        throw BoundedFileReadError.cannotOpen(relativePath, errno)
      }
      Darwin.close(directoryDescriptor)
      directoryDescriptor = nextDescriptor
    }

    let filename = components[components.count - 1]
    let descriptor = filename.withCString {
      Darwin.openat(
        directoryDescriptor,
        $0,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
      )
    }
    guard descriptor >= 0 else {
      throw BoundedFileReadError.cannotOpen(relativePath, errno)
    }
    defer { Darwin.close(descriptor) }
    return try readData(
      descriptor: descriptor,
      displayPath: relativePath,
      maximumByteCount: maximumByteCount
    )
#else
    return try data(
      at: components.reduce(rootURL) { $0.appendingPathComponent($1) },
      maximumByteCount: maximumByteCount
    )
#endif
  }

  public static func utf8String(at url: URL, maximumByteCount: Int) throws -> String {
    let data = try data(at: url, maximumByteCount: maximumByteCount)
    guard let string = String(data: data, encoding: .utf8) else {
      throw BoundedFileReadError.invalidUTF8(url.path)
    }
    return string
  }

  public static func utf8String(
    relativePath: String,
    under rootURL: URL,
    maximumByteCount: Int
  ) throws -> String {
    let data = try data(
      relativePath: relativePath,
      under: rootURL,
      maximumByteCount: maximumByteCount
    )
    guard let string = String(data: data, encoding: .utf8) else {
      throw BoundedFileReadError.invalidUTF8(relativePath)
    }
    return string
  }
}

private extension BoundedFileReader {
  static func safeComponents(_ relativePath: String) throws -> [String] {
    guard !relativePath.isEmpty,
          !relativePath.hasPrefix("/"),
          !relativePath.contains("\0") else {
      throw BoundedFileReadError.unsafeRelativePath(relativePath)
    }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !components.isEmpty,
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw BoundedFileReadError.unsafeRelativePath(relativePath)
    }
    return components
  }

#if canImport(Darwin)
  static func readData(
    descriptor: Int32,
    displayPath: String,
    maximumByteCount: Int
  ) throws -> Data {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else {
      throw BoundedFileReadError.cannotInspect(displayPath, errno)
    }
    guard (metadata.st_mode & S_IFMT) == S_IFREG else {
      throw BoundedFileReadError.notRegularFile(displayPath)
    }
    guard metadata.st_size >= 0,
          metadata.st_size <= off_t(maximumByteCount) else {
      throw BoundedFileReadError.exceedsByteLimit(displayPath, maximumByteCount)
    }

    var result = Data()
    result.reserveCapacity(Int(metadata.st_size))
    var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maximumByteCount + 1))
    while true {
      let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
        Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
      }
      if bytesRead == 0 {
        break
      }
      if bytesRead < 0 {
        if errno == EINTR { continue }
        throw BoundedFileReadError.cannotRead(displayPath, errno)
      }
      guard result.count + bytesRead <= maximumByteCount else {
        throw BoundedFileReadError.exceedsByteLimit(displayPath, maximumByteCount)
      }
      result.append(contentsOf: buffer.prefix(bytesRead))
    }
    return result
  }
#endif
}
