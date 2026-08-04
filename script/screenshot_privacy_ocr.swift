#!/usr/bin/env swift

import Darwin
import Foundation
import Vision

private enum ScreenshotPrivacyOCRError: LocalizedError {
  case unreadableImage(String)

  var errorDescription: String? {
    switch self {
    case .unreadableImage(let path):
      return "无法读取截图：\(path)"
    }
  }
}

private func recognizedText(at path: String) throws -> String {
  let url = URL(fileURLWithPath: path)
  guard FileManager.default.isReadableFile(atPath: url.path) else {
    throw ScreenshotPrivacyOCRError.unreadableImage(path)
  }

  let request = VNRecognizeTextRequest()
  request.recognitionLevel = .accurate
  request.usesLanguageCorrection = false
  request.minimumTextHeight = 0.008
  try VNImageRequestHandler(url: url, options: [:]).perform([request])
  return (request.results ?? [])
    .compactMap { $0.topCandidates(1).first?.string }
    .joined(separator: "\n")
}

private func containsMatch(_ pattern: String, in value: String) -> Bool {
  value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}

var blocked: [String] = []
do {
  for path in CommandLine.arguments.dropFirst() {
    let text = try recognizedText(at: path)
    let compacted = text.filter { !$0.isWhitespace }
    if containsMatch(#"(?:file://)?/(?:Users|Volumes)/"#, in: text) {
      blocked.append("\(URL(fileURLWithPath: path).lastPathComponent): OCR local path")
    }
    if containsMatch(#"github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|Authorization:Bearer[A-Za-z0-9._-]{20,}"#, in: compacted) {
      blocked.append("\(URL(fileURLWithPath: path).lastPathComponent): OCR token-like secret")
    }
  }
} catch {
  fputs("screenshot privacy OCR: \(error.localizedDescription)\n", stderr)
  exit(1)
}

if !blocked.isEmpty {
  blocked.forEach { print($0) }
  exit(2)
}
