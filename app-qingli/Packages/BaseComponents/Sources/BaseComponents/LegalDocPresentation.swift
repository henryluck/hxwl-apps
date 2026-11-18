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

/// 合规文档展示（需求：直接打开 URL；网络不可达时显示 App 内缓存文件）：
///   ① 在线可达 → SFSafariViewController 直接打开在线页（样式与线上完全一致）
///   ② 不可达 → App 内渲染磁盘缓存（此前在线访问成功时落盘的内容）
///   ③ 无缓存（首次离线）→ spec 打包兜底正文（并落盘，之后离线也有缓存）
struct LegalDocSheet: View {
    let kind: LegalKind
    let url: URL?
    let html: String?

    /// nil = 探测中；true = 在线可达（Safari 直出）；false = 离线（缓存渲染）
    @State private var online: Bool?
    @State private var offlineContent: String?

    var body: some View {
        Group {
            switch online {
            case .some(true) where url != nil:
                SafariSheet(url: url!)   // 应用内直接打开在线页
            default:
                NavigationStack {
                    LegalDocView(title: kind.title, html: offlineContent ?? html ?? "")
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
            // 离线内容先备好（磁盘缓存 → spec 兜底），探测失败立即渲染
            if let cached = LegalDocFetcher.readCached(kind: legalKindMapping) {
                offlineContent = cached
            } else if let html, !html.isEmpty {
                offlineContent = html
                LegalDocFetcher.warmCache(kind: legalKindMapping, html: html)   // 兜底落盘
            }
            // 在线探测：可达 → 顺便把最新内容刷进缓存（下次离线用）
            online = await LegalDocFetcher.probeAndRefreshCache(url: url, kind: legalKindMapping)
        }
    }

    private var legalKindMapping: LegalDoc.Kind {
        kind == .privacy ? .privacy : .terms
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
