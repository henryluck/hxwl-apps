import CoreKit
import SwiftUI

/// 智能清理建议页：总可释放空间 + 分类列表 + 一键清理。
public struct CleanSuggestView: View {
    let summary: ScanSummary
    let onOneTapClean: () -> Void
    let onOpenCategory: (CleanKind) -> Void

    @State private var recheck = false

    public init(summary: ScanSummary,
                onOneTapClean: @escaping () -> Void,
                onOpenCategory: @escaping (CleanKind) -> Void) {
        self.summary = summary
        self.onOneTapClean = onOneTapClean
        self.onOpenCategory = onOpenCategory
    }

    private var order: [CleanKind] {
        [.similarPhotos, .similarVideos, .blurredPhotos, .screenshots, .livePhotos]
    }

    public var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        totalCard
                        ForEach(order.filter { summary.count(for: $0) > 0 }, id: \.rawValue) { kind in
                            rowCard(kind)
                        }
                        if summary.totalCleanableCount == 0 {
                            emptyCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 110)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if summary.totalCleanableCount > 0 {
                    CleanPrimaryButton("一键清理\(summary.totalCleanableCount)项（\(ByteFormatter.short(summary.totalCleanableBytes))）") {
                        onOneTapClean()
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.96))
        }
        .navigationTitle("智能清理建议")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CleanPalette.navBarGreen, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
    }

    private var totalCard: some View {
        CleanCard {
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(ByteFormatter.split(summary.totalCleanableBytes).value)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                    Text(ByteFormatter.split(summary.totalCleanableBytes).unit)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                }
                Text("可释放空间")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "9AA09C"))
                Text("基于AI智能分析，为您提供个性化清理建议")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "B8BCC4"))
            }
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity)
        }
    }

    private func rowCard(_ kind: CleanKind) -> some View {
        Button {
            onOpenCategory(kind)
        } label: {
            CleanCard {
                HStack(spacing: 12) {
                    kindIcon(kind)
                    Text(kind.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                    Spacer()
                    Text(ByteFormatter.short(summary.bytes(for: kind)))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "C9CDD4"))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 17)
            }
        }
    }

    private var emptyCard: some View {
        CleanCard {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(CleanPalette.green)
                Text("非常干净，无需清理")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(hex: "1A1A1A"))
            }
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func kindIcon(_ kind: CleanKind) -> some View {
        let bg: Color = {
            switch kind {
            case .similarPhotos: return Color(hex: "4D8DF7")
            case .similarVideos: return Color(hex: "4DA3FF")
            case .blurredPhotos: return CleanPalette.yellow
            case .screenshots: return CleanPalette.green
            case .livePhotos: return Color(hex: "8B7BF7")
            }
        }()
        Image(systemName: kind.symbol)
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(bg))
    }
}

extension Color {
    /// 导航栏浅绿（原型顶部渐变的上沿色）
    static var navBarGreen: Color { Color(hex: "D7F2DF") }
}
