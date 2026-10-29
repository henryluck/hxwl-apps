import SafariServices
import SwiftUI

/// 合规文档类型（隐私政策/用户协议）：展示标题（与我的页/订阅墙文案一致）
enum LegalKind: String, Identifiable {
    case privacy, terms

    var id: String { rawValue }
    var title: String { self == .privacy ? "隐私政策" : "用户协议" }
}

/// 在线政策链接是否已配置：nil / 无 host / example.com 模板占位 → false（回退内置正文）。
/// 生产 spec.compliance 填真实 URL 后，协议按钮即成为审核要求的功能链接（应用内 Safari 浏览）。
func isConfiguredPolicyURL(_ url: URL?) -> Bool {
    guard let url, let host = url.host, !host.hasSuffix("example.com") else { return false }
    return true
}

/// 协议入口是否有可展示内容：真实在线 URL 或内置 HTML 正文。
/// 两者都缺（含 example.com 占位 URL + 空正文）时调用方应隐藏按钮，避免外跳占位站。
func hasLegalContent(url: URL?, html: String?) -> Bool {
    isConfiguredPolicyURL(url) || (html?.isEmpty == false)
}

/// 合规文档展示（审核 3.1.2 要求「功能链接」），两级兜底：
/// 1. spec 配置了真实在线政策页 → SFSafariViewController 应用内浏览；
/// 2. URL 未配置或仍是 example.com 模板占位 → spec.compliance.legal 打包的 HTML 正文离线浏览（LegalDocView）。
/// 调用方在两者都缺时可自行回退 openURL 外链（旧 spec 行为）。
struct LegalDocSheet: View {
    let kind: LegalKind
    let url: URL?
    let html: String?

    var body: some View {
        if isConfiguredPolicyURL(url), let url {
            SafariSheet(url: url)
        } else {
            NavigationStack {
                LegalDocView(title: kind.title, html: html ?? "")
                    .navigationTitle(kind.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { dismiss() }
                        }
                    }
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
}

/// SFSafariViewController 包装：应用内浏览在线政策页，右上角「完成」收起
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
