import Capabilities
import SwiftUI
import UIKit

/// 意见反馈：按 spec.support.feedback.fields 动态生成表单；
/// 配了中台 → submitFeedback；未配 → mailto（字段拼进正文）。
///
/// 架构说明：BaseComponents 是 SwiftPM 包，仅依赖 CoreKit + Capabilities，
/// 不能 import 工厂主模块（说明书类型所在）。因此本视图使用 **view-local**
/// 的 `Field` 结构 + `ZhongtaiService` 协议 + 基本类型；由 Task 7 的 SettingsView /
/// 壳层把说明书层的 Field → `FeedbackView.Field` 做桥接。
public struct FeedbackView: View {
    /// 单个反馈字段定义（view-local，与工厂主模块解耦）。
    public struct Field {
        public let key: String
        public let label: String
        public let kind: String         // "text" | "picker"
        public let options: [String]    // picker 时的可选项；text 时为空
        public let required: Bool

        public init(key: String, label: String, kind: String, options: [String] = [], required: Bool = false) {
            self.key = key
            self.label = label
            self.kind = kind
            self.options = options
            self.required = required
        }
    }

    let fields: [Field]
    let supportEmail: String?
    let zhongtai: any ZhongtaiService
    let appVersion: String

    @Environment(\.openURL) private var openURL
    @State private var values: [String: String] = [:]
    @State private var submitting = false
    @State private var done = false          // 中台提交成功 → "已提交"
    @State private var mailed = false        // mailto 兜底 → "已打开邮件草稿"（中性提示，不声称已提交）
    @State private var error: String?

    public init(fields: [Field], supportEmail: String?,
                zhongtai: any ZhongtaiService, appVersion: String) {
        self.fields = fields
        self.supportEmail = supportEmail
        self.zhongtai = zhongtai
        self.appVersion = appVersion
    }

    public var body: some View {
        Form {
            // 用 enumerate-by-offset 而非 `id: \.key`：admin 端可能产出重复 key
            // （删后再加），non-unique ids 会破坏 SwiftUI。提交时仍按 field.key 聚合，
            // 服务器契约不变；重复 key 是 admin 数据质量问题，不阻塞渲染。
            ForEach(Array(fields.enumerated()), id: \.offset) { _, f in
                fieldRow(f)
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.caption) }
            }
        }
        .navigationTitle("意见反馈")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(submitting ? "提交中…" : "提交") { submit() }
                    .disabled(submitting || done)
            }
        }
        .alert("已提交，感谢反馈！", isPresented: $done) { }
        .alert("已打开邮件草稿，请在邮件中完成发送", isPresented: $mailed) { }
    }

    @ViewBuilder private func fieldRow(_ f: Field) -> some View {
        if f.kind == "picker" {
            Picker(f.label + (f.required ? " *" : ""), selection: Binding(
                get: { values[f.key] ?? f.options.first ?? "" },
                set: { values[f.key] = $0 })) {
                ForEach(f.options, id: \.self) { Text($0).tag($0) }
            }
        } else {
            TextField(f.label + (f.required ? " *" : ""), text: Binding(
                get: { values[f.key] ?? "" },
                set: { values[f.key] = $0 }),
                axis: .vertical)
                .lineLimit(2...6)
        }
    }

    private func submit() {
        // 必填校验
        if let missing = fields.first(where: { $0.required && (values[$0.key] ?? "").isEmpty }) {
            error = "请填写「\(missing.label)」"
            return
        }
        error = nil
        submitting = true

        if zhongtai.isConfigured {
            Task {
                do {
                    let payload = FeedbackPayload(
                        fields: values,
                        appVersion: appVersion,
                        deviceModel: UIDevice.current.model,
                        systemVersion: UIDevice.current.systemVersion
                    )
                    try await zhongtai.submitFeedback(payload)
                    await MainActor.run { submitting = false; done = true }
                } catch {
                    await MainActor.run {
                        submitting = false
                        self.error = "提交失败，改用邮件"
                        mailto()
                    }
                }
            }
        } else {
            // 未配置中台：仅打开邮件草稿。不设 `done`（避免触发"已提交"误导用户），
            // 改用中性的 `mailed` 提示——用户尚未发送任何内容，需在邮件 App 里完成。
            mailto()
            submitting = false
            mailed = true
        }
    }

    private func mailto() {
        guard let email = supportEmail,
              let url = URL(string: "mailto:\(email)?subject=意见反馈&body=" +
                  fields.map { "\($0.label)：\(values[$0.key] ?? "")" }.joined(separator: "%0D%0A"))
        else { return }
        openURL(url)
    }
}
