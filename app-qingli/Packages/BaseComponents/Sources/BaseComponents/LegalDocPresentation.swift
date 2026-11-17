import SafariServices
import SwiftUI

/// 合规文档类型（隐私政策/用户协议）：展示标题（与我的页/订阅墙文案一致）
enum LegalKind: String, Identifiable {
    case privacy, terms

    var id: String { rawValue }
    var title: String { self == .privacy ? "隐私政策" : "用户协议" }

    /// spec 打包的兜底正文（subscription.html 模式调用方传入，这里不重复读取）
    func fallbackHTML(privacy: String?, terms: String?) -> String? {
        self == .privacy ? privacy : terms
    }
}

/// 在线政策链接是否已配置：nil / 无 host / example.com 模板占位 → false（回退内置正文）。
/// 生产 spec.compliance 填真实 URL 后，协议按钮即成为审核要求的功能链接。
func isConfiguredPolicyURL(_ url: URL?) -> Bool {
    guard let url, let host = url.host, !host.hasSuffix("example.com") else { return false }
    return true
}

/// 协议入口是否有可展示内容：真实在线 URL 或内置 HTML 正文。
/// 两者都缺（含 example.com 占位 URL + 空正文）时调用方应隐藏按钮，避免外跳占位站。
func hasLegalContent(url: URL?, html: String?) -> Bool {
    isConfiguredPolicyURL(url) || (html?.isEmpty == false)
}

/// 合规文档展示（需求：显示 URL 内容，App 缓存一份，URL 不可达时显示缓存）：
///   打开即渲染（缓存 → 兜底正文），后台拉 URL 最新内容无感刷新。
///   URL 完全不可用且无任何内容 → 回退应用内 Safari（旧行为兜底）。
struct LegalDocSheet: View {
    let kind: LegalKind
    let url: URL?
    let html: String?

    @State private var content: String?

    var body: some View {
        Group {
            if isConfiguredPolicyURL(url), content == nil, (html?.isEmpty != false) {
                // 极端场景：URL 有效但缓存与兜底都为空 → 先用 Safari 打开（网络可达时直出）
                SafariSheet(url: url!)
            } else {
                NavigationStack {
                    LegalDocView(title: kind.title, html: content ?? "")
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
        .task {
            // 三级兜底：远程 URL（成功即刷新缓存）→ 磁盘缓存 → spec 打包正文
            await LegalDocFetcher.fetchAsync(kind: legalKindMapping,
                                             urlString: url?.absoluteString,
                                             fallbackHTML: html) { fresh, _ in
                if let fresh, !fresh.isEmpty { content = fresh }
            }
            // 打开瞬间先用兜底渲染（不等网络）
            if content == nil, let html, !html.isEmpty { content = html }
        }
    }

    private var legalKindMapping: LegalDoc.Kind {
        kind == .privacy ? .privacy : .terms
    }

    @Environment(\.dismiss) private var dismiss
}

private extension LegalDocFetcher {
    /// async 包装（sheet .task 里顺序执行：先秒开兜底，再等远程结果）
    static func fetchAsync(kind: LegalDoc.Kind, urlString: String?, fallbackHTML: String?,
                           completion: @escaping (String?, Bool) -> Void) async {
        await withCheckedContinuation { cont in
            fetch(kind: kind, urlString: urlString, fallbackHTML: fallbackHTML) { html, fromCache in
                completion(html, fromCache)
                cont.resume()
            }
        }
    }
}

/// SFSafariViewController 包装：应用内浏览在线政策页，右上角「完成」收起
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
