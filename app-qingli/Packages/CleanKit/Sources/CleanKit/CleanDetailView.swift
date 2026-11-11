import CoreKit
import Photos
import SwiftUI

/// 清理详情页：相似照片按组（最佳标记）、模糊/截图/Live 网格平铺。
/// 底部主按钮随勾选实时计算「清理N项（释放X）」。
public struct CleanDetailView: View {
    let kind: CleanKind
    let summary: ScanSummary
    let onCleaned: () -> Void          // 清理完成回调（刷新扫描结果）

    @State private var selected: Set<String> = []
    @State private var groupSelection: [String: Bool] = [:]   // 组级全选（相似照片组勾选）
    @State private var cleaning = false
    @State private var result: CleanExecutor.Result?
    @State private var showResult = false
    @Environment(\.dismiss) private var dismiss

    public init(kind: CleanKind, summary: ScanSummary, onCleaned: @escaping () -> Void) {
        self.kind = kind
        self.summary = summary
        self.onCleaned = onCleaned
    }

    private var groups: [CleanGroup] { summary.groups(for: kind) }
    private var isSimilar: Bool { kind == .similarPhotos || kind == .similarVideos }

    /// 可清理候选（非最佳）
    private var candidates: [CleanAsset] {
        groups.flatMap { $0.assets.filter { !$0.isBest } }
    }

    private var selectedAssets: [CleanAsset] {
        candidates.filter { selected.contains($0.id) }
    }
    private var selectedBytes: Int64 { selectedAssets.reduce(0) { $0 + $1.byteCount } }

    private var allSelected: Bool {
        !candidates.isEmpty && selected.count == candidates.count
    }

    private var buttonTitle: String {
        if selectedAssets.isEmpty {
            return kind == .livePhotos ? "转为静态" : "清理"
        }
        if kind == .livePhotos {
            let n = selectedAssets.count
            let unit = n > 1 ? "张" : "1张"
            return "\(n)\(unit)转为静态（可省\(ByteFormatter.short(selectedBytes))）"
        }
        return "清理\(selectedAssets.count)项（释放\(ByteFormatter.short(selectedBytes))）"
    }

    public var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            if let r = result, showResult {
                successView(r)
            } else {
                gridContent
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CleanPalette.navBarGreen, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .toolbar {
            if !showResult {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(allSelected ? "取消全选" : "全选") {
                        if allSelected {
                            selected.removeAll()
                        } else {
                            selected = Set(candidates.map { $0.id })
                        }
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // 清理成功页自带「继续清理」按钮，不再显示底部主按钮
            if !showResult {
                CleanPrimaryButton(buttonTitle, enabled: !cleaning && !selectedAssets.isEmpty) { performClean() }
                    .accessibilityIdentifier("detail.primaryAction")
                    .padding(.horizontal, 40)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.96))
            }
        }
    }

    // MARK: - 网格内容

    private var gridContent: some View {
        Group {
            if isSimilar {
                similarList
            } else {
                flatGrid
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 100)
    }

    /// 相似照片/视频：按组卡片（组长「★最佳」，组内勾选）
    private var similarList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                ForEach(groups) { group in
                    groupCard(group)
                }
                if groups.isEmpty {
                    emptyHint
                }
            }
            .padding(.bottom, 10)
        }
    }

    private func groupCard(_ group: CleanGroup) -> some View {
        let best = group.assets.first { $0.isBest }
        let rest = group.assets.filter { !$0.isBest }
        let groupAllSelected = !rest.isEmpty && rest.allSatisfy { selected.contains($0.id) }
        return CleanCard {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(dateHeader(group))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                    Text("\(group.assets.count)项 · \(ByteFormatter.short(group.cleanableBytes))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "9AA09C"))
                    Spacer()
                    Button {
                        if groupAllSelected {
                            for a in rest { selected.remove(a.id) }
                        } else {
                            for a in rest { selected.insert(a.id) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            SelectBadge(selected: groupAllSelected)
                            Text(groupAllSelected ? "取消全选" : "全选")
                                .font(.system(size: 13))
                                .foregroundStyle(Color(hex: "6B7078"))
                        }
                    }
                }
                // 网格：最佳占大格，其余小格
                HStack(spacing: 8) {
                    if let best {
                        bestCell(best)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                              spacing: 8) {
                        ForEach(rest) { asset in
                            thumbCell(asset)
                        }
                    }
                }
                .frame(height: 150)
            }
            .padding(12)
        }
    }

    private func bestCell(_ asset: CleanAsset) -> some View {
        ZStack(alignment: .topLeading) {
            AssetThumb(assetID: asset.id)
                .frame(width: 120, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("★ 最佳")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(hex: "6B7078").opacity(0.85)))
                .padding(6)
        }
    }

    private func thumbCell(_ asset: CleanAsset) -> some View {
        let isSelected = selected.contains(asset.id)
        return Button {
            if isSelected { selected.remove(asset.id) } else { selected.insert(asset.id) }
        } label: {
            ZStack(alignment: .topTrailing) {
                AssetThumb(assetID: asset.id, isVideo: asset.mediaType == .video)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                SelectBadge(selected: isSelected)
                    .padding(5)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? CleanPalette.green : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    /// 模糊/截图/Live：平铺网格
    private var flatGrid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                      spacing: 10) {
                ForEach(candidates) { asset in
                    thumbCell(asset)
                    .aspectRatio(0.78, contentMode: .fit)
                }
            }
            .padding(.bottom, 10)
            if candidates.isEmpty {
                emptyHint.padding(.top, 60)
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 38))
                .foregroundStyle(CleanPalette.green)
            Text("没有发现可清理项")
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "6B7078"))
        }
        .frame(maxWidth: .infinity)
    }

    private func dateHeader(_ group: CleanGroup) -> String {
        let date = group.assets.compactMap { $0.creationDate }.first ?? Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "MM月dd日"
        return fmt.string(from: date)
    }

    // MARK: - 清理动作

    private func performClean() {
        guard !cleaning else { return }
        let targets = selectedAssets
        guard !targets.isEmpty else { return }
        cleaning = true
        let work: ([CleanAsset], @escaping @MainActor (CleanExecutor.Result) -> Void) -> Void =
            kind == .livePhotos ? CleanExecutor.shared.convertLiveToStatic : CleanExecutor.shared.clean
        work(targets) { r in
            cleaning = false
            result = r
            withAnimation(.easeInOut(duration: 0.25)) { showResult = true }
        }
    }

    // MARK: - 成功页

    private func successView(_ r: CleanExecutor.Result) -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 90)
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 62))
                    .foregroundStyle(CleanPalette.green)
                Text(kind == .livePhotos ? "转换完成" : "清理成功")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                Text("空间已腾出 相册更简洁")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "9AA09C"))
            }
            Spacer().frame(height: 36)
            CleanCard {
                HStack(spacing: 0) {
                    VStack(spacing: 6) {
                        Text("\(r.movedCount)")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(Color(hex: "1A1A1A"))
                        Text("清理数量")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "9AA09C"))
                    }
                    .frame(maxWidth: .infinity)
                    Rectangle().fill(Color(hex: "EEF0F2")).frame(width: 1, height: 40)
                    VStack(spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text(ByteFormatter.split(r.freedBytes).value)
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(Color(hex: "1A1A1A"))
                            Text(ByteFormatter.split(r.freedBytes).unit)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(hex: "1A1A1A"))
                        }
                        Text("节省空间")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "9AA09C"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 22)
            }
            .padding(.horizontal, 16)
            Spacer()
            CleanPrimaryButton("继续清理") {
                onCleaned()
                dismiss()
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
        }
    }
}
