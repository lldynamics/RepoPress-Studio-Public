import AppKit
import CoreGraphics
import Foundation

public struct OpenGraphCoverGeneratorService: Sendable {
  public init() {}

  public struct StyleOptions: Hashable, Sendable {
    public var accentColorHex: String
    public var isDarkMode: Bool
    public var fontName: String

    public init(
      accentColorHex: String = "#0A84FF",
      isDarkMode: Bool = true,
      fontName: String = "SF Pro Display"
    ) {
      self.accentColorHex = accentColorHex
      self.isDarkMode = isDarkMode
      self.fontName = fontName
    }
  }

  @MainActor
  public func generateCoverPNGData(
    title: String,
    author: String?,
    category: String?,
    dateString: String?,
    siteName: String?,
    options: StyleOptions = StyleOptions()
  ) -> Data? {
    let width: CGFloat = 1200
    let height: CGFloat = 630

    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
      image.unlockFocus()
      return nil
    }

    let isDark = options.isDarkMode
    let bgColor = isDark
      ? NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)
      : NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1.0)
    let cardBgColor = isDark
      ? NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.20, alpha: 1.0)
      : NSColor.white
    let titleColor = isDark ? NSColor.white : NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
    let subtitleColor = isDark
      ? NSColor(calibratedRed: 0.7, green: 0.75, blue: 0.8, alpha: 1.0)
      : NSColor(calibratedRed: 0.4, green: 0.4, blue: 0.4, alpha: 1.0)

    let accentColor = NSColor(hexString: options.accentColorHex) ?? NSColor.systemBlue

    // Draw background gradient
    context.saveGState()
    bgColor.setFill()
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Accent glow/gradient circle in top right
    let gradientColors = [accentColor.withAlphaComponent(isDark ? 0.35 : 0.2).cgColor, accentColor.withAlphaComponent(0.0).cgColor] as CFArray
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 1.0]) {
      context.drawRadialGradient(
        gradient,
        startCenter: CGPoint(x: width * 0.85, y: height * 0.85),
        startRadius: 0,
        endCenter: CGPoint(x: width * 0.85, y: height * 0.85),
        endRadius: 400,
        options: .drawsAfterEndLocation
      )
    }

    // Draw Card Container
    let cardRect = CGRect(x: 60, y: 60, width: width - 120, height: height - 120)
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 24, yRadius: 24)
    cardBgColor.setFill()
    cardPath.fill()

    let strokeColor = isDark
      ? NSColor(calibratedWhite: 1.0, alpha: 0.1)
      : NSColor(calibratedWhite: 0.0, alpha: 0.08)
    strokeColor.setStroke()
    cardPath.lineWidth = 2
    cardPath.stroke()

    // Left accent bar
    let accentBarRect = CGRect(x: cardRect.minX + 32, y: cardRect.minY + 48, width: 8, height: cardRect.height - 96)
    let accentBarPath = NSBezierPath(roundedRect: accentBarRect, xRadius: 4, yRadius: 4)
    accentColor.setFill()
    accentBarPath.fill()

    // Text Insets
    let textX = cardRect.minX + 64
    let textWidth = cardRect.width - 100

    // 1. Site Name & Category Badge
    var badgeText = (siteName ?? "RepoPress Studio").uppercased()
    if let cat = category, !cat.isEmpty {
      badgeText += "  •  \(cat.uppercased())"
    }

    let badgeFont = NSFont.systemFont(ofSize: 22, weight: .bold)
    let badgeAttributes: [NSAttributedString.Key: Any] = [
      .font: badgeFont,
      .foregroundColor: accentColor
    ]
    let badgeString = NSAttributedString(string: badgeText, attributes: badgeAttributes)
    badgeString.draw(at: NSPoint(x: textX, y: cardRect.maxY - 100))

    // 2. Title Text
    let titleFont = NSFont.systemFont(ofSize: 52, weight: .bold)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = .byWordWrapping
    paragraphStyle.maximumLineHeight = 64
    paragraphStyle.lineSpacing = 6

    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: titleFont,
      .foregroundColor: titleColor,
      .paragraphStyle: paragraphStyle
    ]

    let titleRect = CGRect(x: textX, y: cardRect.minY + 120, width: textWidth, height: cardRect.height - 240)
    let titleAttrString = NSAttributedString(string: title, attributes: titleAttributes)
    titleAttrString.draw(in: titleRect)

    // 3. Footer: Author & Date
    var footerParts: [String] = []
    if let auth = author, !auth.isEmpty {
      footerParts.append("✍️ \(auth)")
    }
    if let dt = dateString, !dt.isEmpty {
      footerParts.append("📅 \(dt)")
    }
    let footerText = footerParts.joined(separator: "    ")

    if !footerText.isEmpty {
      let footerFont = NSFont.systemFont(ofSize: 24, weight: .medium)
      let footerAttributes: [NSAttributedString.Key: Any] = [
        .font: footerFont,
        .foregroundColor: subtitleColor
      ]
      let footerString = NSAttributedString(string: footerText, attributes: footerAttributes)
      footerString.draw(at: NSPoint(x: textX, y: cardRect.minY + 56))
    }

    context.restoreGState()
    image.unlockFocus()

    guard let tiffRepresentation = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
      return nil
    }

    return bitmap.representation(using: .png, properties: [:])
  }
}

private extension NSColor {
  convenience init?(hexString: String) {
    let hexSanitized = hexString.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
    var rgb: UInt64 = 0
    guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

    let red = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
    let green = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
    let blue = CGFloat(rgb & 0x0000FF) / 255.0

    self.init(calibratedRed: red, green: green, blue: blue, alpha: 1.0)
  }
}
