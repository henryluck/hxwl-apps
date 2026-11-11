import CoreLocation
import CoreKit
import PhotosUI
import SwiftUI

// MARK: - 常用地点

/// 常用地点：本机管理免费，去导航为会员（R-033/034）
struct SavedPlacesScreen: View {
    @ObservedObject var model: NavAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: NavStores.SavedPlace?
    @State private var showEditor = false
    @State private var deleteTarget: NavStores.SavedPlace?

    var body: some View {
        NavigationStack {
            Group {
                if model.stores.savedPlaces.isEmpty {
                    NavEmptyView(title: "还没有常用地点",
                                 detail: "添加家、公司或其他常用地址，导航时可直接带入")
                } else {
                    List {
                        ForEach(model.stores.savedPlaces) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Text(item.category)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(NavTheme.accentDeep)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(NavTheme.accentSoft, in: Capsule())
                                    Text(item.name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(NavTheme.ink)
                                }
                                Text(item.address)
                                    .font(.system(size: 13))
                                    .foregroundStyle(NavTheme.inkMute)
                                    .lineLimit(2)
                                HStack(spacing: 14) {
                                    Button("去导航") {
                                        guard model.requireMembership() else { return }
                                        if let place = item.place, place.hasValidCoordinate {
                                            model.destination = place
                                            dismiss()
                                            model.openPlan()
                                        } else {
                                            // 地址未确认坐标：走真实检索确认（R-034）
                                            model.openSearch(target: .destination, preset: item.address)
                                        }
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
                    if let target = deleteTarget {
                        model.stores.deleteSaved(id: target.id)
                    }
                    deleteTarget = nil
                }
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: {
                Text(deleteTarget?.name ?? "")
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
    @State private var category = "家"

    private let categories = ["家", "公司", "其他"]

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("最多 30 字", text: $name)
                        .onChange(of: name) { value in
                            if value.count > 30 { name = String(value.prefix(30)) }
                        }
                }
                Section("地址") {
                    TextField("最多 120 字", text: $address, axis: .vertical)
                        .lineLimit(2...3)
                        .onChange(of: address) { value in
                            if value.count > 120 { address = String(value.prefix(120)) }
                        }
                }
                Section("类别") {
                    Picker("类别", selection: $category) {
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(editing == nil ? "新增常用地点" : "编辑常用地点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let editing {
                    name = editing.name
                    address = editing.address
                    category = editing.category
                }
            }
        }
    }

    private func save() {
        let item = NavStores.SavedPlace(id: editing?.id ?? UUID().uuidString,
                                        name: name.trimmingCharacters(in: .whitespaces),
                                        address: address.trimmingCharacters(in: .whitespaces),
                                        category: category,
                                        place: editing?.place,
                                        createdAt: editing?.createdAt ?? Date())
        if model.stores.upsertSaved(item) {
            dismiss()
        }
    }
}

// MARK: - 出行工具

/// 出行工具：地址整理（客户端文本规则）+ 停车便签（本机，照片不上传）
struct TravelToolsScreen: View {
    @ObservedObject var model: NavAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AddressParserView(model: model)
                    } label: {
                        Label("地址整理", systemImage: "text.alignleft")
                    }
                    NavigationLink {
                        ParkingNoteView(model: model)
                    } label: {
                        Label("停车便签", systemImage: "parkingsign.circle")
                    }
                } footer: {
                    Text("地址整理为客户端文本规则，不使用 AI 问答、不做图片识别、不自动读取剪贴板。")
                }
            }
            .navigationTitle("出行工具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

/// 地址整理：粘贴文本 → 规则提取最多 5 条候选（R-035/036）
struct AddressParserView: View {
    @ObservedObject var model: NavAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var candidates: [String] = []
    @State private var editingIndex: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("粘贴包含地址的文本（最多 2000 字）")
                    .font(.system(size: 13))
                    .foregroundStyle(NavTheme.inkMute)

                TextField("例如：明天 10 点去天河区体育西路 103 号维多利广场", text: $text, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(4...8)
                    .padding(12)
                    .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(NavTheme.line, lineWidth: 1))
                    .onChange(of: text) { value in
                        if value.count > 2000 { text = String(value.prefix(2000)) }
                    }

                NavPrimaryButton(title: "整理地址", systemImage: "wand.and.stars",
                                 enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    candidates = AddressExtractor.extract(from: text)
                }

                if !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("候选地址（\(candidates.count)）")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NavTheme.inkSoft)
                        ForEach(Array(candidates.enumerated()), id: \.offset) { index, address in
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(NavTheme.accentDeep)
                                    .frame(width: 22, height: 22)
                                    .background(NavTheme.accentSoft, in: Circle())
                                Text(address)
                                    .font(.system(size: 14))
                                    .foregroundStyle(NavTheme.ink)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                                Button("导航") {
                                    guard model.requireMembership() else { return }
                                    model.openSearch(target: .destination, preset: address)
                                    dismiss()
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(NavTheme.accent)
                            }
                            .padding(10)
                            .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                } else if !text.isEmpty {
                    Text("未提取到地址，可手动填写关键词后点「导航」走真实检索。")
                        .font(.system(size: 12))
                        .foregroundStyle(NavTheme.inkMute)
                }
            }
            .padding(16)
        }
        .background(NavTheme.bg)
        .navigationTitle("地址整理")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum AddressExtractor {
    /// 客户端规则：按标点切分，保留含地址特征词的片段，最多 5 条
    static func extract(from text: String) -> [String] {
        let separators = CharacterSet(charactersIn: "，,。；;！!？?\n\r\t、|")
        let chunks = text.components(separatedBy: separators)
        let keywords = ["路", "街", "道", "巷", "号", "弄", "小区", "大厦", "广场",
                        "中心", "大厦", "园", "村", "镇", "区", "县", "市", "楼", "栋"]
        var results: [String] = []
        for raw in chunks {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 4, trimmed.count <= 180 else { continue }
            guard keywords.contains(where: { trimmed.contains($0) }) else { continue }
            if !results.contains(trimmed) { results.append(trimmed) }
            if results.count >= 5 { break }
        }
        return results
    }
}

/// 停车便签：备注 + 一张照片，本机保存（R-037/038）
struct ParkingNoteView: View {
    @ObservedObject var model: NavAppModel
    @State private var note = ""
    @State private var imageItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let savedNote = model.stores.parking {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("已保存的停车记录")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NavTheme.inkSoft)
                        Text(NavFormat.clock(savedNote.createdAt))
                            .font(.system(size: 12))
                            .foregroundStyle(NavTheme.inkMute)
                        if !savedNote.note.isEmpty {
                            Text(savedNote.note)
                                .font(.system(size: 14))
                                .foregroundStyle(NavTheme.ink)
                        }
                        if let data = savedNote.imageData, let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 140)
                                .frame(maxWidth: .infinity)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        Button("清除记录", role: .destructive) {
                            model.stores.clearParking()
                            saved = false
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NavTheme.bad)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .navCard()
                }

                Text("备注")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NavTheme.inkSoft)
                TextField("例如：B2 层 312 号车位", text: $note, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(2...4)
                    .padding(12)
                    .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(NavTheme.line, lineWidth: 1))

                PhotosPicker(selection: $imageItem, matching: .images) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                        Text(imageData == nil ? "选择一张停车照片" : "已选择照片，可重新选择")
                            .font(.system(size: 14))
                    }
                    .foregroundStyle(NavTheme.accentDeep)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(NavTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if let imageData, let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 160)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                NavPrimaryButton(title: "保存停车位置",
                                 systemImage: "parkingsign",
                                 enabled: !note.trimmingCharacters(in: .whitespaces).isEmpty || imageData != nil) {
                    save()
                }

                Text("照片与备注仅保存在本机，不上传、不参与分析。")
                    .font(.system(size: 11))
                    .foregroundStyle(NavTheme.inkMute)
            }
            .padding(16)
        }
        .background(NavTheme.bg)
        .navigationTitle("停车便签")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: imageItem) { item in
            Task {
                guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
                imageData = Self.compress(data)
            }
        }
    }

    private func save() {
        let record = NavStores.ParkingNote(note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                           imageData: imageData,
                                           createdAt: Date())
        saved = model.stores.saveParking(record)
        if saved {
            note = ""
            imageData = nil
            imageItem = nil
        }
    }

    /// 长边 ≤1200、JPEG 0.78（R-037 输入限制）
    private static func compress(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1200
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.78)
    }
}
