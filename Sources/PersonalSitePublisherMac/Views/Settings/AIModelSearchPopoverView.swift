import PublishingAICore
import PublishingCoreSupport
import SwiftUI

struct AIModelSearchPopoverView: View {
  let models: [AIModelDescriptor]
  let selectedModel: String
  let onSelect: (String) -> Void
  @State private var searchText = ""

  var filteredModels: [AIModelDescriptor] {
    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return models
    }
    return models.filter {
      $0.id.localizedCaseInsensitiveContains(trimmed)
        || $0.name.localizedCaseInsensitiveContains(trimmed)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.workbenchSecondary)
        TextField(String(localized: "搜索模型 (如 r1, sonnet, gemini, flash...)"), text: $searchText)
          .textFieldStyle(.plain)
          .font(.workbenchBody)
          .accessibilityLabel(
            String(localized: "搜索模型 (如 r1, sonnet, gemini, flash...)")
          )
        if !searchText.isEmpty {
          Button {
            searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.workbenchSecondary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(WorkbenchSpacing.control)
      .background(Color.primary.opacity(0.04))

      Divider()

      if filteredModels.isEmpty {
        VStack(spacing: 6) {
          Spacer()
          Image(systemName: "questionmark.folder")
            .font(.workbenchTitle2)
            .foregroundStyle(.workbenchSecondary)
          Text("未找到包含 \"\(searchText)\" 的模型")
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
          Spacer()
        }
        .frame(minHeight: 140)
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(filteredModels) { descriptor in
              Button {
                onSelect(descriptor.id)
              } label: {
                HStack(spacing: 8) {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.name)
                      .font(.workbenchBody.monospaced())
                      .foregroundStyle(Color.primary)
                    if descriptor.id != descriptor.name {
                      Text(descriptor.id)
                        .font(.workbenchMetadata.monospaced())
                        .foregroundStyle(.workbenchSecondary)
                    }
                    AIModelMetadataView(model: descriptor)
                  }

                  Spacer()

                  if descriptor.hasProviderMetadata, descriptor.isReasoning {
                    Text("深度思考")
                      .font(.workbenchMetadata.weight(.medium))
                      .padding(.horizontal, WorkbenchSpacing.tight)
                      .padding(.vertical, 2)
                      .background(Color.secondary.opacity(0.12), in: Capsule())
                      .foregroundStyle(.workbenchSecondary)
                  }

                  if descriptor.hasProviderMetadata, descriptor.isVision {
                    Text("多模态")
                      .font(.workbenchMetadata.weight(.medium))
                      .padding(.horizontal, WorkbenchSpacing.tight)
                      .padding(.vertical, 2)
                      .background(Color.secondary.opacity(0.12), in: Capsule())
                      .foregroundStyle(.workbenchSecondary)
                  }

                  if descriptor.id == selectedModel {
                    Image(systemName: "checkmark")
                      .font(.workbenchMetadata.weight(.bold))
                      .foregroundStyle(WorkbenchTheme.brand)
                  }
                }
                .padding(.horizontal, WorkbenchSpacing.control)
                .padding(.vertical, WorkbenchSpacing.icon)
                .contentShape(Rectangle())
                .background(
                  descriptor.id == selectedModel
                    ? WorkbenchTheme.brand.opacity(0.08)
                    : Color.clear,
                  in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.badge)
                )
              }
              .buttonStyle(.plain)
            }
          }
          .padding(WorkbenchSpacing.icon)
        }
        .frame(minHeight: 200, maxHeight: 320)
      }

      Divider()

      HStack {
        Text("共 \(models.count) 个可用模型")
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
        Spacer()
        if !searchText.isEmpty {
          Text("已筛选出 \(filteredModels.count) 个")
            .font(.workbenchMetadata)
            .foregroundStyle(.workbenchSecondary)
        }
      }
      .padding(.horizontal, WorkbenchSpacing.control)
      .padding(.vertical, WorkbenchSpacing.icon)
    }
    .frame(width: 360)
  }
}
