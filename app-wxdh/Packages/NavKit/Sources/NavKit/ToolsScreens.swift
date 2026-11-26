import CoreLocation
import CoreKit
import PhotosUI
import SwiftUI

// MARK: - 常用地点（规则 v0.31.1 §3：无类别、重复拦截、去导航走真实检索）

/// 常用地点：本机管理免费，去导航为会员；名称只是标题，不代替地址或坐标
struct SavedPlacesScreen: View {
    @ObservedObject var model: NavAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: NavStores.SavedPlace?
    @State private var showEditor = false
    @State private var deleteTarget: NavStores.SavedPlace?
    @State private var deleteFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if model.stores.savedPlaces.isEmpty {
                    // 【U-025】初装为空列表，不预置示例、不选类别
                    NavEmptyView(title: "还没有常用地点",
                                 detail: "添加常用地址，导航时可直接带入检索")
                } else {
                    List {
                        ForEach(model.stores.savedPlaces) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                // 【R-072】不再展示类别胶囊
                                Text(item.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(NavTheme.ink)
                                Text(item.address)
                                    .font(.system(size: 13))
                                    .foregroundStyle(NavTheme.inkMute)
                                    .lineLimit(2)
                                HStack(spacing: 14) {
                                    Button("去导航") {
                                        guard model.requireMembership() else { return }
                                        // 【U-032】地址作为检索词回显搜索框，经真实 POI 确认，
                                        // 不把保存的 place 对象直接当已选目的地（名称不是 POI ID）
                                        model.openSearch(target: .destination, preset: item.address)
                                        dismiss()
                                    }
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(NavTheme.accent)

                                    Button("编辑") {
                                        editing = item
                                        showEditor = true
                                    }
                                    .font(.system(size: 13))
                                    .foregroundStyle(NavTheme.inkSoft)

                                    Button("删除") {
                                        deleteTarget = item
                                    }
                                    .font(.system(size: 13))
                                    .foregroundStyle(NavTheme.bad)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("常用地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        editing = nil
                        showEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showEditor) {
                SavedPlaceEditor(model: model, editing: editing)
            }
            .alert("删除这条常用地点？", isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } })) {
                Button("删除", role: .destructive) {
                    // 【U-031】确认且持久化成功才消失；失败保留并提示；按 ID 定点删不误删相邻
                    if let target = deleteTarget {
                        if !model.stores.deleteSaved(id: target.id) {
                            deleteFailed = true
                        }
                    }
                    deleteTarget = nil
                }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: {
                Text(deleteTarget?.name ?? "")
            }
            .alert("删除失败", isPresented: $deleteFailed) {
                Button("好", role: .cancel) {}
            } message: {
                Text("记录未能删除，已保留，请重试。")
            }
        }
    }
}

private struct SavedPlaceEditor: View {
    @ObservedObject var model: NavAppModel
    let editing: NavStores.SavedPlace?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var nameLimitHit = false
    @State private var addressLimitHit = false
    @State private var duplicateHint = false
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("地点名称（最多 30 字）", text: $name)
                        .onChange(of: name) { value in
                            // 【U-027】超限显式提示，不静默截断保存；换行/控制字符不得进入单行
                            if value.count > 30 {
                                name = String(value.prefix(30))
                                nameLimitHit = true
                            }
                            name = name.replacingOccurrences(of: "\n", with: "")
                                .replacingOccurrences(of: "\r", with: "")
                                .replacingOccurrences(of: "\t", with: "")
                        }
                    if nameLimitHit {
                        Text("名称最多 30 字")
                            .font(.system(size: 12))
                            .foregroundStyle(NavTheme.bad)
                    }
                } header: {
                    Text("名称")
                }
                Section {
                    TextField("地址（最多 120 字）", text: $address, axis: .vertical)
                        .lineLimit(2...3)
                        .onChange(of: address) { value in
                            if value.count > 120 {
                                address = String(value.prefix(120))
                                addressLimitHit = true
                            }
                            address = address.replacingOccurrences(of: "\r", with: "")
                                .replacingOccurrences(of: "\t", with: "")
                        }
                    if addressLimitHit {
                        Text("地址最多 120 字")
                            .font(.system(size: 12))
                            .foregroundStyle(NavTheme.bad)
                    }
                } header: {
                    Text("地址")
                }
                Section {
                    Text("名称与地址均必填；保存后可从「去导航」用地址检索真实地点。")
                        .font(.system(size: 12))
                        .foregroundStyle(NavTheme.inkMute)
                }
            }
            .navigationTitle(editing == nil ? "新增常用地点" : "编辑常用地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }   // 【U-029】取消保留旧值，不写入草稿
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!isValid)
                }
            }
            .alert("该地点已保存", isPresented: $duplicateHint) {
                Button("好", role: .cancel) {}
            } message: {
                Text("相同名称与地址的地点已存在。")
            }
            .alert("保存失败", isPresented: $saveFailed) {
                Button("好", role: .cancel) {}
            } message: {
                Text("未能保存（可能存储空间不足），表单内容已保留，请重试。")
            }
            .onAppear {
                // 【规则 §3.1】编辑回填原值（旧 category 忽略）
                if let editing {
                    name = editing.name
                    address = editing.address
                }
            }
        }
    }

    /// 两字段必填（首尾空白去除后非空、非全空格）
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        guard isValid else { return }
        let item = NavStores.SavedPlace(
            id: editing?.id ?? UUID().uuidString,   // 编辑保持原 ID；UUID 避免同毫秒冲突
            name: name.trimmingCharacters(in: .whitespaces),
            address: address.trimmingCharacters(in: .whitespaces),
            category: nil,
            place: editing?.place,
            createdAt: editing?.createdAt ?? Date())
        switch model.stores.upsertSavedChecked(item) {
        case .success:
            dismiss()
        case .duplicate:
            duplicateHint = true       // 【U-028】不创建重复记录
        case .invalid:
            saveFailed = true          // 保留表单，不虚报成功
        }
    }
}

// MARK: - 出行工具

/// 出行工具：地址整理（客户端文本规则）+ 停车便签（本机，照片不上传）
struct TravelToolsScreen: View {
    @ObservedObject var model: NavAppModel
    @Environment(\.dismiss) private var dismiss
    /// 【R-073-02】初始路由：首页停车卡直达详情（nil = 默认工具列表）
    var initialRoute: Route?

    enum Route: Hashable { case parkingNote, addressParser }
    @State private var path: [Route] = []
    @State private var showSavedPlaces = false

    var body: some View {
        NavigationStack(path: $path) {
            // 【v0.32 原型对齐】出行工具页 = 常用地点入口行 + 工具双入口 + 我的停车记录卡/空态
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 常用地点入口行（原型 v13-saved-link：图标+标题+箭头）
                    Button {
                        showSavedPlaces = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "bookmark")
                                .font(.system(size: 21))
                                .foregroundStyle(NavTheme.accentDeep)
                            Text("常用地点")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(NavTheme.ink)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(NavTheme.inkMute)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 56)
                        .frame(maxWidth: .infinity)
                        .navCard()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("常用地点，点按查看")

                    parkingToolsCard
                }
                .padding(16)
            }
            .background(NavTheme.bg)
            .navigationTitle("出行工具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .addressParser: AddressParserView(model: model)
                case .parkingNote: ParkingNoteView(model: model)
                }
            }
            // 【R-073-02】首页停车卡进入 → 直达详情；用户仍可返回工具列表
            .onAppear {
                if initialRoute == .parkingNote, path.isEmpty {
                    path = [.parkingNote]
                }
            }
            .sheet(isPresented: $showSavedPlaces) {
                SavedPlacesScreen(model: model)
            }
        }
    }

    // MARK: - 停车工具卡（原型 parking-tool-row + 我的停车记录 + 空态）

    private var parkingToolsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 双工具入口行（地址整理 / 停车便签）
            HStack(spacing: 10) {
                toolEntry(icon: "text.alignleft", title: "地址整理") {
                    path.append(.addressParser)
                }
                toolEntry(icon: "parkingsign.circle", title: "停车便签") {
                    path.append(.parkingNote)
                }
            }

            // 我的停车记录（R-073：无论是否找到车，有记录即显示；开关控制的是首页而非此处）
            HStack {
                Text("我的停车记录")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NavTheme.inkSoft)
                Spacer()
                if model.stores.parking != nil {
                    Text("已保存在本机")
                        .font(.system(size: 11))
                        .foregroundStyle(NavTheme.inkMute)
                }
            }
            .padding(.top, 2)

            if let saved = model.stores.parking {
                parkingRecordCard(saved)
            } else {
                parkingEmptyCard
            }
        }
    }

    /// 双入口按钮（原型 parking-tool-row：图标在上文字在下）
    private func toolEntry(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundStyle(NavTheme.accentDeep)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(NavTheme.ink)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(NavTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// 停车记录卡（原型 parking-record：缩略图/图标 + 备注 + 保存时间 + 查看记录 + 操作行）
    private func parkingRecordCard(_ saved: NavStores.ParkingNote) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                path.append(.parkingNote)
            } label: {
                HStack(spacing: 12) {
                    if let data = saved.imageData, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(NavTheme.accentSoft)
                            Image(systemName: "parkingsign")
                                .font(.system(size: 26))
                                .foregroundStyle(NavTheme.accentDeep)
                        }
                        .frame(width: 64, height: 64)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        let display = saved.note.trimmingCharacters(in: .whitespaces)
                        Text(display.isEmpty ? "已拍下停车位置" : display)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(NavTheme.ink)
                            .lineLimit(1)
                        Text(saved.createdAt.map { "\(NavFormat.dateTime($0)) 保存" } ?? "时间未记录")
                            .font(.system(size: 12))
                            .foregroundStyle(NavTheme.inkMute)
                        Label("查看记录", systemImage: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(NavTheme.accentDeep)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
            }
            .buttonStyle(.plain)

            // 操作行（原型 parking-record-actions：补充/修改 + 删除便签）
            HStack(spacing: 10) {
                Button {
                    path.append(.parkingNote)
                } label: {
                    Text("补充 / 修改")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NavTheme.accentDeep)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(NavTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                Button {
                    path.append(.parkingNote)
                } label: {
                    Label("删除便签", systemImage: "trash")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NavTheme.bad)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(NavTheme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding([.horizontal, .bottom], 12)
        }
        .navCard()
    }

    /// 空态（原型 parking-empty：图标 + 主文案 + 说明 + 示例）
    private var parkingEmptyCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "parkingsign")
                .font(.system(size: 30))
                .foregroundStyle(NavTheme.inkMute)
            Text("停好车，留个记号")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NavTheme.ink)
            Text("记下楼层车位，或拍下附近标识。")
                .font(.system(size: 13))
                .foregroundStyle(NavTheme.inkSoft)
            Text("例如：地下 B2 · D区168号")
                .font(.system(size: 11))
                .foregroundStyle(NavTheme.inkMute)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .navCard()
    }
}

/// 地址整理：粘贴文本 → 规则提取候选 → 选择/手填确认 → **高德标准化** → 快捷导航
/// （v0.32 原型对齐：label「粘贴聊天或订单文字」+ 提取状态行 + 候选横排按钮 +
///   导航地址可编辑 + 快捷导航；标准化走高德 iOS SDK 地理编码（复用已配置 SDK key），
///   失败时 MapKit 兜底——产出结构化标准地址便于导航检索命中）
struct AddressParserView: View {
    @ObservedObject var model: NavAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var textLimitHit = false          // 超限粘贴显式提示（不静默截断后直接提取）
    @State private var outcome: AddressExtractionOutcome?
    @State private var selectedCandidate: Int?       // 候选选中（0 候选时 nil=手填）
    @State private var finalAddress = ""             // 最终确认地址（≤180 字）
    @State private var finalLimitHit = false
    @State private var extractedOnce = false         // 0 候选提示只在提取后显示
    @State private var standardizing = false         // 高德标准化中（导航按钮防重）
    @State private var standardNote = ""             // 标准化结果状态（原/标准地址 + 来源）
    @State private var standardizeToken = UUID()     // 异步标准化结果防错配（原文/候选变更即失效）
    @State private var lastAutoFilled = ""           // 最近一次程序回填值（区分用户手改）
    @State private var lastStandardized: AddressStandardizer.StandardAddress?

    private var candidates: [String] { outcome?.candidates ?? [] }

    /// 原型状态行：找到多个地址，请选择 / 已提取地址，请确认 / 未找到明确地址，可手动填写
    private var extractionStatus: String? {
        guard extractedOnce, let outcome else { return nil }
        if outcome.candidates.count > 1 { return "找到多个地址，请选择" }
        if outcome.candidates.count == 1 { return "已提取地址，请确认" }
        return "未找到明确地址，可手动填写"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 原型 label：粘贴聊天或订单文字
                Text("粘贴聊天或订单文字")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NavTheme.inkSoft)

                TextField("例如：\n收件人：李先生\n地址：杭州市西湖区湖滨路26号\n备注：到后联系", text: $text, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(4...8)
                    .padding(12)
                    .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(NavTheme.line, lineWidth: 1))
                    .onChange(of: text) { value in
                        // 【U-008】超限显式提示：保留上限内文本并提示，不得无提示截断后直接提取
                        if value.count > 2000 {
                            text = String(value.prefix(2000))
                            textLimitHit = true
                        }
                        // 【U-009】编辑原文 → 旧候选、选择、确认值、旧错误立即失效
                        if outcome != nil || selectedCandidate != nil || !finalAddress.isEmpty || extractedOnce {
                            outcome = nil
                            selectedCandidate = nil
                            finalAddress = ""
                            extractedOnce = false
                            standardNote = ""
                            lastStandardized = nil
                        }
                        // 原文改动 → 在途标准化结果一律作废
                        standardizeToken = UUID()
                    }

                if textLimitHit {
                    Text("最多 2000 字，请删减后提取")
                        .font(.system(size: 12))
                        .foregroundStyle(NavTheme.bad)
                }

                NavPrimaryButton(title: "提取地址", systemImage: "wand.and.stars",
                                 enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    extract()
                }

                // 原型：提取后才展示 address-extracted 浅绿容器（状态 + 候选 + 导航地址）
                if extractedOnce {
                    VStack(alignment: .leading, spacing: 14) {
                        if let status = extractionStatus {
                            Text(status)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(NavTheme.inkSoft)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let outcome {
                            candidateSection(outcome)
                        }

                        finalSection
                    }
                    .padding(17)
                    .background(NavTheme.accentSoft.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                // 原型 fresh-tool-status（始终显示）
                Text("提取后可修改，实际地点与路线到导航确认。")
                    .font(.system(size: 12))
                    .foregroundStyle(NavTheme.inkMute)
            }
            .padding(16)
        }
        .background(NavTheme.bg)
        .navigationTitle("地址整理")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 候选区（原型 address-choices：竖排列表，序号 + 文本，选中高亮）

    @ViewBuilder
    private func candidateSection(_ outcome: AddressExtractionOutcome) -> some View {
        if outcome.candidates.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(outcome.candidates.enumerated()), id: \.offset) { index, address in
                    Button {
                        selectedCandidate = index
                        lastAutoFilled = address
                        finalAddress = address
                        standardNote = ""
                        lastStandardized = nil
                        let token = UUID()
                        standardizeToken = token
                        Task { await applyStandardization(address, token: token) }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(selectedCandidate == index ? .white : NavTheme.accentDeep)
                                .frame(width: 20, height: 20)
                                .background(selectedCandidate == index ? NavTheme.accent : NavTheme.accentSoft,
                                            in: Circle())
                            Text(address)
                                .font(.system(size: 14))
                                .foregroundStyle(NavTheme.ink)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(NavTheme.panel.opacity(selectedCandidate == index ? 1 : 0.6),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selectedCandidate == index ? NavTheme.accent : NavTheme.line,
                                    lineWidth: selectedCandidate == index ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                }
                // 【U-004】超 5 个显式提示，不悄悄丢弃
                if outcome.truncated {
                    Text("仅显示前 5 个，请缩小原文范围")
                        .font(.system(size: 12))
                        .foregroundStyle(NavTheme.bad)
                }
            }
            .accessibilityLabel("选择提取的地址")
        }
    }

    // MARK: - 最终导航地址（可编辑，≤180 字；标准化后回填标准地址）

    private var finalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("导航地址")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NavTheme.inkSoft)
            TextField("确认或补充城市、道路、门牌", text: $finalAddress, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...3)
                .padding(12)
                .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(NavTheme.line, lineWidth: 1))
                .onChange(of: finalAddress) { value in
                    if value.count > 180 {
                        finalAddress = String(value.prefix(180))
                        finalLimitHit = true
                    }
                    // 用户手改 → 作废在途标准化结果（程序回填值不触发）
                    if value != lastAutoFilled {
                        standardizeToken = UUID()
                        standardNote = ""
                        lastStandardized = nil
                    }
                    // 手动改动后取消候选高亮（文字已是用户确认值）
                    if let idx = selectedCandidate, candidates.indices.contains(idx), value != candidates[idx] {
                        selectedCandidate = nil
                    }
                }
            if finalLimitHit {
                Text("最多 180 字")
                    .font(.system(size: 12))
                    .foregroundStyle(NavTheme.bad)
            }

            // 标准化状态（高德/MapKit 回填标准地址后提示，可继续手改）
            if !standardNote.isEmpty {
                Text(standardNote)
                    .font(.system(size: 12))
                    .foregroundStyle(NavTheme.inkSoft)
            }

            NavPrimaryButton(title: standardizing ? "标准化地址中…" : "快捷导航",
                             systemImage: "location.fill",
                             enabled: !finalAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      && !standardizing,
                             loading: standardizing) {
                Task { await navigateAndStandardize() }
            }

        }
    }

    // MARK: - 动作

    private func extract() {
        let result = AddressExtractor.extractOutcome(from: text)
        outcome = result
        extractedOnce = true
        standardNote = ""
        lastStandardized = nil
        let token = UUID()
        standardizeToken = token
        // 【规则 §1.1-5】1 个候选填入可编辑字段并提示核对；2~5 个默认选第一项，仍须核对
        if let first = result.candidates.first {
            selectedCandidate = 0
            lastAutoFilled = first
            finalAddress = first
            // 【v0.32 需求】提取即走高德地理编码，把「光荣道26号」补成
            // 「天津市北辰区光荣道26号」这类标准地址，用户仍可手改。
            Task { await applyStandardization(first, token: token) }
        } else {
            selectedCandidate = nil
            lastAutoFilled = ""
            finalAddress = ""
        }
    }

    /// 提取/切换候选后立即标准化并回填导航地址；失败保留原文（不阻塞）。
    private func applyStandardization(_ raw: String, token: UUID) async {
        if token == standardizeToken { standardNote = "正在转为标准地址…" }
        let std = await AddressStandardizer.standardize(raw)
        guard token == standardizeToken else { return }   // 原文/候选已变 → 丢弃旧结果
        guard let std, !std.formatted.isEmpty else {
            standardNote = ""
            return
        }
        lastStandardized = std
        if std.formatted != raw {
            lastAutoFilled = std.formatted
            finalAddress = std.formatted
            standardNote = "已转为标准地址（\(std.source.rawValue)）：\(std.formatted)"
        } else {
            standardNote = "地址已为标准格式（\(std.source.rawValue)）"
        }
    }

    /// 【v0.32 需求】快捷导航 = 标准地址 → 真实地点检索。
    /// 提取阶段已标准化时复用结果；用户手改后重新标准化（失败用原文，不阻塞）。
    private func navigateAndStandardize() async {
        var keyword = finalAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !standardizing else { return }
        guard model.requireMembership() else { return }
        standardizing = true
        defer { standardizing = false }
        var std = lastStandardized
        if std?.formatted != keyword {
            std = await AddressStandardizer.standardize(keyword)
        }
        if let std, std.formatted != keyword {
            keyword = std.formatted
            lastAutoFilled = std.formatted
            finalAddress = std.formatted
            standardNote = "已转为标准地址（\(std.source.rawValue)）：\(std.formatted)"
        }
        // 文字交给真实地点检索（搜索框回显标准地址），会员/路线流程走既有规则
        model.openSearch(target: .destination, preset: keyword)
        dismiss()
    }
}

// MARK: - 停车便签（规则 v0.31.1 §2）

/// 停车便签：备注（≤100 字）+ 一张照片；不自动采集 GPS、不绘返车路线、照片不上传。
/// 仅一条当前记录。【R-073】「已找到车」不再是删除前置——任意状态可删（二次确认）；
/// 新建/编辑带「在首页显示」开关（默认开，编辑继承旧值）。
struct ParkingNoteView: View {
    @ObservedObject var model: NavAppModel
    @State private var note = ""
    @State private var noteLimitHit = false
    @State private var imageItem: PhotosPickerItem?
    @State private var draftImage: UIImage?
    @State private var processingImage = false     // 照片处理中（禁重复提交）
    @State private var imageError: String?         // 照片处理失败提示（草稿保留）
    @State private var saveError: String?          // 保存失败提示（旧记录与草稿保留）
    @State private var saving = false              // 保存中（双击保护）
    @State private var confirmDelete = false       // 「删除便签」二次确认（R-073-05，无前置）
    @State private var clearFailed = false         // 删除失败提示
    @State private var toggleFailed = false        // 首页显示开关持久化失败（R-073-03/T-254）
    /// 表单「在首页显示」开关：新建默认开；编辑时回填旧值（R-073-04 继承不自动重开）
    @State private var homeVisible = true
    /// 记录刚被本次会话删除（用于隐藏编辑表单，回到空态）
    @State private var justDeleted = false

    private var savedNote: NavStores.ParkingNote? { model.stores.parking }
    /// 可保存：非空备注或有效照片至少一项（双空不可点/不可覆盖旧记录）
    private var canSave: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftImage != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let saved = savedNote {
                    savedCard(saved)
                }

                editorCard
            }
            .padding(16)
        }
        .background(NavTheme.bg)
        .navigationTitle("停车便签")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: imageItem) { item in
            guard let item else { return }
            processImage(item)
        }
        .alert("删除便签？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                // 【R-073-05】确认且删除成功才清空（含照片）；失败提示并保持旧记录（T-258）
                if model.stores.deleteParking() {
                    draftImage = nil
                    imageItem = nil
                    note = ""
                    homeVisible = true          // 删除后新建重置默认开（R-073 状态口径）
                    justDeleted = true
                } else {
                    clearFailed = true
                }
            }
            .disabled(clearFailed)              // 【R-073-05】连点不能误删新记录
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后备注与照片将从本机清除，首页卡片同步消失，无法恢复。")
        }
        .alert("清除失败", isPresented: $clearFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text("记录未能删除，已保留原记录，请重试。")
        }
        .onAppear {
            // 【R-073-04·已有记录修改】回填当前备注/照片/展示开关（继承旧值，不自动重开）
            if let saved = savedNote, note.isEmpty, draftImage == nil {
                note = saved.note
                homeVisible = saved.homeVisible
                if let data = saved.imageData { draftImage = UIImage(data: data) }
            }
        }
    }

    // MARK: - 已保存记录卡（详情：显示内容 + 开关 + 删除）

    private func savedCard(_ saved: NavStores.ParkingNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("当前停车记录")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NavTheme.inkSoft)
                Spacer()
                // 【U-023】无法核实的旧时间显示「时间未记录」，不伪造
                Text(saved.createdAt.map { NavFormat.dateTime($0) } ?? "时间未记录")
                    .font(.system(size: 12))
                    .foregroundStyle(NavTheme.inkMute)
            }
            let displayNote = saved.note.trimmingCharacters(in: .whitespaces)
            if !displayNote.isEmpty {
                Text(displayNote)
                    .font(.system(size: 14))
                    .foregroundStyle(NavTheme.ink)
            }
            if let data = saved.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            // 【R-073-03】「在首页显示」开关（详情即时生效：关→首页卡立即消失，开→立即恢复；
            // 仅改展示字段，不删备注/照片/时间；持久化失败开关回退并提示——T-254）
            Toggle(isOn: Binding(
                get: { model.stores.parking?.homeVisible ?? saved.homeVisible },
                set: { newValue in
                    if !model.stores.setParkingHomeVisible(newValue) {
                        // 持久化失败：开关回退旧值 + 提示；记录不丢
                        model.stores.objectWillChange.send()
                        toggleFailed = true
                    }
                })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("在首页显示")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(NavTheme.ink)
                    Text("关闭后首页不展示此卡，记录仍保留在工具内")
                        .font(.system(size: 11))
                        .foregroundStyle(NavTheme.inkMute)
                }
            }
            .tint(NavTheme.accent)

            // 【R-073-05】删除便签：不再前置「已找到车」，任意状态可删（二次确认）
            Button("删除便签", role: .destructive) {
                confirmDelete = true
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(NavTheme.bad)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .navCard()
        .alert("开关保存失败", isPresented: $toggleFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text("显示状态未能更新（可能存储空间不足），已恢复旧状态，记录未丢失。")
        }
    }

    // MARK: - 编辑卡

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(savedNote == nil ? "记录车辆位置" : "修改记录")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NavTheme.ink)

            TextField("楼层 / 车位 / 附近标识（最多 100 字）", text: $note, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(2...4)
                .padding(12)
                .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(NavTheme.line, lineWidth: 1))
                .onChange(of: note) { value in
                    if value.count > 100 {
                        note = String(value.prefix(100))
                        noteLimitHit = true
                    }
                }
            if noteLimitHit {
                Text("备注最多 100 字")
                    .font(.system(size: 12))
                    .foregroundStyle(NavTheme.bad)
            }

            // 拍一张（相机权限仅点击时请求）：走系统相机选择器，取消不改动草稿
            PhotosPicker(selection: $imageItem, matching: .images) {
                HStack(spacing: 8) {
                    Image(systemName: processingImage ? "hourglass" : "photo.on.rectangle.angled")
                    Text(processingImage ? "照片处理中…"
                         : draftImage == nil ? "拍一张 / 选择停车照片"
                         : "已选择照片，可重新选择")
                        .font(.system(size: 14))
                }
                .foregroundStyle(NavTheme.accentDeep)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(NavTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(processingImage)

            if let imageError {
                Text(imageError)
                    .font(.system(size: 12))
                    .foregroundStyle(NavTheme.bad)
            }

            if let draftImage {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: draftImage)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 160)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button {
                        // 【U-021】移除草稿照片：有备注仍可保存纯文字
                        self.draftImage = nil
                        imageItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                            .shadow(radius: 3)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除照片")
                }
            }

            if let saveError {
                Text(saveError)
                    .font(.system(size: 12))
                    .foregroundStyle(NavTheme.bad)
            }

            // 【R-073-01/04】「在首页显示」开关：新建默认开；编辑回填旧值（继承不自动重开）
            Toggle(isOn: $homeVisible) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("在首页显示")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(NavTheme.ink)
                    Text("开启后首页搜索与快捷入口下方展示精简卡片")
                        .font(.system(size: 11))
                        .foregroundStyle(NavTheme.inkMute)
                }
            }
            .tint(NavTheme.accent)

            NavPrimaryButton(title: savedNote == nil ? "保存停车位置" : "更新停车记录",
                             systemImage: "parkingsign",
                             enabled: canSave && !processingImage,
                             loading: saving) {
                save()
            }

            Text("备注与照片仅保存在本机，不上传、不参与分析；不自动采集停车位置。")
                .font(.system(size: 11))
                .foregroundStyle(NavTheme.inkMute)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .navCard()
    }

    // MARK: - 照片处理（规则 §2.1：验证 → 方向 → 等比压缩 → JPEG 0.78）

    private func processImage(_ item: PhotosPickerItem) {
        processingImage = true
        imageError = nil
        Task {
            defer { processingImage = false }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                // 【U-017】读取失败：明确提示，草稿旧图保留
                imageError = "照片读取失败，请重新选择。"
                return
            }
            // 20 MB 上限（进处理前校验）
            guard data.count <= 20 * 1024 * 1024 else {
                imageError = "照片超过 20 MB，请换一张。"
                return
            }
            guard let processed = Self.compress(data) else {
                imageError = "照片无法处理（可能已损坏），请换一张。"
                return
            }
            draftImage = processed
        }
    }

    /// 验证解码 + 0 尺寸排除 + 方向正确 + 长边 ≤1200 等比缩放 + JPEG 0.78
    private static func compress(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }   // 0 尺寸图排除
        let maxSide: CGFloat = 1200
        let longest = max(size.width, size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1    // 按像素输出，不乘屏幕倍率
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        // image.draw 自动应用 EXIF 方向
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.78) else { return nil }
        return UIImage(data: jpeg)
    }

    // MARK: - 保存

    private func save() {
        guard canSave, !saving else { return }
        saving = true
        saveError = nil
        // 【U-019/020】保存成功以持久化为准；失败保留草稿与旧记录，不虚报成功
        // 【R-073-04】编辑继承表单里的开关值（隐藏状态下编辑保存，首页仍隐藏——T-255）；
        // 新建默认开（@State 初始 true）；创建时间语义保持「首次记录时间」不因编辑重置
        let record = NavStores.ParkingNote(
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            imageData: draftImage?.jpegData(compressionQuality: 0.78),
            createdAt: savedNote?.createdAt ?? Date(),
            homeVisible: homeVisible)
        let ok = model.stores.saveParking(record)
        saving = false
        if ok {
            note = ""
            noteLimitHit = false
            imageItem = nil
            // 保存后回填模式：不清 homeVisible（继承当前选择）
        } else {
            saveError = "保存失败（可能存储空间不足），草稿已保留，请重试。"
        }
    }
}
