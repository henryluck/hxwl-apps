import CoreKit
import MapKit
import SwiftUI

/// 导航首页：全屏真实地图（首次默认卫星），标题/检索/图层/定位/分类叠在地图上（NAV-01/02/12）
struct NavigateHomeView: View {
    @ObservedObject var model: NavAppModel
    @State private var showTools = false
    @State private var showSavedPlaces = false

    var body: some View {
        ZStack(alignment: .top) {
            NavMapView(controller: model.mapController,
                       satellite: model.satellite,
                       showsUserLocation: true)
                .ignoresSafeArea()

            // 顶部压暗：保证标题/状态在卫星底图上可读（NAV-01 对比度）
            LinearGradient(colors: [.black.opacity(0.42), .black.opacity(0.0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 170)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                header
                searchBar
                Spacer(minLength: 0)
                bottomPanel
            }
            .padding(.top, 6)
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

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("智能卫星导航")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                Text(model.locationChip.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.locationChip.ok ? Color.white.opacity(0.95)
                                                          : Color(hex: "FFE1A8"))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
            Spacer()
            Button {
                model.showProfile = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.isUnlocked ? "crown.fill" : "person.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.isUnlocked ? "会员" : "我的")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(NavTheme.accentDeep)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(.white.opacity(0.94), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isUnlocked ? "会员中心" : "我的")
        }
        .padding(.horizontal, 16)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Button {
                model.openSearch(target: .destination)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NavTheme.inkMute)
                    Text(model.destination?.name ?? "搜索目的地、公交站、地铁站")
                        .font(.system(size: 15))
                        .foregroundStyle(model.destination == nil ? NavTheme.inkMute : NavTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索目的地")

            Button {
                model.satellite.toggle()
                model.mapController.setMapType(satellite: model.satellite)
            } label: {
                Image(systemName: model.satellite ? "globe.asia.australia.fill" : "map.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NavTheme.accentDeep)
                    .frame(width: 46, height: 46)
                    .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.satellite ? "切换标准地图" : "切换卫星地图")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - 底部

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(NavTheme.accent)
                Text(model.locationChip.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NavTheme.inkSoft)
                Spacer()
                Button {
                    Task { await model.locate() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "location.circle.fill")
                        Text("重新定位")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NavTheme.accentDeep)
                }
                .buttonStyle(.plain)
                .disabled(model.locating)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(NavTheme.panel.opacity(0.96), in: Capsule())

            VStack(spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                          spacing: 8) {
                    ForEach(NearbyCategory.allCases) { category in
                        categoryButton(category)
                    }
                }
                HStack(spacing: 8) {
                    toolButton(title: "常用地点", icon: "bookmark.fill") { showSavedPlaces = true }
                    toolButton(title: "出行工具", icon: "wrench.and.screwdriver.fill") { showTools = true }
                }
            }
            .padding(12)
            .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 16, y: 4)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func categoryButton(_ category: NearbyCategory) -> some View {
        Button {
            guard model.requireMembership() else { return }
            model.openNearby(category)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: category.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(NavTheme.accent)
                Text(category.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NavTheme.ink)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(NavTheme.accentSoft.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("周边\(category.title)")
    }

    private func toolButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(NavTheme.inkSoft)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(NavTheme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
