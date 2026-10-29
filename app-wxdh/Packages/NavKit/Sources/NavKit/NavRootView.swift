import Capabilities
import CoreKit
import SwiftUI

/// 导航 App 根视图：四 Tab + 全屏子流程（子流程不显示 Tab，NAV-01）
public struct NavRootView: View {
    @StateObject private var model: NavAppModel
    private let appName: String
    private let privacyURL: URL?
    private let termsURL: URL?
    private let supportEmail: String

    public init(context: PluginContext, appName: String = "智能卫星导航") {
        _model = StateObject(wrappedValue: NavAppModel(pay: context.pay, theme: context.theme))
        self.appName = appName
        self.privacyURL = context.config["privacy_url"]?.stringValue.flatMap(URL.init(string:))
        self.termsURL = context.config["terms_url"]?.stringValue.flatMap(URL.init(string:))
        self.supportEmail = context.config["support_email"]?.stringValue ?? ""
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                tabContent
                if model.flow == .home {
                    NavTabBar(selection: $model.tab)
                }
            }
            .background(NavTheme.bg)

            flowLayer
        }
        .tint(NavTheme.accent)
        .sheet(isPresented: $model.showProfile) {
            ProfileScreen(model: model, appName: appName,
                          privacyURL: privacyURL, termsURL: termsURL,
                          supportEmail: supportEmail)
        }
        .onChange(of: model.engine.phase) { phase in
            if phase == .arrived { model.handleArrival() }
        }
        .task {
            #if DEBUG
            model.applyDebugLaunchScreenIfNeeded()
            #endif
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.tab {
        case .navigate:
            NavigateHomeView(model: model)
        case .compass:
            CompassScreen(model: model)
        case .altitude:
            AltitudeScreen(model: model)
        case .weather:
            WeatherScreen(model: model)
        }
    }

    @ViewBuilder
    private var flowLayer: some View {
        switch model.flow {
        case .home:
            EmptyView()
        case .search:
            SearchView(model: model)
                .transition(.move(edge: .trailing))
        case .nearby:
            NearbyListView(model: model)
                .transition(.move(edge: .trailing))
        case .plan:
            RoutePlanView(model: model)
                .transition(.move(edge: .trailing))
        case .navigating:
            NavigatingView(model: model)
                .transition(.opacity)
        case .arrived:
            ArrivalView(model: model)
                .transition(.opacity)
        }
    }
}

/// 底部一级 Tab：四项等宽，导航项略强，不用实心选中底色（R-004 / 视觉规范）
struct NavTabBar: View {
    @Binding var selection: NavTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(NavTab.allCases) { tab in
                Button {
                    if selection != tab {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: tab == .navigate ? 21 : 19,
                                          weight: selection == tab ? .bold : .medium))
                        Text(tab.title)
                            .font(.system(size: 12, weight: selection == tab ? .bold : .medium))
                    }
                    .foregroundStyle(selection == tab ? NavTheme.accentDeep : NavTheme.inkMute)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .background(
            NavTheme.panel
                .overlay(alignment: .top) {
                    Rectangle().fill(NavTheme.line).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}
