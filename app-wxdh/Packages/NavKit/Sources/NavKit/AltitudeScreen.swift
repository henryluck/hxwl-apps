import CoreLocation
import SwiftUI

/// 海拔：真实读数、坐标复制、本机记录（R-028/029/030/031）
struct AltitudeScreen: View {
    @ObservedObject var model: NavAppModel
    @State private var showRecordSheet = false
    @State private var showHistory = false
    @State private var note = ""
    @State private var copied = false

    private var snapshot: LocationSnapshot? { model.location.snapshot }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "123A2E"), Color(hex: "0E2A22")],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            if !model.isUnlocked {
                lockedState
            } else {
                content
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

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("海拔")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                        Text(snapshot.map { "更新于 \(NavFormat.clock($0.timestamp))" } ?? "等待定位…")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Button {
                        Task { await model.locate() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("重新定位")
                }

                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(snapshot.map { String(format: "%.0f", $0.altitude) } ?? "--")
                            .font(.system(size: 68, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("米")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Text(accuracyText)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack(spacing: 10) {
                    Button {
                        copyCoordinates()
                    } label: {
                        Label(copied ? "已复制" : "复制坐标", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        note = ""
                        showRecordSheet = true
                    } label: {
                        Label("记录", systemImage: "mappin.and.ellipse")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(hex: "0E2A22"))
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Color(hex: "CDE8DC"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(snapshot == nil)
                    .opacity(snapshot == nil ? 0.5 : 1)
                }

                VStack(alignment: .leading, spacing: 8) {
                    infoRow("当前坐标", snapshot.map { NavFormat.coordinate($0.latitude, $0.longitude) } ?? "—")
                    infoRow("水平精度", snapshot.map { String(format: "±%.0f 米", $0.horizontalAccuracy) } ?? "—")
                    infoRow("垂直精度", verticalAccuracyText)
                    infoRow("定位来源", "设备 GPS / 系统定位服务")
                }
                .padding(14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    showHistory = true
                } label: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("海拔记录")
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text("\(model.stores.altitudeRecords.count) 条")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Text("海拔为设备定位返回值，受遮挡与天气影响存在误差；本 App 不提供气压、含氧量等专业仪表数据。")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    private var accuracyText: String {
        guard let snapshot else { return "定位后显示读数" }
        if snapshot.verticalAccuracy < 0 { return "垂直精度未知" }
        return String(format: "垂直精度 ±%.0f 米", snapshot.verticalAccuracy)
    }

    private var verticalAccuracyText: String {
        guard let snapshot, snapshot.verticalAccuracy >= 0 else { return "未提供" }
        return String(format: "±%.0f 米", snapshot.verticalAccuracy)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
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

    private var recordSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                if let snapshot {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%.0f 米", snapshot.altitude))
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(NavTheme.ink)
                        Text(NavFormat.coordinate(snapshot.latitude, snapshot.longitude))
                            .font(.system(size: 12))
                            .foregroundStyle(NavTheme.inkMute)
                    }
                }
                TextField("备注（选填，最多 80 字）", text: $note, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(2...4)
                    .padding(12)
                    .background(NavTheme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onChange(of: note) { value in
                        if value.count > 80 { note = String(value.prefix(80)) }
                    }
                Spacer()
            }
            .padding(16)
            .navigationTitle("保存海拔记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showRecordSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveRecord() }
                        .disabled(snapshot == nil)
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

    private var historySheet: some View {
        NavigationStack {
            Group {
                if model.stores.altitudeRecords.isEmpty {
                    NavEmptyView(title: "还没有海拔记录", detail: "在海拔页点「记录」保存当前读数")
                } else {
                    List {
                        ForEach(model.stores.altitudeRecords) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(String(format: "%.0f 米", record.altitude))
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(NavTheme.ink)
                                    Spacer()
                                    Text(NavFormat.clock(record.createdAt))
                                        .font(.system(size: 12))
                                        .foregroundStyle(NavTheme.inkMute)
                                }
                                Text(NavFormat.coordinate(record.latitude, record.longitude))
                                    .font(.system(size: 12))
                                    .foregroundStyle(NavTheme.inkMute)
                                if !record.note.isEmpty {
                                    Text(record.note)
                                        .font(.system(size: 13))
                                        .foregroundStyle(NavTheme.inkSoft)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                model.stores.deleteAltitudeRecord(id: model.stores.altitudeRecords[index].id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("海拔记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showHistory = false }
                }
            }
        }
    }

    private var lockedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.85))
            Text("海拔与记录为会员功能")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text("解锁后可查看实时海拔、坐标并保存本机记录")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
            Button {
                _ = model.requireMembership()
            } label: {
                Text("解锁会员")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(hex: "0E2A22"))
                    .frame(width: 200, height: 48)
                    .background(Color(hex: "CDE8DC"), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 40)
    }
}
