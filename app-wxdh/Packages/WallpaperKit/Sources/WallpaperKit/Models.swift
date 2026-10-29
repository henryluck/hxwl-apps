import Capabilities
import CoreKit
import SwiftUI

// MARK: - 数据模型（catalog.json 驱动，schema 与素材产线一致）

struct Theme: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let style: String
    let symbol: String
    let isPro: Bool
    let colorHexes: [String]
    let wallpapers: [String]?

    var colors: [Color] { colorHexes.map { Color(hex: $0) } }

    enum CodingKeys: String, CodingKey {
        case id, name, style, symbol, isPro, wallpapers
        case colorHexes = "colors"
    }
}

struct ThemeCatalog: Codable {
    let version: Int
    let categories: [String]
    let themes: [Theme]
}

@MainActor
final class WallpaperStore: ObservableObject {
    @Published private(set) var catalog: ThemeCatalog?
    @Published private(set) var error: String?

    private let content: any ContentService

    init(content: any ContentService) {
        self.content = content
    }

    func load() async {
        do {
            let data = try await content.catalogData()
            catalog = try JSONDecoder().decode(ThemeCatalog.self, from: data)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
