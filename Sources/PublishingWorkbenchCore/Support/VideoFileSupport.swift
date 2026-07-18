import Foundation

public enum DraftAttachmentMediaKind: String, Sendable {
  case image
  case video
}

public enum VideoFileSupport {
  public static let supportedExtensions: Set<String> = [
    "m4v",
    "mov",
    "mp4",
    "ogg",
    "ogv",
    "webm",
  ]

  public static func isSupportedVideoPath(_ path: String) -> Bool {
    supportedExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
  }

  public static func isSupportedVideoURL(_ url: URL) -> Bool {
    isSupportedVideoPath(url.path)
  }

  public static func supportedVideoURLs(in urls: [URL]) -> [URL] {
    urls.filter(isSupportedVideoURL)
  }

  public static func accessibleTitle(for url: URL) -> String {
    let title = url
      .deletingPathExtension()
      .lastPathComponent
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    return title.nilIfEmpty ?? "视频"
  }

  public static func mimeType(for path: String) -> String {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "mov":
      return "video/quicktime"
    case "m4v":
      return "video/x-m4v"
    case "webm":
      return "video/webm"
    case "ogg", "ogv":
      return "video/ogg"
    default:
      return "video/mp4"
    }
  }

  public static func htmlEmbed(
    publicPath: String,
    accessibleTitle: String
  ) -> String {
    let normalizedTitle = accessibleTitle
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .nilIfEmpty
      ?? "视频"
    let escapedPath = escapedHTMLAttribute(publicPath)
    let escapedTitle = escapedHTMLAttribute(normalizedTitle)
    let escapedMIMEType = escapedHTMLAttribute(mimeType(for: publicPath))
    return """
    <video controls preload="metadata" playsinline aria-label="\(escapedTitle)" style="max-width: 100%; height: auto;">
      <source src="\(escapedPath)" type="\(escapedMIMEType)">
      您的浏览器不支持视频播放。<a href="\(escapedPath)">下载视频</a>
    </video>
    """
  }

  private static func escapedHTMLAttribute(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}

public extension DraftAttachment {
  var mediaKind: DraftAttachmentMediaKind {
    if VideoFileSupport.isSupportedVideoPath(originalFilename)
      || VideoFileSupport.isSupportedVideoPath(repositoryPath)
      || sourceFilePath.map(VideoFileSupport.isSupportedVideoPath) == true {
      return .video
    }
    return .image
  }
}
