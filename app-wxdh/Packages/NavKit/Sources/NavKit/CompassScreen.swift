import CoreLocation
import CoreKit
import SwiftUI

/// 罗盘：对齐原型 classic-compass-view（R-024/025/026/027）
/// 结构：页头（罗盘 + 我的/会员）→ 视角切换 → 「手机当前朝向」→ 大号读数 →
/// 传统罗盘盘面（白面虚线内圈 40 刻度菱形双色指针）→ 地点/坐标 → 真北磁北 →
/// 提示文案 → 「方位设置与校准」按钮（弹校准面板）。
struct CompassScreen: View {
    @ObservedObject var model: NavAppModel
    @State private var style: Style = .classic
    @State private var showCalibration = false
    @State private var showHelp = false

    enum Style: String, CaseIterable {
        case classic, fun
        var title: String { self == .classic ? "传统罗盘" : "趣味主题" }
    }

    private var heading: Double? { model.location.heading }
    private var snapshot: LocationSnapshot? { model.location.snapshot }

    /// heading 有效性：nil 或精度 <0 一律视为待校准（原型 valid:!y）
    private var headingValid: Bool {
        model.location.magneticHeading != nil || heading != nil
    }

    var body: some View {
        ZStack {
            // 原型 daily-compass：#f4f8f0 浅绿纸感底
            Color(hex: "F4F8F0").ignoresSafeArea()

            if !model.isUnlocked {
                lockedState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        stylePicker
                            .padding(.top, 6)
                        if style == .classic {
                            classicView
                        } else {
                            funView
                        }
                        helpButton
                            .padding(.top, 10)
                            .padding(.bottom, 18)
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .onAppear {
            // 罗盘 heading 依赖 WhenInUse 权限：notDetermined 时先触发系统弹窗，
            // 否则 startUpdatingHeading 永远不回调（"原地转圈方向不动"的根因之一）
            if model.location.authState == .notDetermined {
                model.location.requestAuthorization()
            }
            model.location.startHeading()
        }
        .onDisappear { model.location.stopHeading() }
        // 未解锁时连续停留 10 秒自动提醒（关闭订阅页后重新计时）
        .autoPaywallReminder(active: !model.isUnlocked)
        .sheet(isPresented: $showCalibration) { calibrationSheet }
        .alert("使用说明", isPresented: $showHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("传统罗盘用于辨认手机朝向，手持时远离金属或磁性物品。\n民俗文化内容仅供娱乐，无科学预测依据，不作为出行决策依据。")
        }
    }

    // MARK: - 视角切换（compass-view-switch）

    private var stylePicker: some View {
        HStack(spacing: 0) {
            ForEach(Style.allCases, id: \.self) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { style = item }
                } label: {
                    HStack(spacing: 6) {
                        if item == .fun {
                            Image(systemName: "sparkles")
                                .font(.system(size: 13))
                        }
                        Text(item.title)
                            .font(.system(size: 16, weight: style == item ? .semibold : .regular))
                    }
                    .foregroundStyle(style == item ? Color(hex: "247255") : Color(hex: "5A705A"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        // 原型：选中白底圆角 13 + 轻投影
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(style == item ? Color.white : .clear)
                            .shadow(color: style == item ? Color(hex: "375138").opacity(0.06) : .clear,
                                    radius: 4, y: 2)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(style == item ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(Color(hex: "E6EFE5"), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    // MARK: - 传统罗盘视图（classic-compass-view）

    private var classicView: some View {
        VStack(spacing: 0) {
            Text("手机当前朝向")
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: "627862"))

            // 大号读数：方向名 30pt semibold + 度数 25pt（原型 h2 + span）
            HStack(alignment: .firstTextBaseline, spacing: 13) {
                Text(headingValid ? cardinalName(heading) : "请先校准")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color(hex: "193E30"))
                Text(headingValid ? String(format: "%.0f°", heading ?? 0) : "")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(Color(hex: "497D5E"))
            }
            .padding(.vertical, 9)

            TraditionalCompassDial(heading: heading, valid: headingValid)
                .frame(width: 300, height: 300)
                .padding(.vertical, 12)

            // 地点 + 坐标（outdoor-compass-place / coordinates）
            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 14))
                Text(placeText)
                    .font(.system(size: 16))
                    .lineLimit(1)
            }
            .foregroundStyle(Color(hex: "3E6550"))
            .padding(.vertical, 5)

            Text(coordinateText)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(hex: "6B826D"))
                .padding(.top, 2)

            // 真北/磁北基线（classic-compass-baseline）
            Text(baselineText)
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "6B826D"))
                .padding(.top, 12)

            // 提示（classic-compass-tip）
            Text(tipText)
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: "54705B"))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.vertical, 18)

            // 方位设置与校准（daily-settings）
            Button {
                showCalibration = true
            } label: {
                Label("方位设置与校准", systemImage: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(hex: "41634F"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color(hex: "D5E4D3"), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
    }

    // MARK: - 趣味主题视图（fun-content-view）

    private var funView: some View {
        VStack(spacing: 14) {
            // 民俗日历头（fun-data-date + fun-lunar-date）
            HStack {
                Text(DateFormatter.dateString(Date()))
                    .font(.system(size: 19, weight: .medium))
                Spacer()
                Text("民俗日历")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(hex: "856628"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(hex: "F6EFD8"), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            Text(lunarSummary)
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: "688064"))
                .frame(maxWidth: .infinity, alignment: .leading)

            // 主方位卡（fun-direction-feature：米黄底大字 + 山形曲线装饰）
            ZStack(alignment: .bottomTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 9) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18))
                        Text("今日吉方")
                            .font(.system(size: 19, weight: .medium))
                    }
                    .foregroundStyle(Color(hex: "557848"))
                    Text(shanName(heading) + "方")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Color(hex: "346547"))
                        .padding(.top, 14)
                    Text("依据传统二十四山方位划分；民俗文化内容，仅供娱乐，不作为出行决策依据。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "6B7965").opacity(0.85))
                        .padding(.top, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                FunMountainArt()
                    .frame(width: 130, height: 100)
                    .padding(6)
            }
            .frame(maxWidth: .infinity, minHeight: 186, alignment: .topLeading)
            .padding(24)
            .background(Color(hex: "F9F9E9"), in: RoundedRectangle(cornerRadius: 25, style: .continuous))

            // 次方位对（fun-direction-pair：两白卡）
            HStack(spacing: 13) {
                funPairCard(title: "当前朝向", value: cardinalName(heading))
                funPairCard(title: "对向方位", value: oppositeCardinal(heading))
            }
        }
    }

    private func funPairCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: "6B7965"))
            Text(value)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color(hex: "346547"))
                .padding(.top, 13)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(21)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// 山形曲线装饰（原型 svg path 1:1）
    private struct FunMountainArt: View {
        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                Path { p in
                    // M10 93Q49 13 74 48t58-27M-12 107Q36 52 63 73t65-3（viewBox 130x110）
                    p.move(to: CGPoint(x: w * 10 / 130, y: h * 93 / 110))
                    p.addQuadCurve(to: CGPoint(x: w * 74 / 130, y: h * 48 / 110),
                                   control: CGPoint(x: w * 49 / 130, y: h * 13 / 110))
                    p.addQuadCurve(to: CGPoint(x: w * 132 / 130, y: h * 21 / 110),
                                   control: CGPoint(x: w * 103 / 130, y: h * 41 / 110))
                    p.move(to: CGPoint(x: -w * 12 / 130, y: h * 107 / 110))
                    p.addQuadCurve(to: CGPoint(x: w * 63 / 130, y: h * 73 / 110),
                                   control: CGPoint(x: w * 36 / 130, y: h * 52 / 110))
                    p.addQuadCurve(to: CGPoint(x: w * 128 / 130, y: h * 70 / 110),
                                   control: CGPoint(x: w * 90 / 130, y: h * 86 / 110))
                }
                .stroke(Color(hex: "C5DCAF"), lineWidth: 16)
                Circle()
                    .fill(Color(hex: "EEC975"))
                    .frame(width: 26, height: 26)
                    .position(x: w * 91 / 130, y: h * 27 / 110)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - 锁定态（compass-member-gate）

    private var lockedState: some View {
        VStack(spacing: 18) {
            Image(systemName: "safari.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color(hex: "386E4D"))
            Text("开启完整罗盘体验")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(hex: "386E4D"))
            Text("传统定向 · 趣味主题")
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: "526E61"))
                .padding(.bottom, 8)
            Button {
                _ = model.requireMembership()
            } label: {
                Text("开通会员查看罗盘")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color(hex: "087F5B"), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 25)
        .padding(.horizontal, 24)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity)
    }

    // MARK: - 校准面板（方位设置与校准）

    private var calibrationSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("校准罗盘")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color(hex: "193E30"))
                    Text("将设备画「8」字缓慢转动 3-5 圈，远离磁铁、金属与电子设备，然后回到罗盘查看方位。")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: "54705B"))
                        .lineSpacing(4)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: "FFF8E8"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(hex: "E8D5A8"), lineWidth: 1)
                }

                VStack(alignment: .leading, spacing: 8) {
                    calibrateRow("真北（GPS 航向）",
                                 heading.map { String(format: "%.1f°", $0) } ?? "—")
                    calibrateRow("磁北（磁力计）",
                                 model.location.magneticHeading.map { String(format: "%.1f°", $0) } ?? "—")
                    calibrateRow("北向基准", baselineText)
                }
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    model.location.startHeading()
                } label: {
                    Label("重新获取方位", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color(hex: "087F5B"), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                .buttonStyle(.plain)

                Text("水平持握设备，远离金属或磁性物品；真北需要定位服务返回航向，室内或信号弱时以磁北为准。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "69785E"))
                    .lineSpacing(3)
                Spacer()
            }
            .padding(20)
            .background(Color(hex: "F4F8F0").ignoresSafeArea())
            .navigationTitle("方位设置与校准")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showCalibration = false }
                }
            }
        }
    }

    private func calibrateRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "54705B"))
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(hex: "193E30"))
        }
    }

    // MARK: - 派生文案

    /// 使用说明入口（daily-help）
    private var helpButton: some View {
        Button {
            showHelp = true
        } label: {
            Text("使用说明与趣味主题说明")
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "69785E"))
        }
        .buttonStyle(.plain)
    }

    private var placeText: String {
        guard let snapshot else { return "当前位置暂不可用" }
        return snapshot.place.name.isEmpty ? "当前位置" : snapshot.place.name
    }

    private var coordinateText: String {
        guard let snapshot else { return "经纬度暂不可用" }
        return NavFormat.coordinate(snapshot.latitude, snapshot.longitude)
    }

    /// 真北判据：GPS 航向（heading）可用时显示真北，否则磁北（原型 x 判据的简化口径）
    private var baselineText: String {
        heading != nil ? "真北" : "磁北"
    }

    private var tipText: String {
        if !headingValid {
            return "水平持握手机，按提示进行校准。"
        }
        return "水平持握手机，轻松辨认方向。"
    }

    /// 八方位名（traditional 视角读数）
    private func cardinalName(_ value: Double?) -> String {
        guard let value else { return "待获取" }
        let names = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        let index = Int(((value + 22.5) / 45).rounded()) % 8
        return names[index]
    }

    private func oppositeCardinal(_ value: Double?) -> String {
        guard let value else { return "待获取" }
        let names = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
        let index = Int(((value + 22.5) / 45).rounded()) % 8
        return names[(index + 4) % 8]
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

    private var lunarSummary: String {
        let shan = shanName(heading)
        return "今日二十四山当值「\(shan)」，方位以罗盘实时读数为参照。"
    }
}

// MARK: - 传统罗盘盘面（原型 Sn 组件 1:1 还原 + 真实罗盘旋转交互）
///
/// viewBox 300×300：白底大圆(r121) + 虚线内圈(r100) + 40 根刻度（每 5 根长刻度，
/// 正北刻度橙色）+ 四正方位字 + 十字细线 + 双色菱形指针 + 白芯圆心。
///
/// 【旋转交互】手机转动时**表盘整体旋转**（marine 罗盘口径）：盘面按 -heading 反向旋转，
/// 让盘面「北」字/橙色北刻度始终指向真实世界的北；中央菱形指针固定朝上，作为朝向基准
/// （lubber line）。此前只转指针、表盘固定，观感不像真罗盘。
/// 角度用连续累加值（最短路径差分），避免 359°↔1° 跳变时表盘倒转一大圈。
struct TraditionalCompassDial: View {
    let heading: Double?
    let valid: Bool

    /// 表盘连续旋转角（已处理跨零跳变；正=顺时针）
    @State private var dialAngle: Double = 0

    /// heading → 表盘目标角的最短路径差分累加：
    /// 目标 = -heading（盘面北对准真实北）；每次取与当前角的带符号最短差值叠加，
    /// 保证 355° → 5° 只转 10° 而不是倒转 350°。
    private func updateContinuousAngle(_ newHeading: Double?) {
        guard let newHeading else { return }
        let target = -newHeading
        var delta = (target - dialAngle).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        dialAngle += delta
    }

    var body: some View {
        ZStack {
            // 白底圆 + 描边
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color(hex: "E0EADF"), lineWidth: 1))
                .frame(width: 242, height: 242)   // r121

            // 内虚线圈 r100
            Circle()
                .stroke(Color(hex: "E6EEE2"), style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
                .frame(width: 200, height: 200)

            // 【旋转层】刻度 + 四正方位字 + 十字线随 heading 反向旋转
            Group {
                // 40 刻度：rotate(t*9)，长刻度 v13 / 短刻度 v6；0 号刻度橙色（北）
                ForEach(0..<40, id: \.self) { tick in
                    Capsule()
                        .fill(tick == 0 ? Color(hex: "D48E32") : Color(hex: "8CA893"))
                        .frame(width: tick % 5 == 0 ? 2 : 1,
                               height: tick % 5 == 0 ? 13 : 6)
                        .offset(y: -143.5 + (tick % 5 == 0 ? 6.5 : 3))
                        .rotationEffect(.degrees(Double(tick) * 9))
                }

                // 四正方位字：北上 东右 南下 西左（17pt，北橙其余青灰）
                Group {
                    compassLabel("北", offset: CGSize(width: 0, height: -139), color: Color(hex: "A96320"))
                    compassLabel("东", offset: CGSize(width: 139, height: 0), color: Color(hex: "597461"))
                    compassLabel("南", offset: CGSize(width: 0, height: 139), color: Color(hex: "597461"))
                    compassLabel("西", offset: CGSize(width: -139, height: 0), color: Color(hex: "597461"))
                }

                // 十字细线
                Path { p in
                    p.move(to: CGPoint(x: 150, y: 16))
                    p.addLine(to: CGPoint(x: 150, y: 284))
                    p.move(to: CGPoint(x: 16, y: 150))
                    p.addLine(to: CGPoint(x: 284, y: 150))
                }
                .stroke(Color(hex: "E0ECE3"), lineWidth: 1)
                .frame(width: 300, height: 300)
            }
            .rotationEffect(.degrees(dialAngle))
            // 弹簧跟随：无 duration 阻尼自动适配，快速转动手腕跟得上，
            // 缓慢转动也不会逐帧抖动（比固定 0.2s easeOut 平滑且实时）
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.85), value: dialAngle)
            .onAppear { dialAngle = -(heading ?? 0) }   // 首帧直接落位，不做大角度扫动
            .onChange(of: heading) { newHeading in
                updateContinuousAngle(newHeading)
            }

            if valid {
                // 【固定层】双色菱形指针固定朝上：深绿半朝向屏幕顶 = 手机当前朝向
                //（marine 罗盘 lubber line 口径；北在哪看盘面橙色刻度/「北」字）
                VStack(spacing: 0) {
                    // 北半：m150 61 17 89-17-9-17 9Z（尖朝上、深绿）
                    DiamondHalf()
                        .fill(Color(hex: "298267"))
                        .frame(width: 34, height: 89)
                    Color.clear
                        .frame(height: 0)
                    // 南半：m150 239 17-89-17 9-17-9Z（尖朝下、浅绿）
                    DiamondHalf()
                        .fill(Color(hex: "CEDFD4"))
                        .frame(width: 34, height: 89)
                        .rotationEffect(.degrees(180))
                }
                .frame(width: 34, height: 178)
                .overlay(
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color(hex: "32795E"), lineWidth: 2))
                        .frame(width: 14, height: 14)
                )
            } else {
                Text("等待校准")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color(hex: "9D702E"))
            }
        }
        .frame(width: 300, height: 300)
        .accessibilityLabel(valid ? "罗盘，当前朝向\(Int(heading ?? 0))度" : "罗盘，等待校准")
    }

    private func compassLabel(_ text: String, offset: CGSize, color: Color) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(color)
            .offset(offset)
    }
}

/// 菱形半边：底边在底部、尖端朝上（原型 path 的几何）
struct DiamondHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // 尖端：底边中点上方（对应 m150 61 → 尖 y=61，两腰到 y=150，中心内凹 -9）
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 9))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

extension DateFormatter {
    /// 2026.11.13 样式（fun-data-date b）
    static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd"
        return f.string(from: date)
    }
}
