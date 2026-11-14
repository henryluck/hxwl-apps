import CoreLocation
import SwiftUI

/// 海拔：对齐原型 alt-page-v14（R-028/029/030/031）
/// 结构：渐变 hero 区（eef8f1→e3f2e8 + 远山插画）+「当前位置海拔」+ 68pt 大数字 +
/// 状态注记 → alt-content：位置行（图标卡 + 地名 + 重新定位圆钮）→ 经纬度行
/// （上分隔线 + 复制按钮）→ 主按钮「记录这一刻」→ 次链接「我的海拔记录」。
struct AltitudeScreen: View {
    @ObservedObject var model: NavAppModel
    @State private var showRecordSheet = false
    @State private var showHistory = false
    @State private var note = ""
    @State private var copied = false

    private var snapshot: LocationSnapshot? { model.location.snapshot }

    var body: some View {
        ZStack {
            // 原型 alt-page：#f6faf7 底色
            Color(hex: "F6FAF7").ignoresSafeArea()

            VStack(spacing: 0) {
                hero
                if !model.isUnlocked {
                    Spacer(minLength: 0)
                    gate
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        content
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                            .padding(.bottom, 24)
                    }
                }
            }
        }
        .task {
            if snapshot == nil { await model.locate() }
        }
        .sheet(isPresented: $showRecordSheet) { recordSheet }
        .sheet(isPresented: $showHistory) { historySheet }
        // 未解锁时连续停留 10 秒自动提醒（关闭订阅页后重新计时）
        .autoPaywallReminder(active: !model.isUnlocked)
    }

    // MARK: - Hero 区（alt-hero：渐变 + 远山插画 + 大读数）

    private var hero: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 8)

            Spacer(minLength: 14)

            // alt-reading-label
            Text("当前位置海拔")
                .font(.system(size: 17))
                .foregroundStyle(Color(hex: "38624F"))

            // alt-number：68pt 大数字 + 米
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(altitudeText)
                    .font(.system(size: 68, weight: .semibold, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: "164E38"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("米")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(hex: "164E38").opacity(0.85))
            }
            .padding(.top, 9)

            // alt-reading-note
            Text(readingNote)
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "466B57"))
                .padding(.top, 4)

            // 远山插画（贴 hero 底部）
            AltLandscapeArt()
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .background(
            LinearGradient(colors: [Color(hex: "EEF8F1"), Color(hex: "E3F2E8")],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var header: some View {
        HStack {
            Text("海拔")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color(hex: "193E30"))
            Spacer()
            // 页头「我的 / 会员」chip（fresh-account 简化：只放会员 chip，我的在 Tab 结构外）
            Button {
                model.showProfile = true
            } label: {
                Label("我的", systemImage: "person")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(hex: "1E5038"))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Color.white.opacity(0.87), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(hex: "DCEBE1"), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)

            Button {
                _ = model.requireMembership()
            } label: {
                Label("会员", systemImage: "crown.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(hex: "533600"))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Color(hex: "FFCB4D"), in: Capsule())
                    .shadow(color: Color(hex: "D8A20C").opacity(0.12), radius: 3, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("会员中心")
        }
    }

    private var altitudeText: String {
        guard let snapshot else { return "—" }
        let value = Int(snapshot.altitude.rounded())
        // 原型 toLocaleString('en-US')：千分位
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private var readingNote: String {
        guard let snapshot else { return "每一段旅程，都值得记录" }
        if model.location.authState.isUsable {
            return "更新于 \(NavFormat.clock(snapshot.timestamp))"
        }
        return "定位未更新 · 上次数据 \(NavFormat.clock(snapshot.timestamp))"
    }

    // MARK: - 内容区（alt-content）

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 位置行（alt-position：图标卡 + 标题 + 重新定位圆钮）
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(hex: "18704E"))
                    .frame(width: 42, height: 46)
                    .background(Color(hex: "E3F1E8"), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(placeText)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color(hex: "193E30"))
                        .lineLimit(1)
                    Text("当前位置")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "536F60"))
                }

                Spacer(minLength: 8)

                Button {
                    Task { await model.locate() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18))
                        .foregroundStyle(Color(hex: "236949"))
                        .frame(width: 44, height: 44)
                        .background(Color.white, in: Circle())
                        .overlay(Circle().strokeBorder(Color(hex: "DBE9DF"), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重新定位")
            }
            .padding(.bottom, 23)

            // 经纬度行（outdoor-coordinates：上分隔线 + 复制按钮）
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("经纬度")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "506C5B"))
                    Text(coordinateText)
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(hex: "224E38"))
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button {
                    copyCoordinates()
                } label: {
                    Text(copied ? "已复制" : "复制")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(hex: "076447"))
                        .frame(minWidth: 48)
                        .frame(height: 44)
                        .background(Color(hex: "E4F2E9"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(snapshot == nil)
                .opacity(snapshot == nil ? 0.5 : 1)
            }
            .padding(.vertical, 13)
            .overlay(alignment: .top) {
                Rectangle().fill(Color(hex: "DCE9DF")).frame(height: 1)
            }
            .padding(.bottom, 18)

            // 主按钮「记录这一刻」（alt-record-button）
            Button {
                note = ""
                showRecordSheet = true
            } label: {
                Label("记录这一刻", systemImage: "square.and.pencil")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(snapshot == nil ? Color(hex: "687E70") : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(snapshot == nil ? Color(hex: "D9E5DD") : Color(hex: "087F5B"))
                    )
            }
            .buttonStyle(.plain)
            .disabled(snapshot == nil)
            .padding(.bottom, 6)

            // 次链接「我的海拔记录」（alt-record-link）
            Button {
                showHistory = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 17))
                    Text("我的海拔记录")
                        .font(.system(size: 17))
                    Spacer()
                    Text(recordCountText)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "526F5D"))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "526F5D").opacity(0.7))
                }
                .foregroundStyle(Color(hex: "26553E"))
                .frame(height: 62)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color(hex: "DFEBE2")).frame(height: 1)
                }
            }
            .buttonStyle(.plain)

            Text("海拔为设备定位返回值，受遮挡与天气影响存在误差；本 App 不提供气压、含氧量等专业仪表数据。")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "617569"))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
        }
    }

    private var recordCountText: String {
        model.stores.altitudeRecords.isEmpty ? "暂无记录" : "\(model.stores.altitudeRecords.count) 条"
    }

    private var placeText: String {
        guard let snapshot else { return "位置暂不可用" }
        return snapshot.place.name.isEmpty ? "当前位置" : snapshot.place.name
    }

    private var coordinateText: String {
        guard let snapshot else { return "暂不可用" }
        return NavFormat.coordinate(snapshot.latitude, snapshot.longitude)
    }

    private func copyCoordinates() {
        guard let snapshot else { return }
        UIPasteboard.general.string = NavFormat.coordinate(snapshot.latitude, snapshot.longitude)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    // MARK: - 锁定态（alt-gate：金边高亮按钮）

    private var gate: some View {
        VStack(spacing: 12) {
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color(hex: "B27B24"))
                .padding(.bottom, 12)
            Text("看看此刻，你在多高的地方")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Color(hex: "2F5B43"))
            Text("查看海拔、位置，留下一份出行记录")
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: "526E61"))
                .padding(.bottom, 22)
            Button {
                _ = model.requireMembership()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text("解锁海拔与记录")
                        .font(.system(size: 18, weight: .semibold))
                }
                .foregroundStyle(Color(hex: "533600"))
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color(hex: "FFFAF2"), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(Color(hex: "DDBD8C"), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - 记录 sheet

    private var recordSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                if let snapshot {
                    // alt-record-preview：预览卡
                    HStack(spacing: 15) {
                        Image(systemName: "mountain.2.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color(hex: "346547"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%.0f 米", snapshot.altitude))
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(Color(hex: "193E30"))
                            Text(NavFormat.clock(snapshot.timestamp))
                                .font(.system(size: 14))
                                .foregroundStyle(Color(hex: "486557"))
                        }
                        Spacer()
                    }
                    .padding(17)
                    .background(Color(hex: "E5F3EA"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Text("备注（选填，最多 80 字）")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "526F5D"))
                TextField("给这次记录写一句话", text: $note, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(2...4)
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color(hex: "C9DFD1"), lineWidth: 1)
                    }
                    .onChange(of: note) { value in
                        if value.count > 80 { note = String(value.prefix(80)) }
                    }
                Text("自动保存时间、位置与坐标，仅存本机。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "526F5D"))
                Button {
                    saveRecord()
                } label: {
                    Label("保存记录", systemImage: "square.and.arrow.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color(hex: "087F5B"), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(snapshot == nil)
                Spacer()
            }
            .padding(22)
            .background(Color(hex: "F6FAF7"))
            .navigationTitle("记录这一刻")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showRecordSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func saveRecord() {
        guard let snapshot else { return }
        let record = NavStores.AltitudeRecord(
            id: UUID().uuidString,
            altitude: snapshot.altitude,
            latitude: snapshot.latitude,
            longitude: snapshot.longitude,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date())
        if model.stores.addAltitudeRecord(record) {
            showRecordSheet = false
        }
    }

    // MARK: - 历史 sheet

    private var historySheet: some View {
        NavigationStack {
            Group {
                if model.stores.altitudeRecords.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "mountain.2")
                            .font(.system(size: 36))
                            .foregroundStyle(Color(hex: "47765C"))
                        Text("还没有海拔记录")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Color(hex: "193E30"))
                        Text("在海拔页点击「记录这一刻」。")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(hex: "526F5D"))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(model.stores.altitudeRecords) { record in
                                // alt-saved：白卡记录条目
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(String(format: "%.0f", record.altitude))
                                            .font(.system(size: 27, weight: .semibold))
                                            .foregroundStyle(Color(hex: "193E30"))
                                        Text("米")
                                            .font(.system(size: 16))
                                            .foregroundStyle(Color(hex: "526F5D"))
                                        Spacer()
                                        Text("记录")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color(hex: "526F5D"))
                                    }
                                    Text(NavFormat.coordinate(record.latitude, record.longitude))
                                        .font(.system(size: 14, design: .monospaced))
                                        .foregroundStyle(Color(hex: "496452"))
                                    Text("更新于 \(NavFormat.clock(record.createdAt))")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color(hex: "496452"))
                                    if !record.note.isEmpty {
                                        Text(record.note)
                                            .font(.system(size: 15))
                                            .foregroundStyle(Color(hex: "193E30").opacity(0.85))
                                    }
                                    HStack {
                                        Text("\(NavFormat.clock(record.createdAt)) 保存")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color(hex: "526F5D"))
                                        Spacer()
                                        Button {
                                            model.stores.deleteAltitudeRecord(id: record.id)
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.system(size: 15))
                                                .foregroundStyle(Color(hex: "526F5D"))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.top, 7)
                                    .overlay(alignment: .top) {
                                        Rectangle().fill(Color(hex: "EDF3EE")).frame(height: 1)
                                    }
                                }
                                .padding(16)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(Color(hex: "D7E6DC"), lineWidth: 1)
                                }
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 20)
                    }
                }
            }
            .background(Color(hex: "F6FAF7"))
            .navigationTitle("我的海拔记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showHistory = false }
                }
            }
        }
    }
}

// MARK: - 远山插画（alt-landscape：三层山峦 + 云）

struct AltLandscapeArt: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // 远层山（最浅）
                Mountain(range: [0.95, 0.55, 0.78, 0.4, 0.72])
                    .fill(Color(hex: "D3E8DB").opacity(0.7))
                // 中层山
                Mountain(range: [1.0, 0.62, 0.5, 0.72, 0.34])
                    .fill(Color(hex: "BFDCCB").opacity(0.8))
                // 近层山（最深）
                Mountain(range: [0.72, 0.4, 0.85, 0.52, 1.0])
                    .fill(Color(hex: "A8CBB7"))
                // 云（两朵圆角长条）
                Cloud()
                    .frame(width: w * 0.22, height: h * 0.09)
                    .position(x: w * 0.24, y: h * 0.3)
                Cloud()
                    .frame(width: w * 0.16, height: h * 0.08)
                    .position(x: w * 0.7, y: h * 0.2)
            }
        }
        .clipped()
    }

    /// 山峦：以归一化高度采样点连成折线，闭合到底
    private struct Mountain: Shape {
        let range: [CGFloat]   // 0~1，相对 hero 高度的采样高度
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let n = range.count - 1
            path.move(to: CGPoint(x: 0, y: rect.height))
            for (i, v) in range.enumerated() {
                let x = rect.width * CGFloat(i) / CGFloat(n)
                let y = rect.height * (1 - v)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.closeSubpath()
            return path
        }
    }

    private struct Cloud: View {
        var body: some View {
            Capsule().fill(Color.white.opacity(0.8))
        }
    }
}
