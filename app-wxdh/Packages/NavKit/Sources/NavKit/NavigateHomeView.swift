import CoreKit
import MapKit
import SwiftUI

/// 导航首页：全屏真实地图（首次默认卫星）。
/// 视觉对齐 v0.25 交互原型 nav-v19：大标题 + 双胶囊账号区、通栏搜索、快捷入口、
/// 地图浮层（图层/定位）、底部「周边服务」彩色网格 + 出行方式分段。
struct NavigateHomeView: View {
    @ObservedObject var model: NavAppModel
    @State private var showTools = false
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
            TravelToolsScreen(model: model)
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
            HStack(spacing: 0) {
                Button {
                    model.showProfile = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("我的")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: "1E5038"))
                    .frame(height: 42)
                    .padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("我的")

                Rectangle()
                    .fill(Color(hex: "D7E7DD"))
                    .frame(width: 1, height: 17)

                Button {
                    if model.isUnlocked {
                        model.showProfile = true
                    } else {
                        model.requireMembership()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color(hex: "E9A51B"))
                        Text("会员")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(Color(hex: "B45418"))
                    .frame(height: 42)
                    .padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isUnlocked ? "会员中心" : "开通会员")
            }
            .background(Color.white, in: Capsule())
            .overlay(Capsule().stroke(Color(hex: "DCEBE1"), lineWidth: 1))
            .shadow(color: Color(hex: "214B34").opacity(0.14), radius: 12, y: 4)
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
        HStack(spacing: 10) {
            shortcutChip(icon: "bookmark", title: "常用地点") { showSavedPlaces = true }
            shortcutChip(icon: "wrench.and.screwdriver.fill", title: "出行工具") { showTools = true }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
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
