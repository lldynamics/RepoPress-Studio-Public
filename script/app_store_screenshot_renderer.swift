import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum RenderError: LocalizedError {
  case invalidArguments(String)
  case unreadableImage(String)
  case bitmapCreationFailed
  case encodingFailed

  var errorDescription: String? {
    switch self {
    case .invalidArguments(let message): message
    case .unreadableImage(let path): "无法读取截图：\(path)"
    case .bitmapCreationFailed: "无法创建无透明通道的 RGB 画布"
    case .encodingFailed: "无法编码 PNG"
    }
  }
}

private struct RGBColor {
  let red: CGFloat
  let green: CGFloat
  let blue: CGFloat

  var nsColor: NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
  }

  init(hex: String) throws {
    let normalized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard normalized.count == 6, let value = Int(normalized, radix: 16) else {
      throw RenderError.invalidArguments("颜色必须是 6 位十六进制值：\(hex)")
    }
    red = CGFloat((value >> 16) & 0xff) / 255
    green = CGFloat((value >> 8) & 0xff) / 255
    blue = CGFloat(value & 0xff) / 255
  }
}

private struct Renderer {
  static let marketingWidth = 2880
  static let marketingHeight = 1800

  static func renderNormalized(
    inputPath: String,
    outputPath: String,
    width: Int,
    height: Int,
    background: RGBColor
  ) throws {
    let image = try loadImage(at: inputPath)
    try renderRGBBitmap(width: width, height: height, outputPath: outputPath) { canvas in
      background.nsColor.setFill()
      canvas.fill()

      let destination = aspectFit(
        sourceSize: image.size,
        inside: canvas
      )
      draw(image, in: destination)
    }
  }

  static func renderMarketing(
    inputPath: String,
    outputPath: String,
    title: String,
    subtitle: String
  ) throws {
    let image = try loadImage(at: inputPath)
    try renderRGBBitmap(
      width: marketingWidth,
      height: marketingHeight,
      outputPath: outputPath
    ) { canvas in
      let backgroundGradient = NSGradient(
        starting: try! RGBColor(hex: "F8F5ED").nsColor,
        ending: try! RGBColor(hex: "E2EEE8").nsColor
      )!
      backgroundGradient.draw(in: canvas, angle: -18)

      drawMarketingCopy(title: title, subtitle: subtitle, canvas: canvas)

      let availableScreenshotArea = NSRect(x: 150, y: 72, width: 2580, height: 1375)
      let screenshotRect = aspectFit(sourceSize: image.size, inside: availableScreenshotArea)
      drawScreenshotCard(image, in: screenshotRect)
    }
  }

  private static func loadImage(at path: String) throws -> NSImage {
    guard let image = NSImage(contentsOfFile: path), image.isValid else {
      throw RenderError.unreadableImage(path)
    }
    return image
  }

  private static func renderRGBBitmap(
    width: Int,
    height: Int,
    outputPath: String,
    drawing: (NSRect) -> Void
  ) throws {
    guard width > 0, height > 0 else {
      throw RenderError.invalidArguments("输出尺寸必须大于 0")
    }
    guard let bitmapContext = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
      throw RenderError.bitmapCreationFailed
    }
    let context = NSGraphicsContext(cgContext: bitmapContext, flipped: false)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    drawing(NSRect(x: 0, y: 0, width: width, height: height))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let image = bitmapContext.makeImage() else {
      throw RenderError.encodingFailed
    }
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    guard let destination = CGImageDestinationCreateWithURL(
      outputURL as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else {
      throw RenderError.encodingFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw RenderError.encodingFailed
    }
  }

  private static func aspectFit(sourceSize: NSSize, inside target: NSRect) -> NSRect {
    guard sourceSize.width > 0, sourceSize.height > 0 else { return target }
    let scale = min(target.width / sourceSize.width, target.height / sourceSize.height)
    let size = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    return NSRect(
      x: target.midX - size.width / 2,
      y: target.midY - size.height / 2,
      width: size.width,
      height: size.height
    ).integral
  }

  private static func draw(
    _ image: NSImage,
    in rect: NSRect,
    operation: NSCompositingOperation = .copy
  ) {
    image.draw(
      in: rect,
      from: NSRect(origin: .zero, size: image.size),
      operation: operation,
      fraction: 1,
      respectFlipped: false,
      hints: [.interpolation: NSImageInterpolation.high]
    )
  }

  private static func drawMarketingCopy(title: String, subtitle: String, canvas: NSRect) {
    let titleStyle = NSMutableParagraphStyle()
    titleStyle.alignment = .center
    titleStyle.lineBreakMode = .byTruncatingTail
    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 86, weight: .bold),
      .foregroundColor: try! RGBColor(hex: "183B2E").nsColor,
      .paragraphStyle: titleStyle,
      .kern: -1.2,
    ]
    (title as NSString).draw(
      in: NSRect(x: 180, y: canvas.height - 160, width: canvas.width - 360, height: 108),
      withAttributes: titleAttributes
    )

    guard !subtitle.isEmpty else { return }
    let subtitleStyle = NSMutableParagraphStyle()
    subtitleStyle.alignment = .center
    subtitleStyle.lineBreakMode = .byTruncatingTail
    let subtitleAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 38, weight: .medium),
      .foregroundColor: try! RGBColor(hex: "4D675D").nsColor,
      .paragraphStyle: subtitleStyle,
    ]
    (subtitle as NSString).draw(
      in: NSRect(x: 240, y: canvas.height - 228, width: canvas.width - 480, height: 54),
      withAttributes: subtitleAttributes
    )
  }

  private static func drawScreenshotCard(_ image: NSImage, in rect: NSRect) {
    let cornerRadius: CGFloat = 30
    let cardPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 44
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()
    NSColor.white.setFill()
    cardPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    cardPath.addClip()
    draw(image, in: rect, operation: .sourceOver)
    NSGraphicsContext.restoreGraphicsState()

    try! RGBColor(hex: "B8C9C0").nsColor.withAlphaComponent(0.8).setStroke()
    cardPath.lineWidth = 2
    cardPath.stroke()
  }
}

private func printUsage() {
  FileHandle.standardError.write(
    Data(
      """
      用法：
        app_store_screenshot_renderer normalize <输入> <输出> <宽> <高> <背景色>
        app_store_screenshot_renderer marketing <输入> <输出> <标题> <副标题>
      """.utf8
    )
  )
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard let command = arguments.first else {
    printUsage()
    throw RenderError.invalidArguments("缺少渲染命令")
  }

  switch command {
  case "normalize":
    guard arguments.count == 6,
          let width = Int(arguments[3]),
          let height = Int(arguments[4])
    else {
      printUsage()
      throw RenderError.invalidArguments("normalize 参数不完整")
    }
    try Renderer.renderNormalized(
      inputPath: arguments[1],
      outputPath: arguments[2],
      width: width,
      height: height,
      background: RGBColor(hex: arguments[5])
    )
  case "marketing":
    guard arguments.count == 5 else {
      printUsage()
      throw RenderError.invalidArguments("marketing 参数不完整")
    }
    try Renderer.renderMarketing(
      inputPath: arguments[1],
      outputPath: arguments[2],
      title: arguments[3],
      subtitle: arguments[4]
    )
  default:
    printUsage()
    throw RenderError.invalidArguments("未知渲染命令：\(command)")
  }
} catch {
  FileHandle.standardError.write(Data("截图渲染失败：\(error.localizedDescription)\n".utf8))
  exit(1)
}
