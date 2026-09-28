import PublishingDomainContracts
import SwiftUI

struct RepositoryImageGalleryTile: View {
  @Environment(\.workbenchAccentColor) private var accentColor
  let asset: RepositoryImageAsset
  let isSelected: Bool
  let thumbnailSize: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      RoundedRectangle(cornerRadius: 6)
        .fill(.quaternary.opacity(0.35))
        .frame(height: thumbnailSize * 0.68)
        .overlay {
          WorkbenchThumbnailView(fileURL: asset.fileURL, maxPixelSize: 640, cornerRadius: 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isSelected ? accentColor : Color.clear, lineWidth: 2)
        }
        .accessibilityHidden(true)
      Text(asset.filename)
        .font(.workbenchCardTitle)
        .lineLimit(1).truncationMode(.middle)
      HStack(spacing: 5) {
        Text(ByteCountFormatter.string(fromByteCount: asset.byteSize, countStyle: .file))
        Spacer(minLength: 0)
        if !asset.references.isEmpty {
          Label("\(asset.references.count)", systemImage: "doc.text")
        }
      }
      .font(.workbenchSupporting).foregroundStyle(.secondary)
    }
    .padding(5)
    .background(
      isSelected ? accentColor.opacity(0.1) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .contentShape(Rectangle())
    .help(asset.repositoryPath)
  }
}

struct RepositoryImageGalleryRow: View {
  let asset: RepositoryImageAsset

  var body: some View {
    HStack(spacing: 12) {
      WorkbenchThumbnailView(fileURL: asset.fileURL, maxPixelSize: 160, cornerRadius: 4)
        .frame(width: 70, height: 48).clipped().accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(asset.filename).font(.workbenchCardTitle).lineLimit(1)
        Text(asset.repositoryPath).font(.workbenchSupporting)
          .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 6)
      Text(ByteCountFormatter.string(fromByteCount: asset.byteSize, countStyle: .file))
        .font(.workbenchSupporting).foregroundStyle(.secondary)
      Label("\(asset.references.count)", systemImage: "doc.text")
        .font(.workbenchSupporting).foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

struct RepositoryImageSidebarHost: View {
  @ObservedObject var session: RepositoryImageBrowserSession
  @Binding var stage: ImageWorkbenchContextStage

  var body: some View {
    RepositoryImageFolderSidebar(
      inventory: session.inventory, isLoading: session.isLoading,
      errorMessage: session.errorMessage, scope: $session.scope,
      expandedPaths: $session.expandedPaths,
      onBrowse: {
        stage = .resources
        session.resourceMode = .repository
      },
      onOpenMaintenance: {
        stage = .resources
        session.resourceMode = .manager
      },
      onRefresh: { session.refreshRequestID = UUID() }
    )
  }
}
