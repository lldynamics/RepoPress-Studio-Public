import PublishingAICore
import SwiftUI

struct AIModelMetadataView: View {
  let model: AIModelDescriptor
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let context = model.contextWindow ?? model.maxInputTokens {
        Text("上下文：\(context.formatted()) tokens")
      }
      if let output = model.maxOutputTokens {
        Text("最大输出：\(output.formatted()) tokens")
      }
      if let input = model.inputPricePerMillionUSD {
        Text("输入：$\(input.formatted(.number.precision(.fractionLength(0...4)))) / 百万 tokens")
      }
      if let output = model.outputPricePerMillionUSD {
        Text("输出：$\(output.formatted(.number.precision(.fractionLength(0...4)))) / 百万 tokens")
      }
      if model.inputPricePerMillionUSD != nil || model.outputPricePerMillionUSD != nil {
        Text("价格由服务商返回，最终费用以账户账单为准。")
      } else {
        Text("服务商未返回价格，请查看账户计费说明。")
      }
    }
    .font(.workbenchMetadata)
    .foregroundStyle(.secondary)
  }
}
