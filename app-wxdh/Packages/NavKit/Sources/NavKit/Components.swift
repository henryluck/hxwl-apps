import Capabilities
import CoreLocation
import Foundation
import SwiftUI

/// 统一返回栏（子流程顶部）
struct NavTopBar<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    let onBack: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(NavTheme.ink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(NavTheme.ink)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(NavTheme.inkMute)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 52)
        .background(NavTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(NavTheme.line).frame(height: 0.5)
        }
    }
}

extension NavTopBar where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, onBack: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, onBack: onBack) { EmptyView() }
    }
}

/// 地点行：名称 / 类别·地址 / 直线距离（NAV-09）
struct PlaceRow: View {
    let place: Place
    var distance: Double?
    var showsChevron = false
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(place.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(NavTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        if !place.category.isEmpty {
                            Text(place.category)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(NavTheme.accentDeep)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(NavTheme.accentSoft, in: Capsule())
                        }
                        Text(place.subtitle.isEmpty ? "地址待补充" : place.subtitle)
                            .font(.system(size: 15))
                            .foregroundStyle(NavTheme.inkMute)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if distance != nil || showsChevron {
                        HStack(spacing: 8) {
                            if let distance {
                                Text("直线 \(NavFormat.distance(distance))")
                                    .font(.system(size: 14))
                                    .foregroundStyle(NavTheme.inkMute)
                            }
                            if showsChevron {
                                Text("去这里")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(NavTheme.accent)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NavTheme.inkMute.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 100, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(place.name)，\(place.subtitle)\(distance.map { "，直线距离\(NavFormat.distance($0))" } ?? "")")
    }
}

/// 失败/空态：一条主提示 + 可用动作（补充要求·失败分流表）
struct NavFailureView: View {
    let failure: NavFailure
    var onAction: (NavFailureAction) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(NavTheme.inkMute)
            Text(failure.title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(NavTheme.ink)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                ForEach(failure.actions, id: \.self) { action in
                    Button {
                        onAction(action)
                    } label: {
                        Text(action.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(action == failure.actions.first ? .white : NavTheme.accentDeep)
                            .padding(.horizontal, 20)
                            .frame(height: 44)
                            .background(
                                action == failure.actions.first
                                    ? AnyShapeStyle(NavTheme.accent)
                                    : AnyShapeStyle(NavTheme.accentSoft),
                                in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }

    private var iconName: String {
        switch failure {
        case .offline: return "wifi.slash"
        case .locationDenied, .locationServicesOff: return "location.slash"
        case .weakLocation, .locationUnavailable: return "location.magnifyingglass"
        case .noRoute, .outOfServiceArea: return "point.topleft.down.curvedto.point.bottomright.up"
        case .authRequired: return "lock.fill"
        default: return "exclamationmark.triangle"
        }
    }
}

/// 空结果（与失败严格区分，NAV-07）
struct NavEmptyView: View {
    let title: String
    var detail: String? = nil
    var actionTitle: String? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(NavTheme.inkMute)
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(NavTheme.ink)
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(NavTheme.inkMute)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NavTheme.accentDeep)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 24)
    }
}

/// 主按钮（44pt 触控目标，NAV-41）
struct NavPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled: Bool = true
    var loading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading {
                    ProgressView().tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(enabled ? NavTheme.accent : NavTheme.inkMute.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || loading)
    }
}

/// 加载行
struct NavLoadingRow: View {
    var text: String = "加载中…"
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(text).font(.system(size: 13)).foregroundStyle(NavTheme.inkMute)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

extension CLLocationCoordinate2D {
    var place: Place {
        Place(id: "coord", name: "地图选点", address: "",
              latitude: latitude, longitude: longitude, coordinateSystem: .gcj02)
    }
}

// MARK: - 会员自动提醒（R-047～054 继承规则）

/// 符合条件页面连续停留 10 秒 → 请求宿主弹订阅页；订阅页关闭后重新计时。
/// 暂停条件：非活动页、退后台、会员已解锁、弹层/弹窗覆盖。
/// 行中（导航沉浸）、搜索编辑、权限弹层等页面本就不挂此修饰器，天然不计时。
///
/// 次数规则未在需求中给出（07 P03 待客户产品确认），当前保守实现：
/// 每次进入页面最多自动提醒 1 次，避免关闭后 10 秒再弹、形成连环弹窗。
private struct AutoPaywallReminder: ViewModifier {
    let active: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var timer: Task<Void, Never>?
    @State private var fired = false

    func body(content: Content) -> some View {
        content
            .onAppear { fired = false; restart() }
            .onDisappear { cancel(); fired = false }
            .onChange(of: active) { _ in restart() }
            .onChange(of: scenePhase) { phase in
                phase == .active ? restart() : cancel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .paywallDidDismiss)) { _ in
                // 关闭订阅页后重新计时（不是立刻再弹）
                restart()
            }
    }

    private func cancel() {
        timer?.cancel()
        timer = nil
    }

    private func restart() {
        cancel()
        guard active, !fired, scenePhase == .active else { return }
        timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            fired = true
            NotificationCenter.default.post(name: .presentPaywall, object: nil)
        }
    }
}

extension View {
    /// 未解锁页面自动提醒：连续停留 10 秒拉起订阅页（关闭后重新计时）
    func autoPaywallReminder(active: Bool) -> some View {
        modifier(AutoPaywallReminder(active: active))
    }
}
