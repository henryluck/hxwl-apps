import CoreLocation
import CoreKit
import SwiftUI

/// 天气：真实实况与预报、独立地区选择、免费仅现在/今天（R-019/020/021/022/023）
struct WeatherScreen: View {
    @ObservedObject var model: NavAppModel
    @ObservedObject private var service: WeatherService
    @State private var showRegionPicker = false

    init(model: NavAppModel) {
        self.model = model
        self.service = model.weather
    }

    private var region: WeatherRegion? { model.stores.weatherRegion }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "1C4B5A"), Color(hex: "123A46"), Color(hex: "0E2A33")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    header
                    if let failure = service.failure, service.snapshot == nil {
                        NavFailureView(failure: failure) { action in
                            switch action {
                            case .retry:
                                Task { await reload() }
                            case .openSettings:
                                model.location.openAppSettings()
                            default:
                                break
                            }
                        }
                    } else if let snapshot = service.snapshot {
                        heroCard(snapshot)
                        hourlySection(snapshot)
                        dailySection(snapshot)
                        Text("数据来源和风天气（经服务端安全代理）；地区与导航位置相互独立，切换天气城市不影响导航范围。")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        NavLoadingRow(text: "正在获取天气…")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showRegionPicker) {
            WeatherRegionPicker(model: model)
        }
        .task {
            if region == nil { await useDeviceRegionIfPossible() }
            if service.snapshot == nil { await reload() }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    showRegionPicker = true
                } label: {
                    HStack(spacing: 5) {
                        Text(region?.display ?? "选择地区")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
                Text(service.snapshot.map { "更新于 \(NavFormat.clock($0.fetchedAt))" } ?? "等待数据")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刷新天气")
        }
    }

    private func heroCard(_ snapshot: WeatherSnapshot) -> some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "%.0f°", snapshot.current.temperature))
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(WeatherCode.text(snapshot.current.code))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: WeatherCode.icon(snapshot.current.code))
                    .font(.system(size: 52))
                    .foregroundStyle(.white.opacity(0.9))
                    .symbolRenderingMode(.hierarchical)
            }

            HStack(spacing: 0) {
                metric("体感", String(format: "%.0f°", snapshot.current.feelsLike))
                metric("湿度", String(format: "%.0f%%", snapshot.current.humidity))
                metric("风速", String(format: "%.0f km/h", snapshot.current.windSpeed))
            }

            Divider().overlay(.white.opacity(0.15))

            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "sunrise.fill").foregroundStyle(Color(hex: "F2C46B"))
                    Text("日出 \(snapshot.sunrise.map(NavFormat.clock) ?? "—")")
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "sunset.fill").foregroundStyle(Color(hex: "E28A5A"))
                    Text("日落 \(snapshot.sunset.map(NavFormat.clock) ?? "—")")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.85))
        }
        .padding(16)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 逐小时（免费仅现在，其余会员）

    private func hourlySection(_ snapshot: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("逐小时预报", locked: !model.isUnlocked)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(snapshot.hours.prefix(24).enumerated()), id: \.element.id) { index, hour in
                        let locked = !model.isUnlocked && index > 0
                        VStack(spacing: 6) {
                            Text(index == 0 ? "现在" : clockHour(hour.time))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.7))
                            Image(systemName: WeatherCode.icon(hour.code))
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(locked ? 0.25 : 0.9))
                            Text(String(format: "%.0f°", hour.temperature))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(locked ? 0.25 : 1))
                        }
                        .frame(width: 52, height: 84)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .blur(radius: locked ? 4 : 0)
                        .accessibilityHidden(locked)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - 7 天（免费仅今天）

    private func dailySection(_ snapshot: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("最近 7 天", locked: !model.isUnlocked)

            VStack(spacing: 0) {
                ForEach(Array(snapshot.days.enumerated()), id: \.element.id) { index, day in
                    let locked = !model.isUnlocked && index > 0
                    HStack(spacing: 12) {
                        Text(index == 0 ? "今天" : dayLabel(day.date))
                            .font(.system(size: 14, weight: index == 0 ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(locked ? 0.3 : 1))
                            .frame(width: 62, alignment: .leading)
                        Image(systemName: WeatherCode.icon(day.code))
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(locked ? 0.25 : 0.85))
                        Text(WeatherCode.text(day.code))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(locked ? 0.3 : 0.8))
                            .frame(width: 72, alignment: .leading)
                        Spacer()
                        Text(String(format: "%.0f° / %.0f°", day.max, day.min))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(locked ? 0.3 : 1))
                    }
                    .padding(.vertical, 10)
                    .blur(radius: locked ? 3 : 0)
                    .accessibilityHidden(locked)
                    if index < snapshot.days.count - 1 {
                        Divider().overlay(.white.opacity(0.1))
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func sectionHeader(_ title: String, locked: Bool) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            if locked {
                Button {
                    _ = model.requireMembership()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                        Text("会员解锁").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: "0E2A33"))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color(hex: "CDE8DC"), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
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
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { return }
        let region = WeatherRegion(id: "\(snapshot.latitude),\(snapshot.longitude)",
                                   name: placemark.locality ?? placemark.administrativeArea ?? "当前位置",
                                   district: placemark.subLocality ?? "",
                                   province: placemark.administrativeArea ?? "",
                                   latitude: snapshot.latitude,
                                   longitude: snapshot.longitude)
        model.stores.setWeatherRegion(region)
        await reload()
    }

    private func clockHour(_ date: Date) -> String {
        let f = DateFormatter()
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

/// 天气地区选择：搜索 / 当前位置 / 最近（只写 weather 独立状态，R-021/022/023）
struct WeatherRegionPicker: View {
    @ObservedObject var model: NavAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searching = false

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
                                Task { await useDevice() }
                            } label: {
                                Label("使用当前位置", systemImage: "location.fill")
                            }
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
        }
    }

    private func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = []; return }
        searching = true
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let outcome = await model.search.search(query: trimmed, scope: .manual, center: nil)
            results = outcome.results
            searching = false
        }
    }

    private func useDevice() async {
        guard let fix = await model.location.requestSingleFix() else { return }
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        guard let mark = try? await geocoder.reverseGeocodeLocation(location).first else { return }
        model.stores.setWeatherRegion(WeatherRegion(id: "\(fix.latitude),\(fix.longitude)",
                                                    name: mark.locality ?? "当前位置",
                                                    district: mark.subLocality ?? "",
                                                    province: mark.administrativeArea ?? "",
                                                    latitude: fix.latitude,
                                                    longitude: fix.longitude))
        dismiss()
    }
}
