import Capabilities
import SwiftUI

/// 关于我们：logo + 名称 + 简介 + 核心功能 + 当前版本 + 联系邮箱。
/// 全部入参为基本类型 + `ThemeService`，不依赖工厂主模块的说明书类型
/// （BaseComponents 是 SwiftPM 包，跨包不可见工厂模块）。
public struct AboutView: View {
    let appName: String
    let version: String
    let iconSystemName: String        // 无 logo 资源时的占位 SF Symbol
    let intro: String
    let features: [String]
    let contactEmail: String?
    let theme: any ThemeService

    @Environment(\.openURL) private var openURL

    public init(appName: String, version: String, iconSystemName: String = "app.fill",
                intro: String, features: [String], contactEmail: String?, theme: any ThemeService) {
        self.appName = appName
        self.version = version
        self.iconSystemName = iconSystemName
        self.intro = intro
        self.features = features
        self.contactEmail = contactEmail
        self.theme = theme
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: iconSystemName)
                    .font(.system(size: 64))
                    .foregroundStyle(theme.accent)
                Text(appName)
                    .font(.title2.bold())
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !intro.isEmpty {
                    Text(intro)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                if !features.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("核心功能").font(.headline)
                        ForEach(features, id: \.self) { Text("• \($0)").font(.subheadline) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }
                if let email = contactEmail, let url = URL(string: "mailto:\(email)") {
                    Button("联系我们：\(email)") { openURL(url) }
                        .font(.subheadline)
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.vertical, 24)
        }
        .navigationTitle("关于我们")
    }
}
