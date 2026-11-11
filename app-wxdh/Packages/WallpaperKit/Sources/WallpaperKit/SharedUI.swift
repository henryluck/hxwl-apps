import SwiftUI

/// 从 Bundle 内按相对路径加载图片
struct AssetImage: View {
    let path: String
    var contentMode: ContentMode = .fill

    var body: some View {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(path),
           let uiImage = UIImage(contentsOfFile: url.path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            Color(.systemGray5)
        }
    }
}

/// 主题卡片主视觉：有真实壁纸用壁纸，没有则渐变占位
struct ThemeArtwork: View {
    let theme: Theme

    var body: some View {
        if let first = theme.wallpapers?.first {
            AssetImage(path: first)
        } else {
            LinearGradient(colors: theme.colors,
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    Image(systemName: theme.symbol)
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.9))
                }
        }
    }
}

struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                LinearGradient(colors: [Color(hex: "FFB75E"), Color(hex: "ED8F03")],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(Capsule())
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
