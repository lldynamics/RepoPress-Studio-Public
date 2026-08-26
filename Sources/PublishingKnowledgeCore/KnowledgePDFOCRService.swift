import AppKit
import Foundation
import PDFKit
import Vision

package struct KnowledgePDFOCRService: Sendable {
  package init() {}

  package func recognizeText(in page: PDFPage) throws -> String {
    try Task.checkCancellation()
    guard let image = try renderedImage(for: page) else { return "" }
    try Task.checkCancellation()
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    request.minimumTextHeight = 0.006

    let preferredLanguages = ["zh-Hans", "zh-Hant", "en-US"]
    if let supportedLanguages = try? request.supportedRecognitionLanguages() {
      let supportedPreferredLanguages = preferredLanguages.filter(supportedLanguages.contains)
      if !supportedPreferredLanguages.isEmpty {
        request.recognitionLanguages = supportedPreferredLanguages
      }
    }

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try Task.checkCancellation()
    try handler.perform([request])
    try Task.checkCancellation()

    let observations = (request.results ?? []).sorted { lhs, rhs in
      let verticalDistance = abs(lhs.boundingBox.maxY - rhs.boundingBox.maxY)
      if verticalDistance > 0.02 {
        return lhs.boundingBox.maxY > rhs.boundingBox.maxY
      }
      return lhs.boundingBox.minX < rhs.boundingBox.minX
    }
    return observations
      .compactMap { $0.topCandidates(1).first?.string.trimmedForPublishing.nilIfEmpty }
      .joined(separator: "\n")
  }

  private func renderedImage(for page: PDFPage) throws -> CGImage? {
    try Task.checkCancellation()
    let bounds = page.bounds(for: .mediaBox)
    guard let targetSize = KnowledgePDFOCRRenderingPolicy.targetSize(for: bounds) else {
      return nil
    }
    let thumbnail = page.thumbnail(of: targetSize, for: .mediaBox)
    try Task.checkCancellation()
    var proposedRect = NSRect(origin: .zero, size: thumbnail.size)
    let image = thumbnail.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    try Task.checkCancellation()
    return image
  }
}

enum KnowledgePDFOCRRenderingPolicy {
  static let maximumDimension: CGFloat = 1_600

  static func targetSize(for bounds: CGRect) -> CGSize? {
    guard bounds.width > 0, bounds.height > 0 else { return nil }

    let scale = min(3, maximumDimension / max(bounds.width, bounds.height))
    return CGSize(
      width: max(1, bounds.width * scale),
      height: max(1, bounds.height * scale)
    )
  }
}
