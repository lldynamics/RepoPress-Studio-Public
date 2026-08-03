import Foundation

/// File types that the asset manager is allowed to inspect inside a site's
/// configured asset root. The list intentionally stays bounded so a source
/// repository's build artefacts and arbitrary binaries are never treated as
/// publishable media by accident.
public enum AssetResourceFileSupport {
  public static let supportedExtensions: Set<String> =
    ImageFileSupport.supportedExtensions
    .union(VideoFileSupport.supportedExtensions)
    .union([
      "aac", "aiff", "flac", "m4a", "mp3", "wav",
      "csv", "doc", "docx", "epub", "json", "numbers", "pages",
      "pdf", "ppt", "pptx", "rtf", "txt", "xls", "xlsx", "zip",
    ])

  public static let compressibleImageExtensions: Set<String> = [
    "heic", "jpeg", "jpg", "png", "tiff",
  ]

  public static let markdownExtensions: Set<String> = [
    "astro", "markdown", "md", "mdown", "mdx", "mkd", "mkdn",
  ]

  public static func isSupportedPath(_ path: String) -> Bool {
    supportedExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
  }

  public static func kind(for path: String) -> AssetResourceKind? {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    if ImageFileSupport.supportedExtensions.contains(ext) { return .image }
    if VideoFileSupport.supportedExtensions.contains(ext) { return .video }
    if ["aac", "aiff", "flac", "m4a", "mp3", "wav"].contains(ext) { return .audio }
    if ["csv", "doc", "docx", "epub", "json", "numbers", "pages", "pdf", "ppt", "pptx", "rtf", "txt", "xls", "xlsx", "zip"].contains(ext) {
      return .document
    }
    return nil
  }
}
