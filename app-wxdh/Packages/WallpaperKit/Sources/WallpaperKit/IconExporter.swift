import CoreKit
import SwiftUI

/// 主题图标视图：详情页展示与导出渲染共用
struct ThemedIconTile: View {
    let symbol: String
    let colors: [Color]

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
                .fill(LinearGradient(colors: colors,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    Image(systemName: symbol)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.white)
                        .padding(side * 0.26)
                }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// 图标套装导出：渲染 1024×1024 PNG 并批量存入相册
@MainActor
enum IconExporter {
    static let symbols = ["message.fill", "camera.fill", "photo.fill", "music.note",
                          "map.fill", "clock.fill", "calendar", "cart.fill",
                          "book.fill", "gamecontroller.fill", "cloud.fill", "heart.fill"]

    static func render(symbol: String, colors: [Color], side: CGFloat = 1024) -> UIImage? {
        let view = ThemedIconTile(symbol: symbol, colors: colors)
            .frame(width: side, height: side)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.uiImage
    }

    static func exportTheme(_ theme: Theme, completion: @escaping (Int, Int) -> Void) {
        let images = symbols.compactMap { render(symbol: $0, colors: theme.colors) }
        PhotoSaver.shared.saveBatch(images, completion: completion)
    }
}
