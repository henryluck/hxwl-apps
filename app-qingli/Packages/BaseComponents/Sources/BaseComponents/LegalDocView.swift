import SwiftUI
import WebKit

/// 协议正文浏览（需求升级：显示 URL 内容 + 本地缓存 + 离线兜底）：
///   打开即用缓存/兜底内容渲染（秒开，无需等待网络）；
///   后台拉取 URL 最新内容，拉到后无感刷新 WebView。
/// 外层由 SettingsView 包 `NavigationStack` + `.navigationTitle(title)`。
public struct LegalDocView: UIViewRepresentable {
    let title: String
    let html: String

    public init(title: String, html: String) {
        self.title = title
        self.html = html
    }

    public func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.javaScriptEnabled = false   // legal HTML needs no JS
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.loadHTMLString(Self.styled(html), baseURL: nil)
        context.coordinator.loadedHTML = html
        return wv
    }

    public func updateUIView(_ wv: WKWebView, context: Context) {
        // 远程拉到最新内容后 html 会变化 → 无感刷新（仅当内容真的变了，避免闪烁）
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        wv.loadHTMLString(Self.styled(html), baseURL: nil)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public class Coordinator {
        var loadedHTML: String?
    }

    /// 统一移动端排版：viewport + 系统字体 + 行高（远程 HTML 自带样式，这里只补基础）
    static func styled(_ html: String) -> String {
        // 远程页通常自带完整 <html> 结构与样式，直接装载即可；纯片段才包壳
        if html.lowercased().contains("<html") {
            return html
        }
        return "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'>"
        + "<style>body{font:-apple-system-body;padding:16px;line-height:1.6;}"
        + "h1{font-size:22px}h2{font-size:18px;margin-top:20px}</style></head>"
        + "<body>\(html)</body></html>"
    }
}

/// 协议文档标识：订阅墙/我的页共用，驱动 sheet(item:) 弹出 LegalDocView。
/// html 为外层判空后的非空正文；title 写死两处一致（「隐私政策」「用户协议」）。
public struct LegalDoc: Identifiable, Equatable {
    public enum Kind: String { case privacy, terms }

    public let kind: Kind
    public let html: String

    public init(kind: Kind, html: String) {
        self.kind = kind
        self.html = html
    }

    public var id: String { kind.rawValue }
    public var title: String { kind == .privacy ? "隐私政策" : "用户协议" }
}
