import SwiftUI

/// 常见问题：折叠问答列表。
/// 入参为 view-local `Item` 结构（不含工厂主模块的说明书类型，
/// BaseComponents 是 SwiftPM 包，跨包不可见工厂模块）。
public struct FAQView: View {
    /// 单条问答（由 Task 7 的 SettingsView / 壳层从 spec 映射进来）。
    public struct Item: Identifiable {
        public let id = UUID()
        public let q: String
        public let a: String
        public init(q: String, a: String) { self.q = q; self.a = a }
    }

    let items: [Item]

    @State private var expanded: Set<UUID> = []

    public init(items: [Item]) { self.items = items }

    public var body: some View {
        List {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Button { toggle(item.id) } label: {
                        HStack {
                            Text(item.q).font(.body.bold())
                            Spacer()
                            Image(systemName: expanded.contains(item.id) ? "chevron.down" : "chevron.right")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    if expanded.contains(item.id) {
                        Text(item.a)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("常见问题")
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}
