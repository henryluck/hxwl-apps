import Capabilities
import CoreKit
import MessageUI
import SwiftUI
import UIKit

// MARK: - 原型版「意见反馈 / 关于我们」
//
// 原型：清理工具 / iPhone 16 & 17 Pro - 214.svg（意见反馈）
//      清理工具 / iPhone 16 & 17 Pro - 215.svg（关于我们）
//
// 与旧 FeedbackView / AboutView 的区别：
//   - 旧版依赖 spec.support 配置段，当前 spec.json 里 support=null → 所有入口静默失效；
//   - 新版无配置也能打开，且功能是「真」的：
//       * 反馈写入本机 Application Support 的 JSON 发件箱（可查看/复制/删除）；
//       * 中台已配置 → 真实 HTTP 提交；未配置但设备有邮件账户 → 原生邮件草稿；
//       * 都没有 → 明确保存到本机，绝不假装「已提交」；
//       * 联系邮箱点击 → 邮件草稿 / 复制邮箱（模拟器无邮件账户也不会无响应）。

// MARK: - 反馈发件箱（本地持久化）

public struct FeedbackRecord: Codable, Identifiable, Hashable {
    public let id: UUID
    public let content: String
    public let contact: String
    public let appVersion: String
    public let createdAt: Date
    public var delivered: Bool

    public init(id: UUID = UUID(), content: String, contact: String,
                appVersion: String, createdAt: Date = Date(), delivered: Bool = false) {
        self.id = id
        self.content = content
        self.contact = contact
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.delivered = delivered
    }
}

/// 反馈发件箱：文件持久化在 Application Support/feedback-outbox.json。
/// 所有写入都经此类型，页面只读 `records`，重启 App 记录仍在。
public final class FeedbackOutbox: ObservableObject {
    public static let shared = FeedbackOutbox()

    @Published public private(set) var records: [FeedbackRecord] = []

    private var fileURL: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent("feedback-outbox.json")
    }

    private init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([FeedbackRecord].self, from: data) else { return }
        records = list.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    public func add(content: String, contact: String, appVersion: String) -> FeedbackRecord {
        let record = FeedbackRecord(content: content, contact: contact, appVersion: appVersion)
        records.insert(record, at: 0)
        persist()
        return record
    }

    public func markDelivered(_ id: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].delivered = true
        persist()
    }

    public func remove(_ id: UUID) {
        records.removeAll { $0.id == id }
        persist()
    }
}

// MARK: - 意见反馈页

public struct ProtoFeedbackView: View {
    let appVersion: String
    let supportEmail: String
    let zhongtai: any ZhongtaiService

    @Environment(\.dismiss) private var dismiss
    @StateObject private var outbox = FeedbackOutbox.shared
    @State private var content = ""
    @State private var contact = ""
    @State private var submitting = false
    @State private var showHistory = false
    @State private var showMail = false
    @State private var mailRecordID: UUID?
    @State private var toast: String?
    @State private var submitted = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case content, contact }

    private let maxLength = 500
    private let green = Color(hex: "61C77A")
    private let ink = Color(hex: "1A1A1A")

    public init(appVersion: String, supportEmail: String,
                zhongtai: any ZhongtaiService = NullZhongtaiService()) {
        self.appVersion = appVersion
        self.supportEmail = supportEmail
        self.zhongtai = zhongtai
    }

    public var body: some View {
        ZStack {
            ProtoSupportBackground()

            VStack(alignment: .leading, spacing: 0) {
                ProtoNavBar(title: "意见反馈") { dismiss() }

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("遇到问题、有建议都可以告诉我们，我们会尽快处理")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "8A9A90"))
                            .padding(.horizontal, 34)
                            .padding(.top, 18)

                        formCard
                            .padding(.horizontal, 30)
                            .padding(.top, 16)

                        Button {
                            showHistory = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 12))
                                Text("我的反馈记录\(outbox.records.isEmpty ? "" : "（\(outbox.records.count)）")")
                                    .font(.system(size: 13))
                            }
                            .foregroundStyle(Color(hex: "5A9B6C"))
                            .padding(.horizontal, 34)
                            .padding(.top, 18)
                        }
                        .accessibilityIdentifier("feedback.history")

                        Button {
                            submit()
                        } label: {
                            Text(submitting ? "提交中…" : "提交反馈")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(green))
                        }
                        .disabled(submitting)
                        .accessibilityIdentifier("feedback.submit")
                        .padding(.horizontal, 48)
                        .padding(.top, 58)
                    }
                    .padding(.bottom, 40)
                }
                // 键盘会盖住表单底部的「提交反馈」按钮：下滑收起键盘 + 键盘工具栏「完成」
                .scrollDismissesKeyboard(.interactively)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成") { focusedField = nil }
                            .accessibilityIdentifier("feedback.keyboard.done")
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showHistory) { FeedbackHistoryView() }
        .sheet(isPresented: $showMail) {
            MailComposer(recipient: supportEmail,
                         subject: "「垃圾清理助手」意见反馈",
                         body: mailBody()) { sent in
                showMail = false
                if sent, let id = mailRecordID { outbox.markDelivered(id) }
                toast = sent ? "反馈已通过邮件发送，感谢支持！" : "邮件未发送，反馈已保存在「我的反馈记录」"
                if sent { clearForm() }
            }
        }
        .alert("反馈已收到", isPresented: $submitted) {
            Button("好的", role: .cancel) { }
        } message: {
            Text(toast ?? "")
        }
        .overlay(alignment: .top) {
            if let toast, !submitted {
                Text(toast)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.72)))
                    .padding(.top, 110)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { self.toast = nil }
                    }
            }
        }
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("请详细描述您的问题或建议")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ink)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(hex: "F5F6F7"))
                if content.isEmpty {
                    Text("例如：扫描相似照片时…（\(maxLength) 字以内）")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "B4B8BC"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                }
                TextEditor(text: Binding(
                    get: { content },
                    set: { content = String($0.prefix(maxLength)) }
                ))
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(height: 148)
                .focused($focusedField, equals: .content)
                .accessibilityIdentifier("feedback.content")
            }
            .frame(height: 148)

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("联系方式：")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ink)
                TextField("(选填)", text: $contact)
                    .font(.system(size: 13))
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .contact)
                    .accessibilityIdentifier("feedback.contact")
                Text("\(content.count)/\(maxLength)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "B4B8BC"))
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(hex: "D5D8DC")).frame(height: 0.5)
                    .padding(.trailing, 60)
                    .offset(y: 8)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
    }

    // MARK: 提交：真实链路（中台 / 邮件 / 本机发件箱）

    private func submit() {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 5 else {
            toast = "请至少输入 5 个字，方便我们定位问题"; return
        }
        guard !submitting else { return }
        submitting = true
        let record = outbox.add(content: text, contact: contact, appVersion: appVersion)

        if zhongtai.isConfigured {
            Task {
                do {
                    let payload = FeedbackPayload(fields: ["content": text, "contact": contact],
                                                  appVersion: appVersion,
                                                  deviceModel: UIDevice.current.model,
                                                  systemVersion: UIDevice.current.systemVersion)
                    try await zhongtai.submitFeedback(payload)
                    await MainActor.run {
                        outbox.markDelivered(record.id)
                        submitting = false
                        clearForm()
                        toast = "反馈已提交，感谢支持！"
                        submitted = true
                    }
                } catch {
                    await MainActor.run {
                        submitting = false
                        toast = "网络提交失败，反馈已保存到本机，可在「我的反馈记录」中复制发送"
                        submitted = true
                    }
                }
            }
        } else if MFMailComposeViewController.canSendMail() && !supportEmail.isEmpty {
            mailRecordID = record.id
            submitting = false
            showMail = true
        } else {
            // 模拟器 / 未配置邮件账户：诚实落本机，不谎报「已提交」
            submitting = false
            clearForm()
            toast = "反馈已保存到本机，可在「我的反馈记录」查看并复制"
            submitted = true
        }
    }

    private func mailBody() -> String {
        let item = outbox.records.first { $0.id == mailRecordID }
        return """
        \(item?.content ?? content)

        联系方式：\(item?.contact ?? contact)
        App 版本：\(appVersion)
        系统：iOS \(UIDevice.current.systemVersion) / \(UIDevice.current.model)
        """
    }

    private func clearForm() {
        content = ""
        contact = ""
    }
}

// MARK: - 反馈记录（真实可查看/复制/删除）

struct FeedbackHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var outbox = FeedbackOutbox.shared

    var body: some View {
        NavigationStack {
            Group {
                if outbox.records.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.system(size: 40))
                            .foregroundStyle(Color(hex: "C9CDD4"))
                        Text("还没有反馈记录")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(outbox.records) { r in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(r.createdAt, style: .date)
                                    Text(r.createdAt, style: .time)
                                    Spacer()
                                    Text(r.delivered ? "已发送" : "已保存到本机")
                                        .font(.system(size: 11))
                                        .foregroundStyle(r.delivered ? Color(hex: "3DA24E") : Color(hex: "E8A93C"))
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                Text(r.content)
                                    .font(.system(size: 14))
                                    .lineLimit(3)
                                if !r.contact.isEmpty {
                                    Text("联系方式：\(r.contact)")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    UIPasteboard.general.string = r.content
                                } label: {
                                    Label("复制内容", systemImage: "doc.on.doc")
                                        .font(.system(size: 12))
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { indexSet in
                            for idx in indexSet { outbox.remove(outbox.records[idx].id) }
                        }
                    }
                }
            }
            .background(ProtoSupportBackground())
            .navigationTitle("我的反馈记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 关于我们页

public struct ProtoAboutView: View {
    let appName: String
    let version: String
    let supportEmail: String

    @Environment(\.dismiss) private var dismiss
    @State private var showMail = false
    @State private var toast: String?

    public init(appName: String, version: String, supportEmail: String) {
        self.appName = appName
        self.version = version
        self.supportEmail = supportEmail
    }

    public var body: some View {
        ZStack {
            ProtoSupportBackground()

            VStack(alignment: .leading, spacing: 0) {
                ProtoNavBar(title: "关于我们") { dismiss() }

                Spacer(minLength: 0)

                VStack(spacing: 0) {
                    ProtoAssetImage("app_logo.jpg")
                        .frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Text(appName)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                        .padding(.top, 22)

                    Text("最新版本\(version)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "9AA09C"))
                        .padding(.top, 10)

                    Text("我们致力于专注手机存储优化，AI 智能识别各类冗余垃圾，精准区分文件，防止误删，让手机更轻松。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "9AA09C"))
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                        .frame(width: 260)
                        .padding(.top, 70)
                }
                .frame(maxWidth: .infinity)

                Spacer(minLength: 0)

                VStack(spacing: 4) {
                    Text("联系我们")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: "1A1A1A"))
                    Button {
                        contact()
                    } label: {
                        Text(supportEmail)
                            .font(.system(size: 15))
                            .foregroundStyle(Color(hex: "1A1A1A"))
                            .underline()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 44)
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showMail) {
            MailComposer(recipient: supportEmail,
                         subject: "关于「\(appName)」",
                         body: "\n\nApp 版本：\(version)\niOS：\(UIDevice.current.systemVersion)") { sent in
                showMail = false
                toast = sent ? "邮件已发送" : "邮件未发送"
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.72)))
                    .padding(.top, 110)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { self.toast = nil }
                    }
            }
        }
    }

    private func contact() {
        guard !supportEmail.isEmpty else {
            toast = "暂未配置联系邮箱"; return
        }
        if MFMailComposeViewController.canSendMail() {
            showMail = true
        } else {
            UIPasteboard.general.string = supportEmail
            toast = "邮箱已复制：\(supportEmail)"
        }
    }
}

// MARK: - 共用小组件

/// 原型统一背景：顶部薄荷绿 → 底部近白
public struct ProtoSupportBackground: View {
    public init() {}
    public var body: some View {
        LinearGradient(colors: [Color(hex: "C7EFD5"), Color(hex: "E6F8EC"), Color(hex: "FAFCFA")],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// 原型自绘导航栏：左返回箭头 + 标题（系统导航栏隐藏）
public struct ProtoNavBar: View {
    let title: String
    let onBack: () -> Void

    public init(title: String, onBack: @escaping () -> Void) {
        self.title = title
        self.onBack = onBack
    }

    public var body: some View {
        HStack(spacing: 24) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color(hex: "1A1A1A"))
                    .frame(width: 24, height: 32)
            }
            .accessibilityIdentifier("support.nav.back")
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color(hex: "1A1A1A"))
            Spacer()
        }
        .padding(.leading, 32)
        .padding(.top, 14)
    }
}

/// 读取打包在 `assets/proto/` 的原型图片（folder reference）
public struct ProtoAssetImage: View {
    let name: String

    public init(_ name: String) { self.name = name }

    public var body: some View {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("assets/proto/\(name)"),
           let img = UIImage(contentsOfFile: url.path) {
            Image(uiImage: img).resizable()
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: "C9EFD6"))
                .overlay(Image(systemName: "sparkles").foregroundStyle(.white))
        }
    }
}

/// 原生邮件草稿（有邮件账户时可用；模拟器通常不可用，调用方需兜底）
struct MailComposer: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    let onResult: (Bool) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([recipient])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onResult: (Bool) -> Void
        init(onResult: @escaping (Bool) -> Void) { self.onResult = onResult }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            controller.dismiss(animated: true)
            onResult(result == .sent)
        }
    }
}
