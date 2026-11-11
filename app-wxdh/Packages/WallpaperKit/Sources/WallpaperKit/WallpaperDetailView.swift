import Capabilities
import CoreKit
import SwiftUI

/// 主题详情：样机预览 + 壁纸保存 + 图标套装导出
struct WallpaperDetailView: View {
    let theme: Theme
    let context: PluginContext

    @State private var saveResult: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                PhoneMockView(theme: theme)
                    .frame(height: 400)
                    .padding(.top, 8)

                wallpaperSection
                iconSection
            }
            .padding(.bottom, 100)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(theme.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { applyButton }
        .alert("提示", isPresented: Binding(get: { saveResult != nil },
                                            set: { if !$0 { saveResult = nil } })) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(saveResult ?? "")
        }
    }

    private var wallpaperSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("壁纸")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if let wallpapers = theme.wallpapers, !wallpapers.isEmpty {
                        ForEach(wallpapers, id: \.self) { path in
                            AssetImage(path: path)
                                .frame(width: 90, height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                    } else {
                        ForEach(0..<3, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 14)
                                .fill(LinearGradient(colors: i == 0 ? theme.colors : theme.colors.reversed(),
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 90, height: 160)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("图标套装（12 枚）")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(IconExporter.symbols, id: \.self) { symbol in
                    ThemedIconTile(symbol: symbol, colors: theme.colors)
                        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                }
            }
            .padding(.horizontal)

            Button {
                IconExporter.exportTheme(theme) { saved, failed in
                    saveResult = failed == 0
                        ? "\(saved) 枚图标已保存到相册，用快捷指令替换到桌面"
                        : "保存完成：成功 \(saved) 枚，失败 \(failed) 枚"
                }
            } label: {
                Text("导出图标套装")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(context.theme.accent)
                    .clipShape(Capsule())
            }
            .padding(.horizontal)
        }
    }

    private var applyButton: some View {
        Button {
            applyTheme()
        } label: {
            Text("保存壁纸到相册")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(LinearGradient(colors: context.theme.accentGradient,
                                           startPoint: .leading, endPoint: .trailing))
                .clipShape(Capsule())
                .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func applyTheme() {
        guard let first = theme.wallpapers?.first,
              let url = context.content.resourceURL(first),
              let image = UIImage(contentsOfFile: url.path) else {
            saveResult = "该主题暂无壁纸素材"
            return
        }
        PhotoSaver.shared.save(image) { ok in
            saveResult = ok
                ? "「\(theme.name)」壁纸已保存到相册，去系统设置里应用吧"
                : "保存失败，请在系统设置中允许访问相册"
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.title3.bold())
            Spacer()
        }
        .padding(.horizontal)
    }
}

struct PhoneMockView: View {
    let theme: Theme
    private let dockIcons = ["phone.fill", "safari.fill", "message.fill", "music.note"]
    private let gridIcons = ["calendar", "camera.fill", "photo.fill", "clock.fill",
                             "map.fill", "cloud.sun.fill", "heart.fill", "star.fill"]

    var body: some View {
        RoundedRectangle(cornerRadius: 44)
            .fill(.black)
            .overlay {
                ZStack {
                    if let first = theme.wallpapers?.first {
                        GeometryReader { geo in
                            AssetImage(path: first)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 38))
                    } else {
                        RoundedRectangle(cornerRadius: 38)
                            .fill(LinearGradient(colors: theme.colors,
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                    }
                    VStack(spacing: 16) {
                        Capsule()
                            .fill(.black)
                            .frame(width: 100, height: 28)
                            .padding(.top, 16)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                            ForEach(gridIcons, id: \.self) { icon in
                                iconTile(icon)
                            }
                        }
                        Spacer()
                        HStack(spacing: 16) {
                            ForEach(dockIcons, id: \.self) { icon in
                                iconTile(icon)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
                .padding(8)
            }
            .padding(.horizontal, 40)
    }

    private func iconTile(_ name: String) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.white.opacity(0.9))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Image(systemName: name)
                    .foregroundStyle(theme.colors.last ?? .pink)
            }
    }
}
