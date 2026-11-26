import CoreKit
import MapKit
import SwiftUI

/// 导航首页：全屏真实地图（首次默认卫星）。
/// 视觉对齐 v0.25 交互原型 nav-v19：大标题 + 双胶囊账号区、通栏搜索、快捷入口、
/// 地图浮层（图层/定位）、底部「周边服务」彩色网格 + 出行方式分段。
struct NavigateHomeView: View {
    @ObservedObject var model: NavAppModel
    @State private var showTools = false
    /// 【R-073-02】首页停车卡直达详情：sheet 弹出时指定工具页初始路由
    @State private var initialToolsRoute: TravelToolsScreen.Route?
    @State private var showSavedPlaces = false
    @State private var showLayerPicker = false

    var body: some View {
        ZStack(alignment: .top) {
            NavMapView(controller: model.mapController,
                       satellite: model.satellite,
                       showsUserLocation: true)
                .ignoresSafeArea()

            // 顶部提亮：卫星底图上仍保证深绿标题/白胶囊可读（原型 h1 白色 text-shadow）
            LinearGradient(colors: [.white.opacity(0.72), .white.opacity(0.28), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 210)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                searchBar
                shortcuts
                Spacer(minLength: 0)
                mapControls
                bottomPanel
            }
            .padding(.top, 8)
        }
        .sheet(isPresented: $showTools) {
            TravelToolsScreen(model: model, initialRoute: initialToolsRoute)
        }
        .sheet(isPresented: $showSavedPlaces) {
            SavedPlacesScreen(model: model)
        }
        .task {
            model.mapController.setMapType(satellite: model.satellite)
            if model.location.authState == .notDetermined {
                // 进入首页不强制索权，只做状态展示（NAV-03）
                model.location.refreshAuthState()
            }
            // 已授权时静默取一次位置把地图落到设备附近（不会再弹权限框）
            if model.location.authState.isUsable, model.location.snapshot == nil {
                await model.locate()
            } else if let snap = model.location.snapshot {
                model.mapController.fit(MKCoordinateRegion(
                    center: snap.place.gcj02Coordinate,
                    latitudinalMeters: 4000, longitudinalMeters: 4000))
            }
        }
        .onAppear {
            // 【Bug 行43·行51】首页地图不承载规划线：规划/导航残留的 overlay 一律清掉
            // （此前导航结束切 tab 回首页会看到上次导航线路）
            model.mapController.clearRoute()
        }
    }

    // MARK: - 顶部：大标题 + 「我的 / 会员」胶囊

    private var header: some View {
        HStack(spacing: 10) {
            Text("导航")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .italic()
                .foregroundStyle(Color(hex: "1E4D38"))
                .shadow(color: .white.opacity(0.95), radius: 8)
            Spacer(minLength: 0)
            AccountMemberCapsule(model: model, height: 42)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    private var searchBar: some View {
        Button {
            model.openSearch(target: .destination)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color(hex: "39604B"))
                Text(model.destination?.name ?? "今天想去哪里？")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(model.destination == nil ? Color(hex: "39604B") : NavTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color(hex: "DEECE2"), lineWidth: 1))
            .shadow(color: Color(hex: "255D35").opacity(0.10), radius: 14, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜索目的地")
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private var shortcuts: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                shortcutChip(icon: "bookmark", title: "常用地点") { showSavedPlaces = true }
                shortcutChip(icon: "wrench.and.screwdriver.fill", title: "出行工具") { showTools = true }
                Spacer(minLength: 0)
            }
            // 【R-073-01/03】保存停车后首页显示精简卡——受记录的 homeVisible 开关控制
            // （新建默认开；详情关闭后立即消失、开启立即恢复；无定时自动隐藏）
            if let parking = model.stores.parking, parking.homeVisible {
                parkingSummary(parking)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    /// 停车摘要卡：点击进入**同一条便签详情**（R-073-02）
    private func parkingSummary(_ parking: NavStores.ParkingNote) -> some View {
        Button {
            // R-073-02：直达详情（记录已被删除/读取失败时走工具空态——详情页自处理）
            initialToolsRoute = .parkingNote
            showTools = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "parkingsign.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(NavTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    let display = parking.note.trimmingCharacters(in: .whitespaces)
                    Text(display.isEmpty ? "已拍下停车位置" : display)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NavTheme.ink)
                        .lineLimit(1)
                    Text(parking.createdAt.map { "停车于 \(NavFormat.clock($0))" } ?? "时间未记录")
                        .font(.system(size: 11))
                        .foregroundStyle(NavTheme.inkMute)
                }
                Spacer(minLength: 0)
                if let data = parking.imageData,
                   let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 40)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NavTheme.inkMute)
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(hex: "E1EEE5"), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("停车记录摘要，点按查看")
    }

    private func shortcutChip(icon: String, title: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 16, weight: .medium))
                Text(title).font(.system(size: 16, weight: .medium))
            }
            .foregroundStyle(Color(hex: "235540"))
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color.white.opacity(0.96), in: Capsule())
            .overlay(Capsule().stroke(Color(hex: "E1EEE5"), lineWidth: 1))
            .shadow(color: Color(hex: "173F32").opacity(0.08), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - 地图浮层：地图类型标签 + 图层 / 定位

    private var mapControls: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.satellite ? "卫星地图" : "标准地图")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color(hex: "173F32").opacity(0.88),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if !model.locationChip.ok {
                    Text(model.locationChip.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(hex: "8A5A18"))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.92), in: Capsule())
                }
            }
            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { showLayerPicker.toggle() }
                } label: {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color(hex: "257457"))
                        .frame(width: 44, height: 44)
                        .background(Color.white,
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .shadow(color: Color(hex: "204B34").opacity(0.16), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换地图图层")

                Button {
                    Task { await model.locate() }
                } label: {
                    Image(systemName: model.locating ? "location.fill" : "scope")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color(hex: "257457"))
                        .frame(width: 44, height: 44)
                        .background(Color.white,
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .shadow(color: Color(hex: "204B34").opacity(0.16), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(model.locating)
                .accessibilityLabel("回到当前位置")
            }
            .overlay(alignment: .bottomTrailing) {
                if showLayerPicker {
                    layerPicker
                        .offset(y: -54)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private var layerPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("地图图层")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NavTheme.inkMute)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            layerOption(title: "卫星地图", desc: "地表纹理", selected: model.satellite) {
                applyLayer(satellite: true)
            }
            layerOption(title: "标准地图", desc: "道路与地点", selected: !model.satellite) {
                applyLayer(satellite: false)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 188)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
    }

    private func layerOption(title: String, desc: String, selected: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color(hex: "B9DBCA") : Color(hex: "E8F1EA"))
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(desc).font(.system(size: 11))
                        .foregroundStyle(NavTheme.inkMute)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(NavTheme.accentDeep)
                }
            }
            .foregroundStyle(NavTheme.ink)
            .padding(.horizontal, 12)
            .frame(height: 44)
        }
        .buttonStyle(.plain)
    }

    private func applyLayer(satellite: Bool) {
        model.satellite = satellite
        model.mapController.setMapType(satellite: satellite)
        withAnimation(.easeOut(duration: 0.18)) { showLayerPicker = false }
    }

    // MARK: - 底部：周边服务 + 出行方式

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("周边服务")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(hex: "234D39"))
                .padding(.bottom, 10)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                      spacing: 9) {
                ForEach(NearbyCategory.allCases) { category in
                    nearbyButton(category)
                }
            }

            Divider()
                .background(Color(hex: "DCE9E0"))
                .padding(.top, 12)

            HStack(spacing: 8) {
                ForEach(TravelMode.allCases, id: \.self) { mode in
                    travelModeButton(mode)
                }
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 17)
        .padding(.top, 15)
        .padding(.bottom, 12)
        .background(Color(hex: "FAFFFC").opacity(0.96),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color(hex: "28533C").opacity(0.10), radius: 18, y: 5)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func nearbyButton(_ category: NearbyCategory) -> some View {
        Button {
            guard model.requireMembership() else { return }
            model.openNearby(category)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: nearbyIcon(category))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 39, height: 39)
                    .background(nearbyColor(category),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(category.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(hex: "264D3B"))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 61)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("周边\(category.title)")
    }

    private func travelModeButton(_ mode: TravelMode) -> some View {
        let selected = model.mode == mode
        return Button {
            model.mode = mode
            model.openSearch(target: .destination)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.icon).font(.system(size: 17, weight: .medium))
                Text(mode.title).font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(Color(hex: "215C40"))
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(selected ? Color(hex: "F5F8E8") : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.title)导航")
    }

    /// 原型 An 分类色板：紫 / 金 / 棕 / 橙 / 蓝灰 / 绿
    private func nearbyColor(_ category: NearbyCategory) -> Color {
        switch category {
        case .charger: return Color(hex: "7961C5")
        case .fishingSpot: return Color(hex: "C39447")
        case .tackleShop: return Color(hex: "AE7337")
        case .hospital: return Color(hex: "E19547")
        case .gym: return Color(hex: "617999")
        case .park: return Color(hex: "469B62")
        }
    }

    private func nearbyIcon(_ category: NearbyCategory) -> String {
        switch category {
        case .charger: return "bolt.car.fill"
        case .fishingSpot: return "fish.fill"
        case .tackleShop: return "storefront.fill"
        case .hospital: return "plus"
        case .gym: return "dumbbell.fill"
        case .park: return "tree.fill"
        }
    }
}
