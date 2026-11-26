import CoreLocation
import SwiftUI

/// 导航中：官方 AMapNaviView 全屏渲染 + 自研状态横幅（时距/重算/信号弱）
struct NavigatingView: View {
    @ObservedObject var model: NavAppModel
    @ObservedObject private var engine: NavEngine
    @ObservedObject private var navi = NaviService.shared

    init(model: NavAppModel) {
        self.model = model
        self.engine = model.engine
    }

    var body: some View {
        ZStack(alignment: .top) {
            // 官方导航视图：路线渲染/车标/跟随镜头全由 SDK 负责
            AMapNaviViewContainer(kind: modeKind) { view in
                // 挂载即注册数据通道（算路已配置 manager，这里补视图）
                navi.configure(kind: modeKind, naviView: view)
            }
            .ignoresSafeArea()

            VStack(spacing: 8) {
                maneuverBanner
                if engine.isWeakLocation {
                    statusChip("定位信号较弱，正在重新获取", color: NavTheme.warn)
                } else if navi.isRecalculating {
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
                        navi.lockCamera()
                        engine.setFollowing(true)
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
        .onDisappear {
            // 离开导航页：解除视图数据通道并销毁单例（官方 dealloc 规范）
            navi.teardown()
        }
    }

    private var modeKind: NaviViewKind {
        engine.session?.mode.naviKind ?? .drive
    }

    // MARK: - 下一动作横幅（数据来自官方 updateNaviInfo）

    private var maneuverBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: engine.maneuverIconName)
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
                Text(engine.maneuverText)
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

    // MARK: - 底部（剩余时距来自官方 liveInfo 镜像）

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
                    .background(NavTheme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                NavPrimaryButton(title: "完成",
                                 systemImage: "checkmark",
                                 enabled: true,
                                 loading: false) {
                    model.finishArrival()
                }
            }
            .padding(24)
            Spacer()
        }
        .background(NavTheme.bg)
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(NavTheme.ink)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(NavTheme.inkMute)
        }
    }
}
