import Foundation
import CoreKit

/// 协议正文获取器（需求：显示 URL 内容，App 缓存一份，URL 不可达时显示缓存）：
///   1. 有网络 → 拉取 URL 最新内容，写磁盘缓存（Documents/LegalCache/<kind>.html）
///   2. 无网络/失败 → 读磁盘缓存
///   3. 无缓存（首次离线）→ 兜底打包进 spec 的 legal.html
/// 全部在后台线程执行，主线程回调。
public enum LegalDocFetcher {

    /// 缓存目录：Library/Caches/LegalCache（系统标准缓存位置，随系统清理策略管理）
    private static var cacheDir: URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("LegalCache", isDirectory: true)
        if let dir, !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                Log.error("[LegalDocFetcher] 缓存目录创建失败: \(error.localizedDescription)")
            }
        }
        return dir
    }

    private static func cacheURL(for kind: LegalDoc.Kind) -> URL? {
        cacheDir?.appendingPathComponent("\(kind.rawValue).html")
    }

    /// 获取协议正文：
    /// - `remote` 优先；成功即更新缓存
    /// - 失败回退磁盘缓存；再回退 `fallbackHTML`（spec 打包正文）
    /// - `completion` 主线程回调 (html, isFromCache)；html 为 nil 表示三级兜底全部落空
    public static func fetch(kind: LegalDoc.Kind,
                             urlString: String?,
                             fallbackHTML: String?,
                             completion: @escaping @MainActor (String?, Bool) -> Void) {
        Task.detached(priority: .userInitiated) {
            // 1. 远程拉取
            if let urlString, !urlString.isEmpty, let url = URL(string: urlString) {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                         timeoutInterval: 10)
                request.setValue("text/html", forHTTPHeaderField: "Accept")
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200,
                       let html = String(data: data, encoding: .utf8), !html.isEmpty {
                        writeCache(html, kind: kind)
                        await MainActor.run { completion(html, false) }
                        return
                    }
                    Log.warn("[LegalDocFetcher] \(kind.rawValue) 远程状态异常，转缓存")
                } catch {
                    Log.warn("[LegalDocFetcher] \(kind.rawValue) 远程不可达: \(error.localizedDescription)")
                }
            }

            // 2. 磁盘缓存
            if let cached = readCache(kind: kind) {
                await MainActor.run { completion(cached, true) }
                return
            }

            // 3. 打包兜底
            await MainActor.run { completion(fallbackHTML, fallbackHTML == nil) }
        }
    }

    /// 写缓存（原子写入，避免中断产生半截文件）
    private static func writeCache(_ html: String, kind: LegalDoc.Kind) {
        guard let url = cacheURL(for: kind) else { return }
        do {
            try html.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            Log.error("[LegalDocFetcher] 缓存写入失败: \(error.localizedDescription)")
        }
    }

    private static func readCache(kind: LegalDoc.Kind) -> String? {
        guard let url = cacheURL(for: kind),
              let data = try? Data(contentsOf: url),
              let html = String(data: data, encoding: .utf8),
              !html.isEmpty else { return nil }
        return html
    }
}
