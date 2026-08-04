import Foundation
import SwiftUI

struct RSSSubscriptionDiscovery: Identifiable, Equatable {
  let id: UUID
  let sourceURL: URL
  let feedURLs: [URL]

  init(sourceURL: URL, feedURLs: [URL]) {
    id = UUID()
    self.sourceURL = sourceURL
    var seen = Set<URL>()
    self.feedURLs = feedURLs.filter { seen.insert($0).inserted }
  }

  var primaryURL: URL? { feedURLs.first }

  var alternativeURLs: [URL] { Array(feedURLs.dropFirst()) }
}

struct RSSSubscriptionDiscoveryView: View {
  @Environment(\.dismiss) private var dismiss
  let discovery: RSSSubscriptionDiscovery
  let onCancel: () -> Void
  let onAdd: ([URL]) -> Void
  @State private var selectedURLs: Set<URL>

  init(
    discovery: RSSSubscriptionDiscovery,
    onCancel: @escaping () -> Void,
    onAdd: @escaping ([URL]) -> Void
  ) {
    self.discovery = discovery
    self.onCancel = onCancel
    self.onAdd = onAdd
    _selectedURLs = State(initialValue: Set(discovery.feedURLs.prefix(1)))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("发现结果", systemImage: "dot.radiowaves.left.and.right")
        .font(.title2.weight(.semibold))

      Text(
        String(
          format: String(localized: "在 %@ 找到 %lld 个 RSS / Atom 订阅。"),
          sourceDisplayName,
          Int64(discovery.feedURLs.count)
        )
      )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if let primaryURL = discovery.primaryURL {
            candidateRow(primaryURL, title: "推荐订阅")
          }

          if !discovery.alternativeURLs.isEmpty {
            Text("该站还发现了其他订阅")
              .font(.headline)
              .padding(.top, 4)

            ForEach(discovery.alternativeURLs, id: \.self) { url in
              candidateRow(url, title: "其他订阅")
            }
          }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
      }
      .frame(maxHeight: 300)

      HStack {
        Text(
          String(
            format: String(localized: "已选择 %lld 个订阅"),
            Int64(selectedURLs.count)
          )
        )
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("取消", role: .cancel) {
          onCancel()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button(
          String(
            format: String(localized: "添加选中的 %lld 个订阅"),
            Int64(selectedURLs.count)
          )
        ) {
          onAdd(selectedFeedURLs)
          dismiss()
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(selectedURLs.isEmpty)
      }
    }
    .padding(WorkbenchSpacing.spacious)
    .frame(minWidth: 560, minHeight: 420)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("rss-subscription-discovery")
  }

  private var sourceDisplayName: String {
    discovery.sourceURL.host ?? discovery.sourceURL.absoluteString
  }

  private var selectedFeedURLs: [URL] {
    discovery.feedURLs.filter { selectedURLs.contains($0) }
  }

  private func candidateRow(_ url: URL, title: LocalizedStringKey) -> some View {
    Toggle(isOn: selectionBinding(for: url)) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.medium))
        Text(verbatim: url.absoluteString)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)
      }
    }
    .toggleStyle(.checkbox)
    .accessibilityLabel(title)
    .accessibilityValue(Text(verbatim: url.absoluteString))
  }

  private func selectionBinding(for url: URL) -> Binding<Bool> {
    Binding(
      get: { selectedURLs.contains(url) },
      set: { isSelected in
        if isSelected {
          selectedURLs.insert(url)
        } else {
          selectedURLs.remove(url)
        }
      }
    )
  }
}
