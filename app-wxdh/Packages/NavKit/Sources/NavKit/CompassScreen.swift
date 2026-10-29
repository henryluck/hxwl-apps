import CoreLocation
import CoreKit
import SwiftUI

/// 罗盘：真实 heading、校准提示、传统/趣味视角、会员门槛（R-024/025/026/027）
struct CompassScreen: View {
    @ObservedObject var model: NavAppModel
    @State private var style: Style = .traditional
    @State private var showCalibration = false

    enum Style: String, CaseIterable {
        case traditional, fun
        var title: String { self == .traditional ? "传统" : "趣味" }
    }

    private var heading: Double? { model.location.heading }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "0E2A22"), Color(hex: "123A2E"), Color(hex: "0A1F19")],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            if !model.isUnlocked {
                lockedState
            } else {
                content
            }
        }
        .onAppear { model.location.startHeading() }
        .onDisappear { model.location.stopHeading() }
        // 未解锁时连续停留 10 秒自动提醒（关闭订阅页后重新计时）
        .autoPaywallReminder(active: !model.isUnlocked)
    }

    private var content: some View {
        VStack(spacing: 0) {
            screenHeader
            stylePicker
            Spacer(minLength: 0)
            dial
            Spacer(minLength: 0)
            detailCard
        }
        .padding(.bottom, 8)
    }

    private var screenHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("罗盘")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                Text(heading == nil ? "等待传感器…" : "方位实时更新")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Button {
                model.showProfile = true
            } label: {
                Image(systemName: "crown.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: "0E2A22"))
                    .frame(width: 36, height: 36)
                    .background(Color(hex: "CDE8DC"), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("会员中心")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var stylePicker: some View {
        HStack(spacing: 0) {
            ForEach(Style.allCases, id: \.self) { item in
                Button {
                    style = item
                } label: {
                    Text(item.title)
                        .font(.system(size: 13, weight: style == item ? .semibold : .regular))
                        .foregroundStyle(style == item ? Color(hex: "0E2A22") : .white.opacity(0.7))
                        .frame(width: 78, height: 32)
                        .background(style == item ? Color(hex: "CDE8DC") : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.white.opacity(0.12), in: Capsule())
        .padding(.top, 12)
    }

    // MARK: - 盘面

    private var dial: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.18), lineWidth: 1)
                .frame(width: 268, height: 268)

            ForEach(0..<72) { tick in
                Rectangle()
                    .fill(.white.opacity(tick % 6 == 0 ? 0.55 : 0.22))
                    .frame(width: tick % 6 == 0 ? 1.6 : 0.8,
                           height: tick % 6 == 0 ? 12 : 6)
                    .offset(y: -126)
                    .rotationEffect(.degrees(Double(tick) * 5))
            }

            // 四正方位：按极坐标摆放，文字保持正向
            ForEach(cardinals, id: \.text) { item in
                Text(item.text)
                    .font(.system(size: item.size, weight: .semibold))
                    .foregroundStyle(item.text == "北" ? Color(hex: "FF8A7A") : .white.opacity(0.85))
                    .offset(x: 96 * sin(item.angle * .pi / 180),
                            y: -96 * cos(item.angle * .pi / 180))
            }

            // 指针：指北
            VStack(spacing: 0) {
                Triangle()
                    .fill(Color(hex: "FF8A7A"))
                    .frame(width: 16, height: 26)
                Rectangle()
                    .fill(.white.opacity(0.9))
                    .frame(width: 3, height: 92)
                Triangle()
                    .fill(.white.opacity(0.35))
                    .rotationEffect(.degrees(180))
                    .frame(width: 12, height: 18)
            }
            .rotationEffect(.degrees(-(heading ?? 0)))
            .animation(.easeOut(duration: 0.2), value: heading)

            // 中心读数：贴底，避免与指针重叠
            VStack(spacing: 2) {
                Text(heading.map { String(format: "%.0f°", $0) } ?? "--°")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(style == .traditional ? cardinalName(heading) : shanName(heading))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .offset(y: 66)
        }
        .frame(height: 300)
    }

    private var cardinals: [(text: String, angle: Double, size: CGFloat)] {
        [("北", 0, 15), ("东", 90, 14), ("南", 180, 14), ("西", 270, 14)]
    }

    private var detailCard: some View {
        VStack(spacing: 10) {
            HStack {
                detailItem(title: "真北", value: heading.map { String(format: "%.1f°", $0) } ?? "—")
                Divider().frame(height: 28).overlay(.white.opacity(0.15))
                detailItem(title: "磁北", value: model.location.magneticHeading.map { String(format: "%.1f°", $0) } ?? "—")
                Divider().frame(height: 28).overlay(.white.opacity(0.15))
                detailItem(title: "坐标",
                           value: model.location.snapshot.map {
                               NavFormat.coordinate($0.latitude, $0.longitude)
                           } ?? "—")
            }

            if style == .fun {
                VStack(alignment: .leading, spacing: 4) {
                    Text("民俗视角")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("当前方位对应传统二十四山「\(shanName(heading))」。民俗内容服务未接入，仅作文化娱乐，不用于出行判断。")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button {
                    showCalibration = true
                } label: {
                    Label("校准", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    model.location.startHeading()
                } label: {
                    Label("重新获取", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .alert("校准罗盘", isPresented: $showCalibration) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("将设备画“8”字缓慢转动 3-5 圈，远离磁铁、金属与电子设备，然后回到罗盘查看方位。")
        }
    }

    private func detailItem(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }

    private var lockedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.85))
            Text("完整罗盘为会员功能")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text("解锁后可查看实时方位、磁北/真北、坐标与校准")
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

    // MARK: - 方位命名

    private func cardinalName(_ value: Double?) -> String {
        guard let value else { return "待获取" }
        let names = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        let index = Int(((value + 22.5) / 45).rounded()) % 8
        return names[index]
    }

    /// 二十四山（真实几何划分，非虚构数据）
    private func shanName(_ value: Double?) -> String {
        guard let value else { return "待获取" }
        let names = ["子", "癸", "丑", "艮", "寅", "甲", "卯", "乙",
                     "辰", "巽", "巳", "丙", "午", "丁", "未", "坤",
                     "申", "庚", "酉", "辛", "戌", "乾", "亥", "壬"]
        let index = Int(((value + 7.5) / 15).rounded()) % 24
        return names[index]
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
