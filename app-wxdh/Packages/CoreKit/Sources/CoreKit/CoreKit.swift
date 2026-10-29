import Foundation
import OSLog
import SwiftUI

// MARK: - 日志（LoggerService 的底层实现，见 Capabilities）

public enum Log {
    private static let logger = Logger(subsystem: "com.factory.core", category: "app")

    public static func info(_ message: String) { logger.info("\(message)") }
    public static func warn(_ message: String) { logger.warning("\(message)") }
    public static func error(_ message: String) { logger.error("\(message)") }
}

// MARK: - 颜色工具

extension Color {
    public init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// 由主色派生一个协调的渐变搭档色（简单提亮/偏移，工厂默认换肤规则）
    public var gradientPartner: Color {
        UIColor(self).adjusted(hue: 0.06, brightness: 0.12, saturation: -0.05).color
    }
}

extension UIColor {
    func adjusted(hue: CGFloat, brightness: CGFloat, saturation: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: (h + hue).truncatingRemainder(dividingBy: 1),
                       saturation: max(0, min(1, s + saturation)),
                       brightness: max(0, min(1, b + brightness)),
                       alpha: a)
    }

    var color: Color { Color(self) }
}

// MARK: - Keychain 简易封装

public enum KeychainStore {
    public static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    public static func get(_ key: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return String(data: data, encoding: .utf8)
    }

    public static func remove(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 轻量 HTTP 客户端（ServerService 的底层实现，见 Capabilities）

public enum HTTPClient {
    public static func get(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    public static func post(_ url: URL, json: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
