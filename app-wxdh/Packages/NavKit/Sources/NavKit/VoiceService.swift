import AVFoundation
import CoreKit
import Foundation

/// 语音播报优先级：转向类可打断普通提示，终态提示清空队列（NAV-29）
public enum VoicePriority: Int, Comparable {
    case normal = 0     // 概要、后台提示
    case turn = 1       // 临近转向
    case terminal = 2   // 到达、退出

    public static func < (lhs: VoicePriority, rhs: VoicePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 导航语音：全 App 唯一输出（内置 TTS），不申请麦克风（NAV-27/29）
@MainActor
public final class VoiceService: NSObject, ObservableObject {
    /// 用户静音：可见且受尊重，不自动解除（NAV-29 / V16）
    @Published public private(set) var isMuted: Bool
    @Published public private(set) var isSpeaking = false
    /// 最近一条播报（诊断用，NAV-30 时间轴）
    @Published public private(set) var lastSpoken: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var spokenKeys = Set<String>()
    private var pending: [(text: String, priority: VoicePriority)] = []
    private var currentPriority: VoicePriority = .normal
    private var sessionConfigured = false
    private var interruptionObserver: NSObjectProtocol?

    public override init() {
        isMuted = UserDefaults.standard.bool(forKey: "nav.voice.muted")
        super.init()
        synthesizer.delegate = self
        observeInterruption()
    }

    // MARK: - 开关

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        UserDefaults.standard.set(muted, forKey: "nav.voice.muted")
        if muted { stopAll() }
    }

    public func resetSessionKeys() {
        spokenKeys.removeAll()
        pending.removeAll()
    }

    // MARK: - 播报

    /// 一次性提示：同一 key 只播一次（去重，避免重复打断）
    public func announceOnce(key: String, text: String, priority: VoicePriority = .normal) {
        guard !spokenKeys.contains(key) else { return }
        spokenKeys.insert(key)
        speak(text, priority: priority)
    }

    /// 可直接重播的提示（如恢复后的当前有效动作）
    public func speak(_ text: String, priority: VoicePriority = .normal) {
        guard !isMuted, !text.isEmpty else { return }
        lastSpoken = text
        // 终态：清空旧队列，结束提示不遗留到下次会话
        if priority == .terminal {
            pending.removeAll()
            synthesizer.stopSpeaking(at: .immediate)
            enqueue(text, priority: priority)
            return
        }
        // 转向优先于普通提示：打断正在播的普通提示，不打断终态
        if synthesizer.isSpeaking && priority > currentPriority && currentPriority != .terminal {
            synthesizer.stopSpeaking(at: .immediate)
            pending.removeAll()
            enqueue(text, priority: priority)
            return
        }
        if synthesizer.isSpeaking {
            // 同类/低优先级排队，避免丢指令
            enqueue(text, priority: priority)
        } else {
            enqueue(text, priority: priority)
        }
    }

    public func stopAll() {
        pending.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        currentPriority = .normal
    }

    private func enqueue(_ text: String, priority: VoicePriority) {
        pending.append((text, priority))
        pump()
    }

    private func pump() {
        guard !synthesizer.isSpeaking, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        currentPriority = next.priority
        configureAudioSessionIfNeeded()
        let utterance = AVSpeechUtterance(string: next.text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.48
        utterance.volume = 1.0
        // 打断其它音频（音乐/播客）后压低而非完全静音
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    // MARK: - 音频会话与中断（NAV-29 / V15）

    private func configureAudioSessionIfNeeded() {
        guard !sessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true, options: [])
            sessionConfigured = true
        } catch {
            Log.warn("[Voice] 音频会话配置失败: \(error.localizedDescription)")
        }
    }

    private func observeInterruption() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
                guard let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                Task { @MainActor in
                    switch type {
                    case .began:
                        // 来电/闹钟：停止播报，队列保留但恢复时只重读当前有效动作
                        self.synthesizer.stopSpeaking(at: .immediate)
                        self.isSpeaking = false
                    case .ended:
                        self.sessionConfigured = false
                        // 不补播过期路口（清队列），由引擎在恢复时按当前动作重新播
                        self.pending.removeAll()
                    @unknown default:
                        break
                    }
                }
            }
    }

    deinit {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

extension VoiceService: AVSpeechSynthesizerDelegate {
    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.currentPriority = .normal
            self.pump()
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.currentPriority = .normal
            self.pump()
        }
    }
}
