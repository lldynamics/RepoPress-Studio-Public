import PublishingWorkbenchCore
import SwiftUI

struct RepositoryFullDiffSheet: View {
  let file: RepositoryChangedFile
  let profile: SiteProfile
  let source: RepositoryChangedFileSource
  let upstreamName: String?
  @State private var diff: String?
  @State private var errorMessage: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("完整差异")
        .font(.headline)
      Text(file.path)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      } else if let diff {
        if diff.isEmpty {
          Text("没有可显示的文本差异。")
            .foregroundStyle(.secondary)
        } else {
          ScrollView([.horizontal, .vertical]) {
            Text(diff)
              .font(.callout.monospaced())
              .textSelection(.enabled)
              .fixedSize(horizontal: true, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .accessibilityLabel("完整差异")
          .accessibilityIdentifier("repository-full-diff-content")
        }
      } else {
        ProgressView("正在读取差异…")
      }
      Spacer(minLength: 0)
      HStack {
        Spacer()
        Button("完成") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 640)
    .task {
      do {
        guard source != .remote || upstreamName != nil else {
          throw RepositoryFullDiffError.unavailable
        }
        let file = file
        let profile = profile
        let upstreamName = upstreamName
        let loadedDiff = try await Task.detached(priority: .utility) {
          try LocalRepositoryService().fullDiff(
            for: file, profile: profile, upstreamName: upstreamName
          )
        }.value
        try Task.checkCancellation()
        diff = loadedDiff
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        errorMessage = error.localizedDescription
      }
    }
  }
}
