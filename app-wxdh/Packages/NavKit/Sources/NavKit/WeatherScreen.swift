import CoreLocation
import CoreKit
import SwiftUI

/// 天气：真实实况与预报、独立地区选择、免费仅现在/今天（R-019/020/021/022/023）
/// 视觉对齐交付原型「gentle-weather」（v0.25）：
///   · 上半屏实景照片 + 深绿渐变遮罩，白色文字（标题栏/城市/日期/大温度/现象/风/体感湿度）
///   · 下半屏白色大卡（圆角 22、水平边距 16）：日出日落两列 → 逐小时/最近7天分段条 → 内容
///   · 未订阅：现在/今天以外的时段模糊（blur 5 + 降透明度），中央「👑 解锁会员」浮层
struct WeatherScreen: View {
    @ObservedObject var model: NavAppModel
    @ObservedObject private var service: WeatherService
    /// 【Bug 行17】stores 虽非 ObservableObject，但需持有引用以便 sheet 关闭后读取最新地区；
    /// 刷新触发点在 onDismiss（见 body）
    private let stores: NavStores
    @State private var showRegionPicker = false
    @State private var segment: Segment = .hourly
    @State private var lastSeenRegionId: String?

    private enum Segment: String, CaseIterable {
        case hourly
        case daily

        var title: String {
            switch self {
            case .hourly: return "逐小时"
            case .daily: return "最近7天"
            }
        }
    }

    init(model: NavAppModel) {
        self.model = model
        self.service = model.weather
        self.stores = model.stores
    }

    private var region: WeatherRegion? { model.stores.weatherRegion }

    var body: some View {
        ZStack {
            backgroundLayer.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    scenerySection
                    contentCard
                }
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showRegionPicker, onDismiss: {
            // 【Bug 行17】切换地区后刷新页面：stores 非 ObservableObject，
            // 选择结果不会自动通知本页；对比 id 变化了才重载，避免无谓请求
            let current = stores.weatherRegion?.id
            if current != lastSeenRegionId {
                lastSeenRegionId = current
                Task { await reload() }
            }
        }) {
            WeatherRegionPicker(model: model)
        }
        .task {
            if region == nil { await useDeviceRegionIfPossible() }
            if service.snapshot == nil { await reload() }
            lastSeenRegionId = region?.id
        }
    }

    // MARK: - 背景（实景照片 + 原型同款渐变遮罩）

    /// 照片铺满 + 遮罩：上深（保证白字可读）→ 中部渐透明 → 底部淡出为卡片区的浅绿背景色
    /// 素材 assets/weather-bg.jpg：干净的云雾山峦带（从 alt-hero-photo 裁出，无文字）
    private var backgroundLayer: some View {
        ZStack {
            if let url = Bundle.main.resourceURL?.appendingPathComponent("assets/weather-bg.jpg"),
               let image = UIImage(contentsOfFile: url.path) {
                GeometryReader { geo in
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                // 照片缺失兜底：与照片色调一致的青绿渐变
                LinearGradient(colors: [Color(hex: "2E5D52"), Color(hex: "6C9C8B"), Color(hex: "C8E4D4")],
                               startPoint: .top, endPoint: .bottom)
            }
            // 原型 gentle-shade：#0e3f3057 → 透明 → #ecfaf1，让卡片下方融入浅绿底
            LinearGradient(stops: [
                .init(color: Color(hex: "0E3F30").opacity(0.34), location: 0),
                .init(color: Color(hex: "123C2F").opacity(0.40), location: 0.24),
                .init(color: Color(hex: "2B6843").opacity(0.20), location: 0.40),
                .init(color: Color(hex: "E5F9EC").opacity(0.84), location: 0.58),
                .init(color: Color(hex: "ECFAF1"), location: 0.86),
            ], startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: - 上半屏：实景区（标题栏 + 城市/日期 + 实况）

    private var scenerySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageTitleBar
            locationHeader
            if let snapshot = service.snapshot {
                currentSection(snapshot)
            } else if service.failure != nil {
                sceneryFailure
            } else {
                Text("天气更新中…")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 40)
            }
        }
        .padding(.bottom, 18)  // 原型 gentle-content 上移 -18 的压叠空间
        // 原型 text-shadow: 0 1px 8px #163d2855
        .shadow(color: Color(hex: "163D28").opacity(0.33), radius: 8, x: 0, y: 1)
    }

    /// 顶部标题栏：原型「天气」+ 白色胶囊（我的 | 会员）——统一组件 AccountMemberCapsule
    private var pageTitleBar: some View {
        HStack {
            Text("天气")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            AccountMemberCapsule(model: model, onDarkBackground: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    /// 城市行（21pt + 下箭头）+ 日期行（含「· 当前位置」）
    private var locationHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showRegionPicker = true
            } label: {
                HStack(spacing: 4) {
                    Text(region?.display ?? "选择地区")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 27)

            HStack(spacing: 0) {
                Text(dateLine)
                if region != nil {
                    Text(" · 当前位置")
                }
            }
            .font(.system(size: 16))
            .foregroundStyle(.white)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }

    /// 「11月15日星期日」（原型日期格式）
    private var dateLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日EEEE"
        return f.string(from: Date())
    }

    /// 实况区：大温度（68pt 上标°）+ 右侧（现象 / 温度区间 / 风）+ 底部体感湿度
    private func currentSection(_ snapshot: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 23) {
                // 原型 gentle-temp：68pt 常规 + 34pt 上标 °
                (Text(String(format: "%.0f", snapshot.current.temperature))
                    .font(.system(size: 68, weight: .regular, design: .rounded))
                + Text("°")
                    .font(.system(size: 34, weight: .regular))
                    .baselineOffset(24))
                    .foregroundStyle(.white)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Int(snapshot.current.temperature.rounded()))度")

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 9) {
                        Image(systemName: WeatherCode.icon(snapshot.current.code))
                            .font(.system(size: 26))
                        Text(WeatherCode.text(snapshot.current.code))
                            .font(.system(size: 20, weight: .medium))
                    }
                    if let day = snapshot.days.first {
                        Text(String(format: "%.0f° ～ %.0f°", day.min, day.max))
                            .font(.system(size: 17))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "wind")
                            .font(.system(size: 15))
                        Text(windText(snapshot))
                            .font(.system(size: 17))
                    }
                    .foregroundStyle(.white.opacity(0.95))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 25)

            HStack(spacing: 24) {
                Text(String(format: "体感 %.0f°", snapshot.current.feelsLike))
                Text(String(format: "湿度 %.0f%%", snapshot.current.humidity))
            }
            .font(.system(size: 17))
            .foregroundStyle(.white.opacity(0.95))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 14)
        }
    }

    /// 照片区内的失败/加载兜底（重试按钮）
    private var sceneryFailure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(service.isLoading ? "天气更新中…" : "暂时无法获取天气")
                .font(.system(size: 18))
                .foregroundStyle(.white)
            if !service.isLoading {
                Button("重新获取") {
                    Task { await reload() }
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .underline()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 44)
    }

    /// 风级文案：快照只有风速 km/h → 按蒲福风级换算成「x级」（原型如「东北风 2级」）
    private func windText(_ snapshot: WeatherSnapshot) -> String {
        let kmh = snapshot.current.windSpeed
        let scale: Int
        switch kmh {
        case ..<1: scale = 0
        case ..<6: scale = 1
        case ..<12: scale = 2
        case ..<20: scale = 3
        case ..<29: scale = 4
        case ..<39: scale = 5
        case ..<50: scale = 6
        case ..<62: scale = 7
        default: scale = 8
        }
        return "\(scale)级"
    }

    // MARK: - 白色大卡：日出日落 + 分段 + 内容

    private var contentCard: some View {
        VStack(spacing: 0) {
            if let snapshot = service.snapshot {
                VStack(spacing: 0) {
                    sunRow(snapshot)
                    segmentBar
                    switch segment {
                    case .hourly: hourlyPane(snapshot)
                    case .daily: dailyPane(snapshot)
                    }
                    footerNote
                }
                .padding(.horizontal, 19)
                .padding(.top, 4)
            } else {
                // 无数据时保住卡片视觉（失败文案在照片区）
                Color.clear.frame(height: 30)
            }
        }
        .background(Color.white.opacity(0.96))
        .clipShape(RoundedCorners(radius: 22, corners: [.topLeft, .topRight]))
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .offset(y: -18)  // 原型 gentle-content：上移压住照片下缘
        .shadow(color: Color(hex: "245B3B").opacity(0.06), radius: 28, x: 0, y: 8)
    }

    /// 日出/日落（原型 gentle-sun：两列、青绿大图标 + 名称 + 时间）
    private func sunRow(_ snapshot: WeatherSnapshot) -> some View {
        HStack(spacing: 20) {
            sunCell(icon: "sunrise.fill", title: "日出", time: snapshot.sunrise.map(NavFormat.clock) ?? "—")
            sunCell(icon: "sunset.fill", title: "日落", time: snapshot.sunset.map(NavFormat.clock) ?? "—")
        }
        .padding(.vertical, 19)
    }

    private func sunCell(icon: String, title: String, time: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(Color(hex: "159A67"))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "4D6858"))
                Text(time)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color(hex: "193E30"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 分段条：浅绿底胶囊，选中白底绿字 + 小阴影（原型 gentle-segment）
    private var segmentBar: some View {
        HStack(spacing: 4) {
            ForEach(Segment.allCases, id: \.self) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { segment = item }
                } label: {
                    Text(item.title)
                        .font(.system(size: 17, weight: segment == item ? .semibold : .regular))
                        .foregroundStyle(segment == item ? NavTheme.accent : Color(hex: "4B6857"))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            Color.white.opacity(segment == item ? 1 : 0),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .shadow(color: Color(hex: "18532B").opacity(segment == item ? 0.05 : 0),
                                radius: 8, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(segment == item ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(Color(hex: "ECF8F0"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 逐小时（免费仅现在，其余锁定；原型 gentle-hours）

    /// 原型为 5 列均分网格（repeat(5, 1fr)，不滚动）：
    /// 已订阅显示 前 5 个小时；未订阅「现在」可见，第 2~5 列模糊 + 「解锁会员」浮层。
    private func hourlyPane(_ snapshot: WeatherSnapshot) -> some View {
        let hours = Array(snapshot.hours.prefix(5))
        let locked = !model.isUnlocked
        // 注意：必须单层 HStack 平铺 5 个 cell 才能均分宽度（嵌套会把「现在」分到 1/2）
        return HStack(alignment: .top, spacing: 0) {
            if let first = hours.first {
                hourCell(label: "现在", code: first.code, temp: first.temperature)
            }
            ForEach(Array(hours.dropFirst().enumerated()), id: \.element.id) { _, hour in
                hourCell(label: clockHour(hour.time), code: hour.code, temp: hour.temperature)
                    .blur(radius: locked ? 5 : 0)
                    .opacity(locked ? 0.55 : 1)
                    .allowsHitTesting(!locked)
            }
        }
        .overlay { if locked { unlockOverlay } }
        .padding(.vertical, 26)
        .frame(minHeight: 150, alignment: .top)
    }

    /// 原型 gentle-hour：时间 16pt 灰绿 / 图标绿色 / 温度 20pt medium 深墨色
    private func hourCell(label: String, code: Int, temp: Double) -> some View {
        VStack(spacing: 18) {
            Text(label)
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: "615E58"))
            Image(systemName: WeatherCode.icon(code))
                .font(.system(size: 24))
                .foregroundStyle(Color(hex: "159A67"))
            Text(String(format: "%.0f°", temp))
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color(hex: "302E2B"))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 7 天（免费仅今天，其余锁定；原型 weather-seven-days）

    private func dailyPane(_ snapshot: WeatherSnapshot) -> some View {
        let days = Array(snapshot.days.prefix(7))
        let locked = !model.isUnlocked
        return VStack(spacing: 0) {
            if let first = days.first {
                dayRow(label: "今天", code: first.code, range: first)
                    .padding(.vertical, 12)
            }
            if days.count > 1 {
                VStack(spacing: 0) {
                    ForEach(days.dropFirst()) { day in
                        dayRow(label: dayLabel(day.date), code: day.code, range: day)
                            .padding(.vertical, 12)
                    }
                }
                .blur(radius: locked ? 5 : 0)
                .opacity(locked ? 0.55 : 1)
                .allowsHitTesting(!locked)
                .overlay { if locked { unlockOverlay } }
            }
        }
        .padding(.vertical, 12)
    }

    /// 原型 weather-day-row：日期 17pt / 图标绿色 30pt 列 / 温度右对齐 17pt medium
    private func dayRow(label: String, code: Int, range: WeatherSnapshot.Day) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 17))
                .foregroundStyle(Color(hex: "302E2B"))
                .frame(width: 78, alignment: .leading)
            Image(systemName: WeatherCode.icon(code))
                .font(.system(size: 19))
                .foregroundStyle(Color(hex: "159A67"))
                .frame(width: 30)
            Text(WeatherCode.text(code))
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: "4A6656"))
            Spacer()
            Text(String(format: "%.0f° / %.0f°", range.max, range.min))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(hex: "302E2B"))
        }
        .frame(minHeight: 49)
    }

    /// 白卡底部合规说明
    private var footerNote: some View {
        Text("数据来源和风天气（经服务端安全代理）；地区与导航位置相互独立，切换天气城市不影响导航范围。")
            .font(.system(size: 11))
            .foregroundStyle(Color(hex: "526E5E").opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .padding(.bottom, 12)
    }

    /// 原型 weather-unlock-overlay：微白底 + 白底橘字「👑 解锁会员」胶囊
    private var unlockOverlay: some View {
        ZStack {
            Color(hex: "F4FCF7").opacity(0.22)
            Button {
                _ = model.requireMembership()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text("解锁会员")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(Color(hex: "B45418"))
                .padding(.horizontal, 17)
                .frame(minHeight: 46)
                .background(Color.white.opacity(0.96), in: Capsule())
                .shadow(color: Color(hex: "164C2C").opacity(0.07), radius: 16, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("解锁会员，查看完整预报")
        }
    }

    // MARK: - 数据

    private func reload() async {
        guard let region else { return }
        await service.load(latitude: region.latitude, longitude: region.longitude)
    }

    private func useDeviceRegionIfPossible() async {
        if let snap = model.location.snapshot {
            await adoptDeviceLocation(snap)
            return
        }
        if let fix = await model.location.requestSingleFix() {
            await adoptDeviceLocation(fix)
        }
    }

    private func adoptDeviceLocation(_ snapshot: LocationSnapshot) async {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: snapshot.latitude, longitude: snapshot.longitude)
        // 【Bug 行17】反编码失败不再静默退出——直接用坐标生成地区（名称兜底"当前位置"），
        // 保证选择动作总有结果；成功则用真实城市名
        let region: WeatherRegion
        if let placemark = try? await geocoder.reverseGeocodeLocation(location).first {
            region = WeatherRegion(id: "\(snapshot.latitude),\(snapshot.longitude)",
                                   name: placemark.locality ?? placemark.administrativeArea ?? "当前位置",
                                   district: placemark.subLocality ?? "",
                                   province: placemark.administrativeArea ?? "",
                                   latitude: snapshot.latitude,
                                   longitude: snapshot.longitude)
        } else {
            region = WeatherRegion(id: "\(snapshot.latitude),\(snapshot.longitude)",
                                   name: "当前位置",
                                   district: "",
                                   province: "",
                                   latitude: snapshot.latitude,
                                   longitude: snapshot.longitude)
        }
        model.stores.setWeatherRegion(region)
        await reload()
    }

    private func clockHour(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH时"
        return f.string(from: date)
    }

    private func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }
}

/// 仅指定角圆角（原型白卡只在顶部压出圆角，底部连向屏幕下缘）
struct RoundedCorners: Shape {
    var radius: CGFloat = 0
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let bezier = UIBezierPath(roundedRect: rect,
                                  byRoundingCorners: corners,
                                  cornerRadii: CGSize(width: radius, height: radius))
        return Path(bezier.cgPath)
    }
}

/// 天气地区选择：搜索 / 当前位置 / 最近（只写 weather 独立状态，R-021/022/023）
struct WeatherRegionPicker: View {
    @ObservedObject var model: NavAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?   // 【Bug 行10】可取消的搜索任务
    @State private var debounceWorkItem: DispatchWorkItem?
    /// 【Bug 行17】「使用当前位置」失败提示（定位权限/信号/反编码问题）
    @State private var alertMessage: String?
    @State private var locating = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(NavTheme.inkMute)
                    TextField("搜索城市或区县", text: $query)
                        .font(.system(size: 16))
                        .onChange(of: query) { text in
                            search(text)
                        }
                    if !query.isEmpty {
                        Button {
                            query = ""
                            results = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(NavTheme.inkMute)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(NavTheme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(12)

                List {
                    if searching {
                        HStack { ProgressView(); Text("搜索中…").foregroundStyle(NavTheme.inkMute) }
                    }
                    if query.isEmpty {
                        Section("快捷") {
                            Button {
                                guard !locating else { return }
                                locating = true
                                Task {
                                    await useDevice()
                                    locating = false
                                }
                            } label: {
                                HStack {
                                    Label("使用当前位置", systemImage: "location.fill")
                                    if locating { Spacer(); ProgressView() }
                                }
                            }
                            .disabled(locating)
                            if let region = model.stores.weatherRegion {
                                Button {
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text("最近：\(region.display)")
                                        Spacer()
                                        Image(systemName: "checkmark").foregroundStyle(NavTheme.accent)
                                    }
                                }
                            }
                        }
                    }
                    Section(query.isEmpty ? "选择地区" : "搜索结果") {
                        ForEach(results) { place in
                            Button {
                                model.stores.setWeatherRegion(
                                    WeatherRegion(id: place.id,
                                                  name: place.city.isEmpty ? place.name : place.city,
                                                  district: place.district.isEmpty ? place.name : place.district,
                                                  province: place.regionLabel,
                                                  latitude: place.latitude,
                                                  longitude: place.longitude))
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.name).foregroundStyle(NavTheme.ink)
                                    Text(place.subtitle).font(.system(size: 12)).foregroundStyle(NavTheme.inkMute)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("选择地区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("无法使用当前位置",
                   isPresented: Binding(
                       get: { alertMessage != nil },
                       set: { if !$0 { alertMessage = nil } }
                   )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // 【Bug 行10】修复闪退：原实现每敲一个字立即发起一次 MKLocalSearch，
        // 连续输入会瞬间并发多个检索；MapKit 并发检索超过约 5 个会直接 crash
        //（MKLocalSearch is not finished / too many concurrent）。
        // 修复：500ms 防抖 + 取消上一个在途搜索任务，同一时刻最多一个 MKLocalSearch。
        debounceWorkItem?.cancel()
        searchTask?.cancel()
        guard !trimmed.isEmpty else {
            results = []
            searching = false
            return
        }
        searching = true
        let work = DispatchWorkItem { [weak model] in
            guard let model else { return }
            searchTask = Task {
                let outcome = await model.search.search(query: trimmed, scope: .manual, center: nil)
                guard !Task.isCancelled else { return }
                results = outcome.results
                searching = false
            }
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func useDevice() async {
        // 【Bug 行17】真根因：requestSingleFix 内部 guard authState.isUsable，
        // 权限为 notDetermined 时直接返回 nil 且不弹授权窗——点击看起来"没反应"。
        // 修复：先等待授权结果（自动弹窗），按结果分别处理并给出可见反馈。
        let location = model.location
        let granted = await location.waitForAuthorization()
        guard granted else {
            // 用户拒绝/系统定位关闭/超时未响应
            location.refreshAuthState()
            alertMessage = location.authState.guidance ?? "未能获取定位授权，请稍后重试"
            return
        }
        guard let fix = await location.requestSingleFix() else {
            alertMessage = location.lastError?.title ?? "定位失败，请检查网络后重试"
            return
        }
        // 【Bug 行10】CLGeocoder 并发实例过多同样会 crash（与 MKLocalSearch 同类限制），
        // 单次调用即可；反编码失败时用坐标兜底生成地区，不再静默退出
        let geocoder = CLGeocoder()
        let coreLocation = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        let mark = try? await geocoder.reverseGeocodeLocation(coreLocation).first
        let name = mark.flatMap { $0.locality ?? $0.administrativeArea } ?? "当前位置"
        model.stores.setWeatherRegion(WeatherRegion(id: "\(fix.latitude),\(fix.longitude)",
                                                    name: name,
                                                    district: mark?.subLocality ?? "",
                                                    province: mark?.administrativeArea ?? "",
                                                    latitude: fix.latitude,
                                                    longitude: fix.longitude))
        dismiss()
    }
}
