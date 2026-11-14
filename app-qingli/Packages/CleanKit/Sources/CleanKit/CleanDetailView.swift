import Capabilities
import CoreKit
import Photos
import SwiftUI

/// 清理详情页：相似照片按组（最佳标记）、模糊/截图/Live 网格平铺。
/// 底部主按钮随勾选实时计算「清理N项（释放X）」。
public struct CleanDetailView: View {
    let kind: CleanKind
    let summary: ScanSummary
    let onCleaned: () -> Void          // 清理完成回调（刷新扫描结果）
    /// 订阅门：未订阅点「清理N项/转为静态」→ 弹订阅页（需求：核心功能拉订阅）
    var pay: (any PayService)? = nil

    @State private var selected: Set<String> = []
    @State private var groupSelection: [String: Bool] = [:]   // 组级全选（相似照片组勾选）
    @State private var cleaning = false
    @State private var result: CleanExecutor.Result?
    @State private var showResult = false
    @Environment(\.dismiss) private var dismiss

    public init(kind: CleanKind, summary: ScanSummary, onCleaned: @escaping () -> Void,
                pay: (any PayService)? = nil) {
        self.kind = kind
        self.summary = summary
        self.onCleaned = onCleaned
        self.pay = pay
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
            // 清理成功页自带「继续清理」按钮，不再显示底部主按钮。
            // 整个修饰（含白底）都放在条件内：否则成功页底部会残留一条 24pt 白条。
            if !showResult {
                CleanPrimaryButton(buttonTitle, enabled: !cleaning && !selectedAssets.isEmpty) { performClean() }
                    .accessibilityIdentifier("detail.primaryAction")
                    .padding(.horizontal, 40)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.96))
            }
        }
        .alert("无法清理", isPresented: $cleanFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text("相册权限被拒绝，无法完成清理。请在系统设置中允许完整访问后重试。")
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
        // 不要再在这里加底部外边距：
        // R10 时为躲常驻 TabBar 加过 140pt，但 R10 修复后二级页已隐藏 TabBar，
        // 且 safeAreaInset 已为底部按钮预留安全区。外层 padding 会把 ScrollView
        // 视口压矮（实测 874pt 屏只剩 492pt，底边 616pt，距按钮栏还空 148pt），
        // 形成下半屏图片永远填不上的空白带。列表所需的尾部间距改放在滚动内容里。
    }

    /// 相似照片/视频（Bug表R9-2/9-3）：
    /// 按天分模板展示——同一天的所有组合并到一个「日期」模板区块内，
    /// 区块内每组一行（横向左右滑动查看多张），不再每天重复多个卡片头。
    private var similarList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                ForEach(daySections, id: \.key) { section in
                    dayCard(section)
                }
                if groups.isEmpty {
                    emptyHint
                }
            }
            // 尾部留白放在滚动内容内：既能完整滚出最后一行，又不压缩视口高度
            .padding(.bottom, 16)
        }
    }

    /// 按天聚合的组区块
    private struct DaySection: Identifiable {
        let key: String          // 「MM月dd日」
        let groups: [CleanGroup]
        var id: String { key }
    }

    private var daySections: [DaySection] {
        var order: [String] = []
        var bucket: [String: [CleanGroup]] = [:]
        for g in groups {
            let key = dateHeader(g)
            if bucket[key] == nil { order.append(key) }
            bucket[key, default: []].append(g)
        }
        return order.map { DaySection(key: $0, groups: bucket[$0] ?? []) }
    }

    /// 单天模板卡：标题行（日期 + 汇总 + 全选该天）→ 每组一行横向滑动缩略图
    private func dayCard(_ section: DaySection) -> some View {
        let dayAssets = section.groups.flatMap { $0.assets.filter { !$0.isBest } }
        let dayAllSelected = !dayAssets.isEmpty && dayAssets.allSatisfy { selected.contains($0.id) }
        let dayBytes = section.groups.reduce(Int64(0)) { $0 + $1.cleanableBytes }
        let dayCount = section.groups.reduce(0) { $0 + $1.assets.count }
        return CleanCard {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(section.key)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                    Text("\(dayCount)项 · \(ByteFormatter.short(dayBytes))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "9AA09C"))
                    Spacer()
                    Button {
                        if dayAllSelected {
                            for a in dayAssets { selected.remove(a.id) }
                        } else {
                            for a in dayAssets { selected.insert(a.id) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            SelectBadge(selected: dayAllSelected)
                            Text(dayAllSelected ? "取消全选" : "全选")
                                .font(.system(size: 13))
                                .foregroundStyle(Color(hex: "6B7078"))
                        }
                    }
                }
                // 每组一行：★最佳 + 其余照片横向滑动（Bug表R9-3）
                ForEach(section.groups) { group in
                    groupRow(group)
                }
            }
            .padding(12)
        }
    }

    /// 组内一行：最佳大格 + 其余小格横向滑动
    private func groupRow(_ group: CleanGroup) -> some View {
        let best = group.assets.first { $0.isBest }
        let rest = group.assets.filter { !$0.isBest }
        return HStack(spacing: 8) {
            if let best {
                bestCell(best)
            }
            // Bug表R9-3：多张照片左右滑动查看
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(rest) { asset in
                        thumbCell(asset)
                            .frame(width: 88, height: 110)
                    }
                }
                .padding(.vertical, 1)
            }
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
                // Bug表R9-1：约束并裁切，照片内容不再超出范围
                AssetThumb(assetID: asset.id, isVideo: asset.mediaType == .video)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
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
                    // Bug表R6：模糊照片/截图清理图片比例改为 1:1（原 0.78 竖长条）
                    .aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(.bottom, 16)
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
        // 订阅门：未订阅拉起订阅页，不放行清理/转换
        guard !CoreFeatureGate.gate(pay) else { return }
        guard !cleaning else { return }
        let targets = selectedAssets
        guard !targets.isEmpty else { return }
        cleaning = true
        let work: ([CleanAsset], @escaping @MainActor (CleanExecutor.Result) -> Void) -> Void =
            kind == .livePhotos ? CleanExecutor.shared.convertLiveToStatic : CleanExecutor.shared.clean
        work(targets) { r in
            cleaning = false
            // Bug表R9-4：系统弹窗点了「不允许」（权限被拒）→ 全部失败时留在当页，
            // 弹出失败提示；不进入清理成功页（否则用户误以为照片被删）。
            if r.movedCount == 0 {
                cleaning = false
                cleanFailed = true
                return
            }
            result = r
            withAnimation(.easeInOut(duration: 0.25)) { showResult = true }
        }
    }

    @State private var cleanFailed = false

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
