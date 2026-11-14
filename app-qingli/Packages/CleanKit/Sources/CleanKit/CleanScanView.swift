import Combine
import CoreKit
import SwiftUI

/// 深度扫描页（原型 cleaning-scan_scan.html）：
/// 环形进度 + 扫掠光带 + 轨道点动画，进度来自 CleanScanner 真实扫描；
/// 扫描完成后展示完成态并立即跳转智能清理建议页（导航由外层 onFinished 接管）。
/// 进入时若已有扫描在进行（首页自动扫描），直接观察该扫描，不重复起扫。
struct CleanScanView: View {
    let onFinished: () -> Void

    @ObservedObject private var scanner = CleanScanner.shared

    @State private var appearedAt = Date()
    @State private var observing = false
    @State private var isDone = false
    @State private var jumpScheduled = false
    // 动画开关（onAppear 置 true 启动 repeatForever 动画）
    @State private var spinSweep = false
    @State private var spinSlow = false
    @State private var orbitA = false
    @State private var orbitB = false
    @State private var pinging = false

    private let ringSize: CGFloat = 260

    var body: some View {
        ZStack {
            CleanPalette.pageBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer(minLength: 10)
                scanRing
                Spacer(minLength: 10)
                hint
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .navigationTitle("深度扫描")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(CleanPalette.navBarGreen, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .onAppear(perform: start)
        .onReceive(scanner.$isScanning.dropFirst()) { scanning in
            // 首页已起的扫描结束时收到通知 → 进入完成态
            if observing, !scanning { markDone() }
        }
    }

    // MARK: - 顶部标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isDone ? "深度扫描完成" : "深度扫描中")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color(hex: "1A1A1A"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(isDone ? "扫描已结束，正在进入清理建议" : "正在分析照片库，找出可清理项")
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: "6B7078"))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 12)
    }

    // MARK: - 环形扫描区

    private var scanRing: some View {
        ZStack {
            // 中心光晕
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.95),
                                              CleanPalette.greenPale.opacity(0.4),
                                              .clear],
                                     center: .center, startRadius: 0, endRadius: ringSize / 2))
                .frame(width: ringSize - 48, height: ringSize - 48)
                .blur(radius: 2)
            // 外圈虚线装饰（慢转）
            Circle()
                .stroke(CleanPalette.green.opacity(0.22),
                        style: StrokeStyle(lineWidth: 1.2, dash: [1.5, 8.5]))
                .frame(width: ringSize - 8, height: ringSize - 8)
                .rotationEffect(.degrees(spinSlow ? 360 : 0))
                .animation(.linear(duration: 46).repeatForever(autoreverses: false), value: spinSlow)
            // 进度轨道
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 14)
                .frame(width: ringSize - 44, height: ringSize - 44)
            // 扫掠光带（锥形渐变，随扫描旋转）
            Circle()
                .stroke(AngularGradient(colors: [.clear, .clear, .clear,
                                                 CleanPalette.greenLight.opacity(0.10),
                                                 CleanPalette.green.opacity(0.42),
                                                 .clear],
                                        center: .center),
                        lineWidth: 34)
                .frame(width: ringSize - 16, height: ringSize - 16)
                .rotationEffect(.degrees(spinSweep ? 360 : 0))
                .animation(.linear(duration: 4.2).repeatForever(autoreverses: false), value: spinSweep)
                .opacity(isDone ? 0.32 : 1)
            // 轨道点 A（正转）
            Circle()
                .fill(.clear)
                .frame(width: ringSize - 48, height: ringSize - 48)
                .overlay(
                    Circle()
                        .fill(.white)
                        .frame(width: 6, height: 6)
                        .shadow(color: CleanPalette.green.opacity(0.6), radius: 4)
                        .offset(y: -(ringSize - 48) / 2)
                )
                .rotationEffect(.degrees(orbitA ? 360 : 0))
                .animation(.linear(duration: 11).repeatForever(autoreverses: false), value: orbitA)
            // 轨道点 B（反转）
            Circle()
                .fill(.clear)
                .frame(width: ringSize - 48, height: ringSize - 48)
                .overlay(
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                        .shadow(color: CleanPalette.green.opacity(0.5), radius: 3)
                        .offset(y: -(ringSize - 48) / 2)
                )
                .rotationEffect(.degrees(orbitB ? -360 : 0))
                .animation(.linear(duration: 17).repeatForever(autoreverses: false), value: orbitB)
            // 进度弧（真实扫描进度驱动）
            Circle()
                .trim(from: 0, to: CGFloat(min(max(scanner.progress, 0.02), 1)))
                .stroke(AngularGradient(colors: [CleanPalette.greenLight,
                                                 CleanPalette.green,
                                                 Color(hex: "2E8F5E"),
                                                 CleanPalette.greenLight],
                                        center: .center),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .frame(width: ringSize - 44, height: ringSize - 44)
                .rotationEffect(.degrees(-90))
                .shadow(color: CleanPalette.green.opacity(0.35), radius: 6)
                .animation(.easeInOut(duration: 0.5), value: scanner.progress)
            // 中心盘
            centerDisc
        }
        .frame(width: ringSize, height: ringSize)
    }

    private var centerDisc: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.85))
            Circle()
                .stroke(Color.white, lineWidth: 1)
            Group {
                if isDone {
                    doneContent
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                } else {
                    scanContent
                        .transition(.opacity)
                }
            }
            .padding(18)
        }
        .frame(width: ringSize - 88, height: ringSize - 88)
        .shadow(color: Color.black.opacity(0.08), radius: 18, y: 10)
    }

    /// 扫描中：状态点（雷达 ping）+ 大号百分比 + 阶段文案
    private var scanContent: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(CleanPalette.green.opacity(0.5))
                        .frame(width: 6, height: 6)
                        .scaleEffect(pinging ? 2.4 : 1)
                        .opacity(pinging ? 0 : 0.8)
                    Circle()
                        .fill(CleanPalette.green)
                        .frame(width: 6, height: 6)
                }
                .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pinging)
                Text("扫描中")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(Color(hex: "3B7F6B"))
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(percentText)")
                    .font(.system(size: 52, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: "1A1A1A"))
                Text("%")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(CleanPalette.green)
            }
            Text(scanner.phaseLabel.isEmpty ? "正在深度扫描" : scanner.phaseLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: "2F6E5D"))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }

    /// 完成态：徽章勾 + 文案
    private var doneContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundStyle(CleanPalette.green)
            Text("扫描完成")
                .font(.system(size: 10, weight: .medium))
                .tracking(2)
                .foregroundStyle(Color(hex: "3B7F6B"))
            Text("深度扫描已完成")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(hex: "2F6E5D"))
        }
    }

    private var hint: some View {
        Text("扫描仅读取照片信息，不会修改你的照片")
            .font(.system(size: 12))
            .foregroundStyle(Color(hex: "9AA09C"))
    }

    private var percentText: Int {
        Int((min(max(scanner.progress, 0), 1) * 100).rounded())
    }

    // MARK: - 生命周期

    private func start() {
        appearedAt = Date()
        guard !jumpScheduled else { return }
        startAnimations()
        if !scanner.isScanning {
            // 无进行中的扫描 → 现场起扫，回调里进入完成态
            scanner.scanAll { summary in
                CleanCenter.shared.summary = summary
                markDone()
            }
        } else {
            // 首页自动扫描进行中 → 观察即可（isScanning 转 false 时 markDone）
            observing = true
            // 竞态兜底：扫描恰好在检查间隙结束 → 不会再有变化事件，主动补一次
            if !scanner.isScanning { markDone() }
        }
    }

    private func startAnimations() {
        spinSweep = true
        spinSlow = true
        orbitA = true
        orbitB = true
        pinging = true
    }

    /// 完成态：极快扫描兜底最短展示 2s，完成后停留 0.8s 立即跳转
    private func markDone() {
        guard !jumpScheduled else { return }
        jumpScheduled = true
        observing = false
        let remain = max(0, 2.0 - Date().timeIntervalSince(appearedAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + remain) {
            withAnimation(.easeInOut(duration: 0.45)) {
                isDone = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                onFinished()
            }
        }
    }
}
