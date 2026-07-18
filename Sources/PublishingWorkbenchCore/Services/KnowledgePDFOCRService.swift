import AppKit
import Foundation
import PDFKit
import Vision

final class KnowledgePDFOCRService: @unchecked Sendable {
  func recognizeText(in page: PDFPage) throws -> String {
    guard let image = renderedImage(for: page) else { return "" }
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
    try handler.perform([request])

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

  private func renderedImage(for page: PDFPage) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    guard bounds.width > 0, bounds.height > 0 else { return nil }

    let maximumDimension: CGFloat = 2_400
    let scale = min(3, maximumDimension / max(bounds.width, bounds.height))
    let targetSize = NSSize(
      width: max(1, bounds.width * scale),
      height: max(1, bounds.height * scale)
    )
    let thumbnail = page.thumbnail(of: targetSize, for: .mediaBox)
    var proposedRect = NSRect(origin: .zero, size: thumbnail.size)
    return thumbnail.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
  }
}
