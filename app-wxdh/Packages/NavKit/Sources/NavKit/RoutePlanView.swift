import CoreLocation
import SwiftUI

/// 路线方案页：地图优先，默认收起方案卡片，三方式与开始始终可见（NAV-16/17/18/20/21）
struct RoutePlanView: View {
    @ObservedObject var model: NavAppModel
    @State private var expanded = false
    @State private var editingField: SearchTarget?
    @State private var draft = ""
    @State private var candidates: [Place] = []
    @State private var candidateTask: Task<Void, Never>?
    @State private var startFailure: NavFailure?
    @State private var starting = false
    @State private var showAllResults = false

    private var isDirty: Bool {
        guard let editing = editingField else { return false }
        let confirmed = editing == .origin ? (model.origin?.name ?? "我的位置")
                                           : (model.destination?.name ?? "")
        return draft.trimmingCharacters(in: .whitespaces) != confirmed
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                NavMapView(controller: model.mapController,
                           satellite: false,
                           showsUserLocation: true) { }
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                }

                VStack {
                    Spacer(minLength: 0)
                    bottomCard(maxHeight: proxy.size.height * 0.55)
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .background(NavTheme.bg)
        .task {
            if model.engine.routes.isEmpty, model.destination != nil {
                await model.plan()
            } else if let route = model.engine.selectedRoute {
                model.mapController.showRoute(route.polyline,
                                              origin: model.originDisplay,
                                              destination: model.destination)
                model.mapController.fitRoute()
            }
        }
    }

    // MARK: - 顶部起终点

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    back()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(NavTheme.ink)
                        .frame(width: 40, height: 40)
                        .background(NavTheme.panel, in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")

                VStack(spacing: 0) {
                    fieldRow(target: .origin)
                    Divider().overlay(NavTheme.line).padding(.leading, 34)
                    fieldRow(target: .destination)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            if let editingField, !candidates.isEmpty {
                candidateList(for: editingField)
            }
        }
    }

    private func fieldRow(target: SearchTarget) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(target == .origin ? NavTheme.good : NavTheme.bad)
                .frame(width: 8, height: 8)
            if editingField == target {
                TextField(target == .origin ? "搜索起点" : "搜索目的地", text: $draft)
                    .font(.system(size: 15))
                    .submitLabel(.search)
                    .onSubmit { Task { await resolveDraft(target) } }
                    .onChange(of: draft) { text in
                        scheduleCandidates(text)
                    }
                Button {
                    cancelEditing()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(NavTheme.inkMute)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消编辑")
            } else {
                Button {
                    beginEditing(target)
                } label: {
                    HStack(spacing: 6) {
                        Text(displayText(for: target))
                            .font(.system(size: 15, weight: target == .destination ? .semibold : .regular))
                            .foregroundStyle(NavTheme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundStyle(NavTheme.inkMute)
                    }
                    .frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(target == .origin ? "起点" : "终点")：\(displayText(for: target))")
            }
        }
    }

    private func candidateList(for target: SearchTarget) -> some View {
        VStack(spacing: 0) {
            ForEach(candidates.prefix(6)) { place in
                Button {
                    applyCandidate(place, target: target)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(NavTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(NavTheme.ink)
                                .lineLimit(1)
                            Text(place.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(NavTheme.inkMute)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(NavTheme.line).padding(.leading, 32)
            }
            Button {
                showAllResults = true
            } label: {
                Text("查看全部结果")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NavTheme.accentDeep)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
            }
            .buttonStyle(.plain)
        }
        .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.horizontal, 12)
    }

    // MARK: - 底部卡片

    private func bottomCard(maxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            modeTabs
            Divider().overlay(NavTheme.line)

            if isDirty {
                dirtyHint
            } else if case .failed(let failure) = model.engine.phase {
                NavFailureView(failure: failure) { action in
                    handle(action)
                }
            } else if expanded {
                routeList
            }

            summaryRow
            startArea
        }
        .background(NavTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 18, y: -2)
        .frame(maxHeight: maxHeight, alignment: .bottom)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .sheet(isPresented: $showAllResults) {
            SearchView(model: model)
        }
    }

    private var modeTabs: some View {
        HStack(spacing: 8) {
            ForEach(TravelMode.allCases, id: \.self) { mode in
                Button {
                    Task {
                        await model.changeMode(mode)
                        expanded = false
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 16, weight: .semibold))
                        Text(mode.title)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(model.mode == mode ? .white : NavTheme.inkSoft)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(model.mode == mode ? NavTheme.accent : NavTheme.bg,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.title)路线")
                .accessibilityAddTraits(model.mode == mode ? [.isSelected] : [])
            }
        }
        .padding(10)
    }

    private var routeList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.engine.routes) { route in
                    Button {
                        model.selectRoute(route.id)
                        expanded = false
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(route.engineLabel)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(NavTheme.accentDeep)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(NavTheme.accentSoft, in: Capsule())
                                    Text(route.timeText)
                                        .font(.system(size: 17, weight: .bold))
                                        .foregroundStyle(NavTheme.ink)
                                }
                                Text("\(route.distanceText) · \(route.arrivalText) 到达")
                                    .font(.system(size: 13))
                                    .foregroundStyle(NavTheme.inkMute)
                            }
                            Spacer(minLength: 0)
                            if model.engine.selectedRouteId == route.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(NavTheme.accent)
                            }
                        }
                        .padding(12)
                        .background(model.engine.selectedRouteId == route.id
                                    ? NavTheme.accentSoft.opacity(0.7) : NavTheme.bg,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 220)
    }

    private var summaryRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                if let route = model.engine.selectedRoute {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(route.timeText) · \(route.distanceText)")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(NavTheme.ink)
                        Text("预计 \(route.arrivalText) 到达")
                            .font(.system(size: 12))
                            .foregroundStyle(NavTheme.inkMute)
                    }
                } else if model.engine.phase == .planning {
                    Text("正在规划路线…")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NavTheme.inkSoft)
                } else {
                    Text("暂无可用方案")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NavTheme.inkSoft)
                }
                Spacer(minLength: 0)
                if !model.engine.routes.isEmpty {
                    HStack(spacing: 4) {
                        Text(expanded ? "收起" : "\(model.engine.routes.count)条方案")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: expanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(NavTheme.accentDeep)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.engine.routes.isEmpty)
    }

    private var startArea: some View {
        VStack(spacing: 8) {
            if let startFailure {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(startFailure.title)
                        .font(.system(size: 13))
                    Spacer()
                    if startFailure == .locationUnavailable || startFailure == .weakLocation {
                        Button("重试定位") { Task { await model.locate() } }
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .foregroundStyle(NavTheme.bad)
                .padding(.horizontal, 4)
            }

            NavPrimaryButton(title: startButtonTitle,
                             systemImage: "location.north.fill",
                             enabled: canStart,
                             loading: starting) {
                Task { await start() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    private var canStart: Bool {
        !isDirty && model.engine.selectedRoute != nil && model.engine.phase == .ready
    }

    private var startButtonTitle: String {
        if isDirty { return "请先选择新的目的地" }
        switch model.engine.phase {
        case .planning: return "正在规划…"
        case .starting: return "正在准备导航…"
        default: return "开始导航"
        }
    }

    private var dirtyHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
            Text("请先选择新的目的地")
                .font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .foregroundStyle(NavTheme.warn)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(NavTheme.warn.opacity(0.08))
    }

    // MARK: - 动作

    private func back() {
        if model.planSource == .nearby, model.nearbyCategory != nil {
            model.backToNearbyList()
        } else {
            model.flow = .home
        }
    }

    private func beginEditing(_ target: SearchTarget) {
        editingField = target
        draft = target == .origin ? (model.origin?.name ?? "") : (model.destination?.name ?? "")
        candidates = []
    }

    private func cancelEditing() {
        // 取消恢复原对象、线与选择（NAV-11）
        candidateTask?.cancel()
        editingField = nil
        draft = ""
        candidates = []
    }

    private func scheduleCandidates(_ text: String) {
        candidateTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            candidates = []
            return
        }
        candidateTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let center = model.location.snapshot?.place.gcj02Coordinate
            let outcome = await model.search.search(query: trimmed,
                                                    scope: model.searchScope,
                                                    center: center)
            guard !Task.isCancelled else { return }
            candidates = outcome.results
        }
    }

    private func resolveDraft(_ target: SearchTarget) async {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let first = candidates.first {
            applyCandidate(first, target: target)
        } else {
            let outcome = await model.search.search(query: trimmed,
                                                    scope: model.searchScope,
                                                    center: model.location.snapshot?.place.gcj02Coordinate)
            if let place = outcome.results.first {
                applyCandidate(place, target: target)
            }
        }
    }

    private func applyCandidate(_ place: Place, target: SearchTarget) {
        candidateTask?.cancel()
        if target == .destination {
            model.destination = place
        } else {
            model.origin = place
        }
        model.stores.addHistory(place)
        editingField = nil
        draft = ""
        candidates = []
        startFailure = nil
        // 确认后地址/站点卡/坐标/路线同时更新（NAV-14）
        Task { await model.plan() }
    }

    private func start() async {
        guard canStart else { return }
        starting = true
        startFailure = nil
        let failure = await model.startNavigation()
        starting = false
        if let failure { startFailure = failure }
    }

    private func handle(_ action: NavFailureAction) {
        switch action {
        case .retry:
            Task { await model.plan() }
        case .retryLocation:
            Task { await model.locate() }
        case .openSettings:
            model.location.openAppSettings()
        case .pickPlace:
            beginEditing(.destination)
        case .unlock:
            _ = model.requireMembership()
        }
    }

    private func displayText(for target: SearchTarget) -> String {
        switch target {
        case .origin:
            return model.origin?.name ?? "我的位置"
        case .destination:
            return model.destination?.name ?? "选择目的地"
        }
    }
}
