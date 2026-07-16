import PublishingWorkbenchCore
import SwiftUI

struct GeneralDraftLibraryDetailView: View {
  @ObservedObject var store: WorkbenchStore
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        summary
        articleList
      }
      .padding(20)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("跨站点复制")
        .font(.title2.weight(.semibold))
      Text("选择一篇文章并复制到另一个发布站点。复制后会作为普通草稿继续编辑。")
        .foregroundStyle(.secondary)
    }
  }

  private var summary: some View {
    HStack(spacing: 12) {
      MetricTile(title: "可复制文章", value: "\(visibleItems.count)", systemImage: "doc.on.doc")
      MetricTile(title: "发布站点", value: "\(publishingProfiles.count)", systemImage: "globe")
    }
  }

  @ViewBuilder
  private var articleList: some View {
    if publishingProfiles.count < 2 {
      EmptyStateView(
        title: "需要至少两个发布站点",
        message: "在设置中新增另一个站点后，即可在站点之间复制文章。",
        systemImage: "globe.badge.chevron.backward",
        actionTitle: "打开设置",
        actionSystemImage: "gearshape",
        action: { openSettings() }
      )
      .frame(height: 240)
    } else if visibleItems.isEmpty {
      EmptyStateView(
        title: "还没有可复制文章",
        message: "新建文章后，可以从这里复制到其他站点。",
        systemImage: "doc.on.doc",
        actionTitle: "新建文章",
        actionSystemImage: "square.and.pencil",
        action: {
          store.createDraft()
          store.selectSection(.writing)
        }
      )
      .frame(height: 240)
    } else {
      VStack(alignment: .leading, spacing: 10) {
        Text("文章")
          .font(.headline)

        ForEach(visibleItems) { item in
          articleRow(item)
        }
      }
    }
  }

  private func articleRow(_ item: GeneralDraftLibraryItem) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "doc.text")
        .foregroundStyle(.secondary)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 4) {
        Text(item.title)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        Text("\(item.profileName) · \(item.updatedAt.workbenchShortText)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      Button {
        _ = store.focusDraft(item.draftID, section: .writing)
      } label: {
        Label("打开", systemImage: "arrow.right.circle")
      }
      .controlSize(.small)

      Menu {
        ForEach(copyTargets(for: item)) { profile in
          Button {
            store.copyDraft(item.draftID, toProfileID: profile.id)
          } label: {
            Label(profile.name, systemImage: "globe")
          }
        }
      } label: {
        Label("复制到站点", systemImage: "doc.on.doc")
      }
      .controlSize(.small)
      .disabled(copyTargets(for: item).isEmpty)
    }
    .padding(12)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private var publishingProfiles: [SiteProfile] {
    store.profiles.filter { $0.purpose == .publishing }
  }

  private var visibleItems: [GeneralDraftLibraryItem] {
    let publishingProfileIDs = Set(publishingProfiles.map(\.id))
    return store.generalDraftLibraryReport.items
      .filter { publishingProfileIDs.contains($0.profileID) }
      .prefix(50)
      .map { $0 }
  }

  private func copyTargets(for item: GeneralDraftLibraryItem) -> [SiteProfile] {
    publishingProfiles.filter { $0.id != item.profileID }
  }
}
