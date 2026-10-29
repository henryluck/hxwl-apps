import SwiftUI

// iPad 兼容窗口适配原语（iPadOS 26+ iPhone-only App 以可调窗口运行，布局会收到真实尺寸变化）。

public extension View {
    /// 内容区最大可读宽度封顶并居中：窗口宽于 max 时内容保持 max 宽、水平居中。
    /// 只套在内容根容器上；背景/TabBar 由调用方留在底层，不受此限。
    /// 默认 600pt：高于所有 iPhone 宽度（≤440），仅宽窗口触发，iPhone 零影响。
    func readableContentWidth(_ max: CGFloat = 600) -> some View {
        self.frame(maxWidth: max)
            .frame(maxWidth: .infinity)
    }
}

/// 按最小列宽生成自适应网格列。
/// minimum 必须按 320pt 不塌列、430pt 不增列（相对原固定列数）核算。
public func adaptiveColumns(minimum: CGFloat, spacing: CGFloat = 16) -> [GridItem] {
    [GridItem(.adaptive(minimum: minimum), spacing: spacing)]
}
