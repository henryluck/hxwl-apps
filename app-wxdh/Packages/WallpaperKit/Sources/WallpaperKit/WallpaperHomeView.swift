import Capabilities
import SwiftUI

/// 插件主页面：主题浏览（分类筛选 + 网格）
struct WallpaperHomeView: View {
    let context: PluginContext
    @StateObject private var store: WallpaperStore
    @State private var selectedCategory = "全部"

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    init(context: PluginContext) {
        self.context = context
        _store = StateObject(wrappedValue: WallpaperStore(content: context.content))
    }

    private var themes: [Theme] { store.catalog?.themes ?? [] }
    private var categories: [String] { store.catalog?.categories ?? ["全部"] }
    private var filtered: [Theme] {
        selectedCategory == "全部" ? themes : themes.filter { $0.style == selectedCategory }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.catalog != nil {
                    content
                } else if let error = store.error {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    ProgressView("加载主题中…")
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("主题")
        }
        .task { await store.load() }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                categoryBar
                grid
            }
            .padding(.vertical)
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories, id: \.self) { cat in
                    Button {
                        selectedCategory = cat
                    } label: {
                        Text(cat)
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(selectedCategory == cat
                                        ? context.theme.accent
                                        : Color(.secondarySystemGroupedBackground))
                            .foregroundStyle(selectedCategory == cat ? .white : .primary)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(filtered) { theme in
                NavigationLink(value: theme) {
                    ThemeCard(theme: theme)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .navigationDestination(for: Theme.self) { theme in
            WallpaperDetailView(theme: theme, context: context)
        }
    }
}

struct ThemeCard: View {
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ThemeArtwork(theme: theme)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                if theme.isPro {
                    ProBadge().padding(8)
                }
            }
            Text(theme.name).font(.subheadline.bold())
            Text(theme.style).font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
