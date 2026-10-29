import CoreLocation
import SwiftUI

/// 导航中：真实跟随、下一动作、时距、语音、退出（NAV-22/23/27/34）
struct NavigatingView: View {
    @ObservedObject var model: NavAppModel
    @ObservedObject private var engine: NavEngine

    init(model: NavAppModel) {
        self.model = model
        self.engine = model.engine
    }

    var body: some View {
        ZStack(alignment: .top) {
            NavMapView(controller: model.mapController,
                       satellite: false,
                       showsUserLocation: true) {
                engine.setFollowing(false)
            }
            .ignoresSafeArea()

            VStack(spacing: 8) {
                maneuverBanner
                if engine.isWeakLocation {
                    statusChip("定位信号较弱，正在重新获取", color: NavTheme.warn)
                } else if case .rerouting = engine.phase {
                    statusChip("正在重新规划路线…", color: NavTheme.accent)
                }
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)

            if !engine.isFollowing {
                VStack {
                    Spacer()
                    Button {
                        if let snap = model.location.snapshot {
                            model.mapController.follow(snap.place.gcj02Coordinate,
                                                       heading: snap.course >= 0 ? snap.course : nil)
                            engine.setFollowing(true)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "location.fill")
                            Text("回到跟随")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(NavTheme.accentDeep)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(NavTheme.panel, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 168)
                }
            }
        }
        .onChange(of: model.location.snapshot) { snap in
            guard let snap, engine.isFollowing else { return }
            // 镜头随有效行进方向；朝向不可靠时沿用上一次镜头朝向（NAV-22）
            let heading = snap.course >= 0 && snap.speed > 1 ? snap.course : nil
            model.mapController.follow(snap.place.gcj02Coordinate, heading: heading)
        }
        .onAppear {
            // 进入导航即近距跟随（不从全览开始），并保证新地图视图重绘路线
            if let snap = model.location.snapshot, engine.isFollowing {
                model.mapController.follow(snap.place.gcj02Coordinate,
                                           heading: snap.course >= 0 && snap.speed > 1 ? snap.course : nil,
                                           animated: false)
            }
        }
        .onChange(of: engine.currentStepIndex) { _ in
            // 步骤推进后按新路线重新绘制（重算后 routeId 已变）
            if let route = engine.selectedRoute {
                model.mapController.showRoute(route.polyline,
                                              origin: engine.session?.origin,
                                              destination: engine.session?.destination)
            }
        }
    }

    // MARK: - 下一动作

    private var maneuverBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: maneuverIcon)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(NavTheme.accentDeep, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(engine.distanceToManeuver > 0
                     ? NavFormat.distance(engine.distanceToManeuver)
                     : "现在")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(NavTheme.ink)
                Text(engine.nextStep?.instruction ?? "沿当前道路继续前行")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NavTheme.inkSoft)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 3)
        .accessibilityElement(children: .combine)
    }

    private func statusChip(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NavTheme.ink)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(NavTheme.panel.opacity(0.96), in: Capsule())
    }

    // MARK: - 底部

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(NavFormat.distance(engine.remainingDistance))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(NavTheme.ink)
                    Text("剩余里程")
                        .font(.system(size: 11))
                        .foregroundStyle(NavTheme.inkMute)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(NavFormat.duration(engine.remainingTime))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(NavTheme.ink)
                    Text("预计 \(NavFormat.clock(engine.etaDate)) 到达")
                        .font(.system(size: 11))
                        .foregroundStyle(NavTheme.inkMute)
                }
                Spacer(minLength: 0)
                Button {
                    model.voice.setMuted(!model.voice.isMuted)
                } label: {
                    Image(systemName: model.voice.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(model.voice.isMuted ? NavTheme.inkMute : NavTheme.accentDeep)
                        .frame(width: 44, height: 44)
                        .background(NavTheme.bg, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.voice.isMuted ? "打开导航语音" : "静音导航语音")
            }

            HStack(spacing: 10) {
                Button {
                    model.exitNavigation()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                        Text("结束导航")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(NavTheme.bad)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(NavTheme.bad.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 14, y: 2)
    }

    private var maneuverIcon: String {
        let text = engine.nextStep?.instruction ?? ""
        if text.contains("左") && text.contains("前") { return "arrow.up.left" }
        if text.contains("右") && text.contains("前") { return "arrow.up.right" }
        if text.contains("左") { return "arrow.turn.up.left" }
        if text.contains("右") { return "arrow.turn.up.right" }
        if text.contains("掉头") { return "arrow.uturn.left" }
        if text.contains("环岛") { return "arrow.triangle.turn.up.right.circle" }
        if text.contains("到达") { return "flag.checkered" }
        if text.contains("楼梯") || text.contains("过街") { return "figure.walk" }
        return "arrow.up"
    }
}

/// 正常到达完成页（NAV-35/36）
struct ArrivalView: View {
    @ObservedObject var model: NavAppModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "flag.checkered.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(NavTheme.accent)

                Text("已到达目的地")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(NavTheme.ink)

                if let summary = model.arrivalSummary {
                    VStack(spacing: 8) {
                        Text(summary.destination.name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(NavTheme.ink)
                            .multilineTextAlignment(.center)
                        Text(summary.destination.subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(NavTheme.inkMute)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 18) {
                            statItem(title: "方式", value: summary.mode.title)
                            if summary.distance > 0 {
                                statItem(title: "行程", value: NavFormat.distance(summary.distance))
                            }
                            statItem(title: "用时", value: NavFormat.duration(summary.duration))
                        }
                        .padding(.top, 6)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .navCard()
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 10) {
                NavPrimaryButton(title: "完成", systemImage: "checkmark") {
                    model.finishArrival()
                }
                Button {
                    model.planAgain()
                } label: {
                    Text("再去此处")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NavTheme.accentDeep)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(NavTheme.bg.ignoresSafeArea())
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NavTheme.ink)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(NavTheme.inkMute)
        }
    }
}
