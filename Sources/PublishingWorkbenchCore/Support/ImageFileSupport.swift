import Foundation

public enum ImageFileSupport {
  public static let supportedExtensions: Set<String> = [
    "avif",
    "gif",
    "heic",
    "jpeg",
    "jpg",
    "png",
    "svg",
    "tiff",
    "webp",
  ]

  public static func isSupportedImagePath(_ path: String) -> Bool {
    supportedExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
  }

  public static func isSupportedImageURL(_ url: URL) -> Bool {
    isSupportedImagePath(url.path)
  }
}
