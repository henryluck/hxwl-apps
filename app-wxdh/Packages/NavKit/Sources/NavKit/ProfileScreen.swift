import Capabilities
import SwiftUI
import UIKit

/// 我的：会员卡与恢复、使用设置、反馈、关于与法务（R-039/040/041/042）
struct ProfileScreen: View {
    @ObservedObject var model: NavAppModel
    let appName: String
    var privacyURL: URL?
    var termsURL: URL?
    var supportEmail: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var showFeedback = false
    @State private var feedbackText = ""
    @State private var feedbackSent = false
    @State private var feedbackSubmitting = false
    @State private var feedbackError: String?
    @State private var restoring = false

    /// 反馈网关（懒加载：spec.json 未配置时提交按钮给出不可用提示）
    private var feedbackGateway: NavGatewayClient? {
        guard let config = NavGatewayConfig.load() else { return nil }
        return NavGatewayClient(config: config)
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    memberCard
                    settingsGroup
                    supportGroup
                    aboutGroup
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(NavTheme.bg)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showFeedback) { feedbackSheet }
    }

    // MARK: - 会员卡

    private var memberCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isUnlocked ? "会员已生效" : "尚未开通会员")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(NavTheme.ink)
                    Text(model.isUnlocked ? "导航、罗盘、海拔与天气预报已解锁"
                                          : "解锁目的地检索、路线导航、周边与完整罗盘")
                        .font(.system(size: 12))
                        .foregroundStyle(NavTheme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: model.isUnlocked ? "crown.fill" : "crown")
                    .font(.system(size: 26))
                    .foregroundStyle(NavTheme.accentDeep)
            }

            HStack(spacing: 10) {
                if !model.isUnlocked {
                    Button {
                        _ = model.requireMembership()
                    } label: {
                        Text("开通会员")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(NavTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    restoring = true
                    Task {
                        await model.pay.restore()
                        await model.pay.refreshEntitlement()
                        restoring = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if restoring { ProgressView().tint(NavTheme.accentDeep) }
                        Text("恢复购买")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(NavTheme.accentDeep)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(NavTheme.panel.opacity(0.85),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(restoring)
            }
        }
        .padding(16)
        .background(NavTheme.cardGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 设置

    private var settingsGroup: some View {
        VStack(spacing: 0) {
            row(icon: "location.fill", title: "定位权限", value: authText) {
                if model.location.authState == .denied || model.location.authState == .restricted {
                    model.location.openAppSettings()
                } else {
                    Task { await model.locate() }
                }
            }
            Divider().overlay(NavTheme.line).padding(.leading, 44)
            row(icon: "speaker.wave.2.fill", title: "导航语音", value: model.voice.isMuted ? "已静音" : "已开启") {
                model.voice.setMuted(!model.voice.isMuted)
            }
        }
        .navCard()
    }

    private var supportGroup: some View {
        VStack(spacing: 0) {
            row(icon: "envelope.fill", title: "意见反馈", value: "") {
                feedbackText = ""
                feedbackSent = false
                showFeedback = true
            }
        }
        .navCard()
    }

    private var aboutGroup: some View {
        VStack(spacing: 0) {
            row(icon: "info.circle.fill", title: "关于我们", value: appName) {}
            Divider().overlay(NavTheme.line).padding(.leading, 44)
            legalRow(title: "用户协议", doc: .terms, url: termsURL)
            Divider().overlay(NavTheme.line).padding(.leading, 44)
            legalRow(title: "隐私政策", doc: .privacy, url: privacyURL)
            Divider().overlay(NavTheme.line).padding(.leading, 44)
            HStack {
                Text("版本")
                    .font(.system(size: 15))
                    .foregroundStyle(NavTheme.ink)
                Spacer()
                Text(version)
                    .font(.system(size: 14))
                    .foregroundStyle(NavTheme.inkMute)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
        }
        .navCard()
    }

    /// 法务正文：优先用说明书里的正式协议（宿主渲染），无正文时回退到外链
    private func legalRow(title: String, doc: LegalDocPresenter.Doc, url: URL?) -> some View {
        Button {
            if let url {
                UIApplication.shared.open(url)
            } else {
                LegalDocPresenter.request(doc)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: doc == .privacy ? "hand.raised.fill" : "doc.text.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NavTheme.accent)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(NavTheme.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NavTheme.inkMute.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(icon: String, title: String, value: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NavTheme.accent)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(NavTheme.ink)
                Spacer()
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(NavTheme.inkMute)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NavTheme.inkMute.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func linkRow(icon: String, title: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NavTheme.accent)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(NavTheme.ink)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NavTheme.inkMute.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
    }

    private var authText: String {
        switch model.location.authState {
        case .authorized: return "使用期间"
        case .approximate: return "近似位置"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        case .servicesOff: return "系统已关闭"
        case .notDetermined: return "未询问"
        }
    }

    // MARK: - 反馈

    private var feedbackSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("写下你的建议或遇到的问题", text: $feedbackText, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(5...8)
                    .padding(12)
                    .background(NavTheme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if feedbackSubmitting {
                    HStack(spacing: 8) {
                        ProgressView().tint(NavTheme.accentDeep)
                        Text("正在提交…")
                            .font(.system(size: 13))
                            .foregroundStyle(NavTheme.inkSoft)
                    }
                }
                if feedbackSent {
                    Label("已提交，感谢反馈！", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(NavTheme.good)
                }
                if let feedbackError {
                    Label(feedbackError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(NavTheme.bad)
                }
                Spacer()
            }
            .padding(16)
            .navigationTitle("意见反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showFeedback = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(feedbackSubmitting ? "提交中…" : "提交") { submitFeedback() }
                        .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || feedbackSubmitting || feedbackSent)
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// 提交反馈到网关 /api/v1/support/feedback（服务端 SQLite 持久化）。
    /// 网关未配置或提交失败时给出可读错误；成功后清空输入并提示。
    private func submitFeedback() {
        let content = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        guard let gateway = feedbackGateway else {
            feedbackError = "反馈服务未配置，暂无法提交。"
            return
        }
        feedbackSubmitting = true
        feedbackError = nil
        Task {
            defer { feedbackSubmitting = false }
            do {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                let device = await UIDevice.current.model
                let sys = await UIDevice.current.systemVersion
                _ = try await gateway.post("/api/v1/support/feedback", data: [
                    "fields": ["content": content],
                    "appVersion": version,
                    "deviceModel": device,
                    "systemVersion": sys,
                ])
                feedbackSent = true
                feedbackText = ""
            } catch {
                if let gatewayError = error as? NavGatewayError {
                    feedbackError = gatewayError.userMessage
                } else {
                    feedbackError = "提交失败，请检查网络后重试。"
                }
            }
        }
    }
}
