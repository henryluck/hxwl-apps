import SwiftUI
import WebKit

/// 协议正文离线浏览：用打包进 spec 的 HTML 直接 loadHTMLString（无需联网/URL）。
/// 外层由 Task 7 的 SettingsView 包 `NavigationStack` + `.navigationTitle(title)`。
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
        wv.loadHTMLString(styledHTML, baseURL: nil)
        return wv
    }

    public func updateUIView(_ wv: WKWebView, context: Context) {
        // HTML 在 makeUIView 一次性加载；内容不可变，这里无需重 load（避免闪烁）。
    }

    private var styledHTML: String {
        "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'>"
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
