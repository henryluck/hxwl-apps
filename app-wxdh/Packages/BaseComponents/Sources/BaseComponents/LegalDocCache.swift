import CoreKit
import Foundation

/// 协议正文缓存器（需求：直接打开 URL；网络不可达时显示 App 内缓存文件）：
///   1. 在线可达 → Safari 直出在线页（探测成功顺带把最新内容写磁盘缓存）
///   2. 离线 → 读磁盘缓存（Library/Caches/LegalCache/<kind>.html）
///   3. 无缓存（首次离线）→ 兜底打包正文（warmCache 落盘，下次离线也有）
enum LegalDocCache {
    private static var cacheDir: URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("LegalCache", isDirectory: true)
        if let dir, !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func cacheURL(for kind: LegalKind) -> URL? {
        cacheDir?.appendingPathComponent("\(kind.rawValue).html")
    }

    /// 读取磁盘缓存（同步；主线程调用，文件很小不卡）。
    static func readCached(kind: LegalKind) -> String? {
        guard let url = cacheURL(for: kind),
              let data = try? Data(contentsOf: url),
              let html = String(data: data, encoding: .utf8),
              !html.isEmpty else { return nil }
        return html
    }

    /// 把兜底正文落盘（首次离线打开时预热缓存，此后离线也有缓存可读）。
    static func warmCache(kind: LegalKind, html: String) {
        guard readCached(kind: kind) == nil else { return }   // 已有缓存不覆盖
        writeCache(html, kind: kind)
    }

    /// 在线探测：可达返回 true 并把最新内容刷进缓存（下次离线用）；不可达返回 false。
    static func probeAndRefreshCache(url: URL?, kind: LegalKind) async -> Bool {
        guard let url else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 6)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                if let html = String(data: data, encoding: .utf8), !html.isEmpty {
                    writeCache(html, kind: kind)
                }
                return true
            }
            return false
        } catch {
            Log.warn("[LegalDocCache] \(kind.rawValue) 在线不可达: \(error.localizedDescription)")
            return false
        }
    }

    private static func writeCache(_ html: String, kind: LegalKind) {
        guard let url = cacheURL(for: kind) else { return }
        try? html.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
