import ActivityKit
import SwiftUI
import WidgetKit

// 锁屏实时活动 UI（Widget Extension 渲染）。
// 数据模型 CleanActivityAttributes 定义在 CleanKit/CleanLiveActivityManager.swift，
// 由本 target 直接编译该文件共享（xcodegen sources 含该路径）。

@available(iOS 16.1, *)
struct CleanLiveActivityView: View {
    let context: ActivityViewContext<CleanActivityAttributes>

    // 品牌色（与 App 内一致；Widget target 不依赖 CleanKit 全量，色值内联）
    private let brandGreen = Color(red: 0.55, green: 0.89, blue: 0.68)      // #8DE3AE
    private let cardDark = Color(red: 0.32, green: 0.39, blue: 0.37)        // #52655E

    var body: some View {
        // 原型布局：第一行 logo + 「温馨提示：」；第二行描述整行可折行；第三行「立即清理」整行胶囊
        VStack(alignment: .leading, spacing: 10) {
            // 第一行：logo + 标题
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(brandGreen)
                    Image(systemName: "trash.slash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                Text("温馨提示：")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(brandGreen)
                Spacer(minLength: 0)
            }
            // 第二行：描述（整行宽度，可折行）
            Text(context.state.isFinished
                 ? "已完成清理 \(context.state.cleanableText)，手机存储空间已释放，运行更流畅。"
                 : "检测到可清理垃圾共\(context.state.cleanableText)，前往清理应用临时缓存，清理后能够释放手机存储空间，提升运行速度。")
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
            // 第三行：立即清理（整行胶囊，Link 深链拉起 App；iOS 16 锁屏不支持 Button）
            Link(destination: URL(string: "qlzs://clean")!) {
                Text(context.state.isFinished ? "已完成" : "立即清理")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(Capsule().fill(brandGreen))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardDark))
        .activityBackgroundTint(cardDark)
    }
}

@available(iOS 16.1, *)
struct CleanLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CleanActivityAttributes.self) { context in
            // 锁屏卡片
            CleanLiveActivityView(context: context)
        } dynamicIsland: { context in
            // 灵动岛
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(red: 0.55, green: 0.89, blue: 0.68))
                        Image(systemName: "trash.slash")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 34, height: 34)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("可清理垃圾 \(context.state.cleanableText)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Link(destination: URL(string: "qlzs://clean")!) {
                        Text("清理")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(red: 0.11, green: 0.23, blue: 0.19))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color(red: 0.55, green: 0.89, blue: 0.68)))
                    }
                }
            } compactLeading: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.55, green: 0.89, blue: 0.68))
            } compactTrailing: {
                Text(context.state.cleanableText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.55, green: 0.89, blue: 0.68))
            } minimal: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.55, green: 0.89, blue: 0.68))
            }
        }
    }
}

// MARK: - Widget 扩展入口
//
// Live Activity 必须包在 WidgetBundle 中作为扩展的 @main 入口，否则 WidgetKit
// 加载不到扩展。
//
// 注意：调试时若出现 "Show Notification Center Widget timed out" (Code=32) 或
// "Failed to show Widget ... Failed to get descriptors for extensionBundleID" (Code=8)，
// 根因不是本文件，而是 scheme 的「运行目标」被设成了 CleanLiveActivity.appex：
// Xcode 会请求 SpringBoard 显示该扩展的 Widget，而本扩展只有 ActivityConfiguration
// （没有 StaticConfiguration 普通小组件），取不到 descriptor 必然失败。
// 正确做法：Run 主 App 的 scheme（project*.yml 中 run.executable 已显式指向主 App）。
@main
struct CleanLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        CleanLiveActivityWidget()
    }
}
