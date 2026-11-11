import CoreKit
import SwiftUI

// MARK: - 原型版底部 TabBar（Figma《个人中心-包含底部tab菜单》还原）
//
// 白底 85pt、无系统毛玻璃；三个 Tab：首页(房子线稿)/百宝箱(箱子线稿)/个人中心(人形线稿)。
// 未选中灰 #8E959D；选中：图标+文字绿色(#3DA24E)且外面包一个浅绿圆角胶囊（原型选中项高亮）。
// 图标优先读打包原型图（assets/proto/tab_home.png 等），缺失回退 SF Symbol。

struct ProtoTabBar: View {
    @Binding var selected: String?
    let tabs: [(id: String?, title: String, icon: String?)]
    let accent: Color

    private let unselectedGray = Color(hex: "8E959D")

    init(selected: Binding<String?>, tabs: [(id: String?, title: String, icon: String?)],
         accent: Color) {
        _selected = selected
        self.tabs = tabs
        self.accent = accent
        // 组件内使用（BaseComponents 包内同名协议不同），这里只做颜色桥接
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                button(for: tab)
            }
        }
        .frame(height: 56)
        .padding(.top, 10)
        .background(
            Color.white
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: .black.opacity(0.04), radius: 0.5, y: -0.5)
        )
    }

    private func button(for tab: (id: String?, title: String, icon: String?)) -> some View {
        let isSelected = selected == tab.id || (selected == nil && tab.id == tabs.first?.id)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selected = tab.id
            }
        } label: {
            VStack(spacing: 3) {
                iconView(for: tab, selected: isSelected)
                    .frame(height: 26)
                Text(tab.title)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color(hex: "3DA24E") : unselectedGray)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    // 选中浅绿胶囊（原型高亮底）
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(hex: "EAF7EC"))
                }
            }
            .padding(.horizontal, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab.\(tab.title)")
    }

    @ViewBuilder
    private func iconView(for tab: (id: String?, title: String, icon: String?), selected: Bool) -> some View {
        let assetName = assetName(for: tab.title)
        if let url = Bundle.main.resourceURL?.appendingPathComponent("assets/proto/\(assetName).png"),
           let img = UIImage(contentsOfFile: url.path) {
            // 原型自绘图标：未选中为灰线稿，选中变绿（模板渲染染色）
            Image(uiImage: recolored(img, to: selected ? Color(hex: "3DA24E") : unselectedGray))
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: tab.icon ?? "circle")
                .font(.system(size: 20))
                .foregroundStyle(selected ? Color(hex: "3DA24E") : unselectedGray)
        }
    }

    private func assetName(for title: String) -> String {
        switch title {
        case "首页": return "tab_home"
        case "百宝箱": return "tab_toolbox"
        default: return "tab_profile"
        }
    }

    /// 把不透明线稿 PNG 整体染成目标色（保留 alpha）
    private func recolored(_ image: UIImage, to color: Color) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let size = CGSize(width: cg.width, height: cg.height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiColor = UIColor(color)
        return renderer.image { _ in
            uiColor.setFill()
            let ctx = UIGraphicsGetCurrentContext()
            ctx?.translateBy(x: 0, y: size.height)
            ctx?.scaleBy(x: 1, y: -1)
            ctx?.clip(to: CGRect(origin: .zero, size: size), mask: cg)
            ctx?.fill(CGRect(origin: .zero, size: size))
        }
    }
}
