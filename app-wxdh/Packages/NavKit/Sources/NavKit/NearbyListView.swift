import CoreLocation
import SwiftUI

/// 周边类别列表：保留检索框、分类横条、100pt 行、20/40/45 分页（NAV-12/13/14）
struct NearbyListView: View {
    @ObservedObject var model: NavAppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            categoryBar
            Divider().overlay(NavTheme.line)
            list
        }
        .background(NavTheme.bg)
        .task {
            if model.nearbyPlaces.isEmpty, !model.nearbyLoading {
                await model.loadNearbyPage(reset: true)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.flow = .home
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(NavTheme.ink)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回首页")

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NavTheme.inkMute)
                    TextField("搜索\(model.nearbyCategory?.title ?? "周边")", text: $model.nearbyQuery)
                        .font(.system(size: 16))
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            searchFocused = false
                            model.flow = .search
                            model.openSearch(target: .destination, preset: model.nearbyQuery)
                            Task { await model.submitSearch() }
                        }
                    if !model.nearbyQuery.isEmpty {
                        Button {
                            model.nearbyQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(NavTheme.inkMute)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(NavTheme.line, lineWidth: 1))
            }
            .padding(.horizontal, 4)
        }
        .padding(.top, 2)
        .background(NavTheme.panel)
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(NearbyCategory.allCases) { category in
                    Button {
                        guard model.requireMembership() else { return }
                        model.openNearby(category)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: category.icon)
                                .font(.system(size: 12, weight: .semibold))
                            Text(category.title)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(model.nearbyCategory == category ? .white : NavTheme.inkSoft)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(model.nearbyCategory == category ? NavTheme.accent : NavTheme.bg,
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.nearbyCategory == category ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(NavTheme.panel)
    }

    @ViewBuilder
    private var list: some View {
        if model.nearbyLoading && model.nearbyPlaces.isEmpty {
            NavLoadingRow(text: "正在查找附近的\(model.nearbyCategory?.title ?? "地点")…")
            Spacer()
        } else if let failure = model.nearbyFailure, model.nearbyPlaces.isEmpty {
            NavFailureView(failure: failure) { action in
                switch action {
                case .retry:
                    Task { await model.loadNearbyPage(reset: true) }
                case .retryLocation:
                    Task { await model.locate() }
                case .openSettings:
                    model.location.openAppSettings()
                default:
                    break
                }
            }
            Spacer()
        } else if model.nearbyPlaces.isEmpty {
            NavEmptyView(title: "附近暂无可用的\(model.nearbyCategory?.title ?? "地点")",
                         detail: "可换个类别或稍后重试")
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.nearbyPlaces.enumerated()), id: \.element.id) { index, place in
                        PlaceRow(place: place, distance: distance(to: place), showsChevron: true) {
                            // 点一行直接到路线地图，无中间确认（NAV-12）
                            model.openNearbyRoute(place)
                        }
                        Divider().overlay(NavTheme.line).padding(.leading, 16)

                        if index == model.nearbyPlaces.count - 1 {
                            // 距底部 45pt 内触发追加（等于 45pt 不自动触发）
                            Color.clear
                                .frame(height: 45)
                                .onAppear {
                                    guard model.nearbyHasMore, !model.nearbyLoading else { return }
                                    Task { await model.loadNearbyPage() }
                                }
                        }
                    }

                    if model.nearbyLoading {
                        NavLoadingRow(text: "加载更多…")
                    } else if model.nearbyHasMore {
                        Button {
                            Task { await model.loadNearbyPage() }
                        } label: {
                            Text("加载更多")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(NavTheme.accentDeep)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("已显示全部 \(model.nearbyPlaces.count) 个")
                            .font(.system(size: 12))
                            .foregroundStyle(NavTheme.inkMute)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
            }
        }
    }

    private func distance(to place: Place) -> Double? {
        guard let snap = model.location.snapshot else { return nil }
        return Geo.distance(snap.place.gcj02Coordinate, place.gcj02Coordinate)
    }
}
