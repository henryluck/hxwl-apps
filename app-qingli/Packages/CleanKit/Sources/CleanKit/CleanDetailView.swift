import Capabilities
import CoreKit
import Photos
import SwiftUI

/// 清理详情页：相似照片按组（最佳标记）、模糊/截图/Live 网格平铺。
/// 底部主按钮随勾选实时计算「清理N项（释放X）」。
public struct CleanDetailView: View {
    let kind: CleanKind
    // 改为可变 @State 绑定：清理后 removeAssets 直接更新本地 summary，
    // 页面网格/候选列表立即刷新（修复问题2：第二次删除无反应 + 问题1：首页不同步）
    @State private var localSummary: ScanSummary
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
        self._localSummary = State(initialValue: summary)
        self.onCleaned = onCleaned
        self.pay = pay
    }

    private var groups: [CleanGroup] { localSummary.groups(for: kind) }
    private var isSimilar: Bool { kind == .similarPhotos || kind == .similarVideos }

    /// 可清理候选：相似页 = 全部资产（row57：最佳也可手动选中清理）；
    /// 其他页（模糊/截图/Live）无最佳概念，直接全部。
    /// 全选（toolbar「全选」/组卡「全选」）仍然只圈非最佳——最佳默认保留，
    /// 只有用户手动点击最佳格才把它加进 selected。
    private var candidates: [CleanAsset] {
        groups.flatMap { $0.assets }
    }

    /// 非最佳候选（全选/组全选的圈选范围）
    private var nonBestCandidates: [CleanAsset] {
        candidates.filter { !$0.isBest }
    }

    private var selectedAssets: [CleanAsset] {
        candidates.filter { selected.contains($0.id) }
    }
    private var selectedBytes: Int64 { selectedAssets.reduce(0) { $0 + $1.byteCount } }

    /// 全选态按「非最佳」判定：全选只圈非最佳，手动选了最佳不影响全选开关显示
    private var allSelected: Bool {
        !nonBestCandidates.isEmpty && nonBestCandidates.allSatisfy { selected.contains($0.id) }
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
                            // row57：全选只圈非最佳（默认保留最佳），手动已选的最佳保留
                            selected = Set(nonBestCandidates.map { $0.id })
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
            // 需求5：未访问/受限访问时按钮上下浮动 → 外层固定高度容器（scroll 边界抖动
            // 不再传给按钮；VStack 内 Spacer 吸底保证按钮永远贴在原位置）
            if !showResult {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    // row55：动转静态页在按钮下方的操作栏里显示「已选 N 张」
                    if kind == .livePhotos {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(CleanPalette.green)
                            Text("已选 \(selectedAssets.count) 张")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(hex: "6B7078"))
                            Spacer()
                            if selectedBytes > 0 {
                                Text("预计可省 \(ByteFormatter.short(selectedBytes))")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(hex: "9AA09C"))
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 6)
                    }
                    CleanPrimaryButton(buttonTitle, enabled: !cleaning && !selectedAssets.isEmpty) { performClean() }
                        .accessibilityIdentifier("detail.primaryAction")
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 12)
                .frame(height: kind == .livePhotos ? 98 : 76)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.96))
            }
        }
        // Bug表r27：删除被拒（点「不允许」）→ 静默留在当页，移除「无法清理」alert
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

    /// 相似照片/视频：
    /// 需求：每一组相似图片放到一个单独的日期组卡片里——
    /// 每张卡 = 一个日期头（日期 + 汇总 + 全选该组）+ 该组一行横向滑动缩略图。
    /// 性能：用 LazyVStack 而非 VStack —— 相似照片候选上百项时分出几十组，
    /// VStack 会一次性创建全部 groupCard（每个含 LazyHStack + 多个 AssetThumb），
    /// 主线程长时间忙 → XCUITest 等不到 app idle → 超时 kill。
    /// LazyVStack 只渲染可见区域，滚动到再创建。
    private var similarList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                ForEach(groups) { group in
                    groupCard(group)
                }
                if groups.isEmpty {
                    emptyHint
                }
            }
            // 尾部留白放在滚动内容内：既能完整滚出最后一行，又不压缩视口高度
            .padding(.bottom, 16)
        }
    }

    /// 单组卡：标题行（日期 + 汇总 + 全选该组）→ 该组一行横向滑动缩略图
    private func groupCard(_ group: CleanGroup) -> some View {
        let groupCandidates = group.assets.filter { !$0.isBest }
        let groupAllSelected = !groupCandidates.isEmpty && groupCandidates.allSatisfy { selected.contains($0.id) }
        let assetCount = group.assets.count
        return CleanCard {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(dateHeader(group))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                    Text("\(assetCount)项 · \(ByteFormatter.short(group.cleanableBytes))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "9AA09C"))
                    Spacer()
                    Button {
                        if groupAllSelected {
                            for a in groupCandidates { selected.remove(a.id) }
                        } else {
                            for a in groupCandidates { selected.insert(a.id) }
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
                // 该组一行：★最佳 + 其余照片横向滑动（Bug表R9-3）
                groupRow(group)
            }
            .padding(12)
        }
        // 可测锚点：组内资产总数 + 可清理数编码进 identifier，
        // 供 UI 测试断言「清理后组数据即时刷新」
        .accessibilityIdentifier("detail.group.\(group.id).a\(assetCount)c\(groupCandidates.count)")
    }

    /// 组内一行：最佳大格 + 其余小格横向滑动
    /// 问题6修复：横向照片（宽>高）时固定方形会裁切+重叠。
    /// 改为自适应宽度：保留照片原始宽高比，高度统一 110pt，宽度按比例计算。
    /// 勾选 badge 固定在每格右上角，不受内容裁切影响。
    private func groupRow(_ group: CleanGroup) -> some View {
        let best = group.assets.first { $0.isBest }
        let rest = group.assets.filter { !$0.isBest }
        return HStack(spacing: 8) {
            if let best {
                bestCell(best)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(rest) { asset in
                        thumbCell(asset)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func bestCell(_ asset: CleanAsset) -> some View {
        // 问题3/6修复：保留照片原始宽高比，高度固定 130pt，宽度按比例计算。
        // 横向照片（宽>高）不会被裁切，竖向照片也不会被拉伸。
        // 问题4修复：最佳标签不带勾选符号（纯文字）。
        // 视觉修复：「最佳」标签改为叠在图片**左上角**且自带实心底衬，
        // 不再半透明压在照片内容上导致文字与截图内容混在一起。
        // row57：最佳也带单选框，支持手动选中（用户判断「最佳」未必想保留的那张）；
        // 批量全选不包含最佳（groupCard/allSelected 只圈非最佳），只有手动点才选上。
        let isSelected = selected.contains(asset.id)
        let ratio = asset.pixelHeight > 0
            ? CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
            : 1.0
        let cellHeight: CGFloat = 130
        let cellWidth = max(80, min(200, cellHeight * ratio))
        return Button {
            withAnimation(.easeIn(duration: 0.12)) {
                if isSelected { selected.remove(asset.id) } else { selected.insert(asset.id) }
            }
        } label: {
            ZStack(alignment: .topLeading) {
                AssetThumb(assetID: asset.id, aspectRatio: ratio,
                           badge: AnyView(SelectBadge(selected: isSelected)
                                .frame(width: 20, height: 20)
                                .padding(6)
                                .frame(width: cellWidth, height: cellHeight, alignment: .topTrailing)))
                    .frame(width: cellWidth, height: cellHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                // 最佳标签（纯文字，无勾选符号，左上角）
                Text("最佳")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(CleanPalette.green))
                    .padding(6)
            }
            .frame(width: cellWidth, height: cellHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? CleanPalette.green : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("detail.best.\(asset.id)")
    }

    private func thumbCell(_ asset: CleanAsset) -> some View {
        let isSelected = selected.contains(asset.id)
        // 问题3/6修复：保留照片原始宽高比，高度固定 110pt，宽度按比例计算。
        // 截图/录屏等横向内容不会被裁切，勾选 badge 始终完整显示在右上角。
        let ratio = asset.pixelHeight > 0
            ? CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
            : 1.0
        let cellHeight: CGFloat = 110
        let cellWidth = max(70, min(180, cellHeight * ratio))
        return Button {
            // row52 修复：勾选切换包 withAnimation，点击反馈立即渲染。
            // 无动画时 SwiftUI 直接进入事务合并窗口，网格缩略图加载期间的
            // 状态变更可能被攒到下一帧批量处理，视觉上「点了过一会才选中」。
            withAnimation(.easeIn(duration: 0.12)) {
                if isSelected { selected.remove(asset.id) } else { selected.insert(asset.id) }
            }
        } label: {
            // 问题3修复：勾选 badge 走 AssetThumb 的 badge 插槽，
            // 在 GeometryReader 内部精确定位，保证圆点完整显示在格内右上角
            // （之前用外层 overlay 时圆点会溢出到图片外）。
            AssetThumb(assetID: asset.id, isVideo: asset.mediaType == .video, aspectRatio: ratio,
                       badge: AnyView(SelectBadge(selected: isSelected)
                            .frame(width: 20, height: 20)
                            .padding(6)
                            .frame(width: cellWidth, height: cellHeight, alignment: .topTrailing)))
                .frame(width: cellWidth, height: cellHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? CleanPalette.green : .clear, lineWidth: 2)
                )
                .frame(width: cellWidth, height: cellHeight)
        }
        .buttonStyle(.plain)
    }

    /// 模糊/截图/Live：平铺网格
    /// row53/54 修复：横拍照片在网格里重叠、勾选符号被覆盖。
    /// 根因：LazyVGrid 的 adaptive 列宽由最小值决定（≈80~110pt），而 thumbCell
    /// 显式 frame 宽度按比例算（横图可达 180pt）→ cell 溢出列宽压到相邻列上。
    /// 修复：网格单元不做比例宽度——固定占满整列宽（frame(maxWidth:.infinity)），
    /// AssetThumb 内部 aspectRatio>0 用 scaledToFit 完整显示横图，勾选 badge
    /// 由 AssetThumb 的 GeometryReader 精确定位在格内右上角，不再溢出。
    /// row6 同源：此前横图被方形格裁切后视觉上「像 1:1」，现在按比例完整显示。
    private var flatGrid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                      spacing: 8) {
                ForEach(candidates) { asset in
                    gridCell(asset)
                }
            }
            .padding(.bottom, 16)
            if candidates.isEmpty {
                emptyHint.padding(.top, 60)
            }
        }
    }

    /// 网格单元（row53/54 专用）：宽度永远等于列宽，高度跟随列宽（方形格），
    /// 横图在格内 scaledToFit 完整显示（上下留白，不裁切不重叠）。
    private func gridCell(_ asset: CleanAsset) -> some View {
        let isSelected = selected.contains(asset.id)
        return Button {
            withAnimation(.easeIn(duration: 0.12)) {
                if isSelected { selected.remove(asset.id) } else { selected.insert(asset.id) }
            }
        } label: {
            AssetThumb(assetID: asset.id, isVideo: asset.mediaType == .video,
                       aspectRatio: 0,   // 网格固定方形格；横图由 Thumb 内部 fit 显示
                       badge: AnyView(SelectBadge(selected: isSelected)
                            .frame(width: 20, height: 20)
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)))
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? CleanPalette.green : .clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("detail.cell.\(asset.id)")
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
        // 需求2（二次删除无反应）：成功页「继续清理」走 onCleaned()+dismiss 整页重建；
        // 但如果用户从成功页左上角返回（不触发重建），summary 仍含已删资产 →
        // 勾选还在旧资产上、再点清理时 fetch 不到资产 → guard 拦下没反应。
        // 修复：清理完成时立即从本地 summary 移除已删资产 + 清空勾选，
        // 页面数据（groups→candidates）随之刷新，第二次清理照常走通。
        let targets = selectedAssets
        guard !targets.isEmpty else { return }
        cleaning = true
        let targetIDs = Set(targets.map { $0.id })
        let work: ([CleanAsset], @escaping @MainActor (CleanExecutor.Result) -> Void) -> Void =
            kind == .livePhotos ? CleanExecutor.shared.convertLiveToStatic : CleanExecutor.shared.clean
        work(targets) { r in
            cleaning = false
            // Bug表r27：系统删除确认框点「不允许」→ 事务回滚，直接留在当页即可，
            // 不再弹「无法清理」提示弹窗（用户主动拒绝，无需打扰）。
            // 选中状态保留（回滚后资产仍在），用户可继续勾选或换别的清理。
            guard r.movedCount > 0 else { return }
            removeAssets(ids: targetIDs)
            selected.removeAll()
            result = r
            withAnimation(.easeInOut(duration: 0.25)) { showResult = true }
        }
    }

    /// 从本地 summary 中移除指定资产（无需等待重扫，网格/统计立即同步）
    /// 修复问题1/2：同时更新 localSummary（页面数据源）和 CleanCenter（全局）
    private func removeAssets(ids: Set<String>) {
        let kept = localSummary.groups(for: kind).compactMap { group -> CleanGroup? in
            let remaining = group.assets.filter { !ids.contains($0.id) }
            guard !remaining.isEmpty else { return nil }
            return CleanGroup(id: group.id, kind: group.kind, assets: remaining)
        }
        localSummary.groups[kind] = kept
        // 同步到全局：首页 onAppear 时检测到变化即刷新
        CleanCenter.shared.summary = localSummary
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
