import CoreGraphics
import Foundation
import ImageIO

private enum QualityError: LocalizedError {
  case invalidArguments
  case unreadableImage(String)

  var errorDescription: String? {
    switch self {
    case .invalidArguments: "usage: app-store-marketing-quality <image-or-directory>"
    case .unreadableImage(let path): "could not decode image: \(path)"
    }
  }
}

private struct ImageQuality {
  let blackRatio: Double
  let placeholderColorRatio: Double

  var isAcceptable: Bool {
    blackRatio < 0.18 && placeholderColorRatio < 0.04
  }
}

private func inspectImage(at url: URL) throws -> ImageQuality {
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else {
    throw QualityError.unreadableImage(url.path)
  }

  let width = 320
  let height = 200
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else {
    throw QualityError.unreadableImage(url.path)
  }
  context.interpolationQuality = .medium
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

  var blackPixels = 0
  var placeholderPixels = 0
  let pixelCount = width * height
  for index in 0..<pixelCount {
    let offset = index * 4
    let red = Int(pixels[offset])
    let green = Int(pixels[offset + 1])
    let blue = Int(pixels[offset + 2])
    if red < 10 && green < 10 && blue < 10 {
      blackPixels += 1
    }
    if red > 210 && green >= 45 && green < 190 && blue >= 45 && blue < 190 {
      placeholderPixels += 1
    }
  }
  return ImageQuality(
    blackRatio: Double(blackPixels) / Double(pixelCount),
    placeholderColorRatio: Double(placeholderPixels) / Double(pixelCount)
  )
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard arguments.count == 1 else { throw QualityError.invalidArguments }
  let inputURL = URL(fileURLWithPath: arguments[0])
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) else {
    throw QualityError.unreadableImage(inputURL.path)
  }

  let imageURLs: [URL]
  if isDirectory.boolValue {
    imageURLs = try FileManager.default.contentsOfDirectory(
      at: inputURL,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  } else {
    imageURLs = [inputURL]
  }

  var failures: [String] = []
  for url in imageURLs {
    let quality = try inspectImage(at: url)
    print(
      String(
        format: "%@: black=%.3f placeholder=%.3f",
        url.lastPathComponent,
        quality.blackRatio,
        quality.placeholderColorRatio
      )
    )
    if !quality.isAcceptable {
      failures.append(url.lastPathComponent)
    }
  }
  if !failures.isEmpty {
    FileHandle.standardError.write(
      Data("marketing screenshot quality failed: \(failures.joined(separator: ", "))\n".utf8)
    )
    exit(1)
  }
} catch {
  FileHandle.standardError.write(Data("marketing screenshot quality failed: \(error.localizedDescription)\n".utf8))
  exit(1)
}
