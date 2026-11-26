# Live Activity 锁屏卡片图标黑块问题 — 完整复盘与正确做法

> 项目：垃圾清理助手（com.hxwl.qlzs）
> 问题周期：2026-11-18 ~ 2026-11-22，历经 5 轮修复
> 最终方案：**图标 Base64 内嵌二进制，纯内存解码**
> 适用范围：所有 WidgetKit 渲染的场景（Live Activity 锁屏卡片 / 灵动岛 / Widget 小组件）

---

## 一、问题现象

锁屏实时活动卡片（Live Activity）左上角的 App 图标显示为**黑色方块**，而不是绿色扫帚 App 图标。

- 模拟器和真机都能复现
- 卡片其他内容（文字、按钮、背景色）完全正常
- 图标位置稳定黑块，偶发灰块

## 二、五轮排查全记录（重要：别重蹈覆辙）

| 轮次 | 方案 | 理论依据 | 结果 |
|---|---|---|---|
| 1 | Asset Catalog + `UIImage(named:)` | Apple 官方推荐路径 | ❌ 黑块 |
| 2 | `.bin` 散文件直读（`UIImage(contentsOfFile:)`，绕开 actool/pngcrush） | 避免 deepmap2 压缩改写 PNG | ❌ 黑块 |
| 3 | imageset 补全 1x/2x/3x + `NSCache` 缓存成功解码值 | 修缺尺度 + 修首帧时序坏缓存 | ❌ 黑块 |
| 4 | SwiftUI 原生 `Image("LiveActivityIcon")`（WidgetKit 静态解析） | 跳过 UIImage 运行时管线 | ❌ 黑块 |
| 5 | **图标 PNG 以 Base64 硬编码进二进制，`UIImage(data:)` 纯内存解码** | 位图数据随代码走，零外部依赖 | ✅ 解决 |

### 每一轮都「验证通过」却真机黑块的教训

前四轮每一轮都在**开发进程内**做了充分验证——UIImage 解码正常、cgImage 有像素、亮度统计非黑——但真机渲染依然黑块。原因：

**开发进程（App / swiftc 测试进程）与 Live Activity 渲染进程是两个完全不同的环境。**

- 渲染进程是 WidgetKit 管理的独立沙盒进程（ chronod 拉起的 `com.hxwl.qlzs.liveactivity` XPC 服务）
- 快照渲染在**时间敏感窗口**内完成，且位图数据需要**跨进程传输**
- 任何「资源查找 → 解码 → 跨进程传递」三段式的图片加载路径，都可能在某一段失败
- 失败时 UIImage 对象**仍然非 nil**（内部是占位数据），`cgImage` 校验也拦不住 → 画出黑块

## 三、最终方案：Base64 内嵌

### 原理

把图标 PNG 压缩后转 Base64 字符串**硬编码进源代码**，编译进二进制。运行时 `Data(base64Encoded:)` → `UIImage(data:)` 纯内存解码。

数据流完全在进程内：**无文件 IO、无 asset 解析、无跨进程资源查找**。位图随代码走，渲染环境拿到的就是一段普通的 `UIImage` 内存对象。

### 尺寸选择

- 锁屏卡片图标显示 34pt
- @3x 需要约 102px，取 **204×204**（2 倍余量，视觉无损）
- PNG optimize 后约 52KB → Base64 约 70KB，编译进二进制无感知

### 实现文件

**`Widgets/LaIconData.swift`** — Base64 数据常量（生成脚本生成，勿手改）：

```swift
import UIKit

enum LaIconData {
    static let pngBase64 =
        "iVBORw0KGgo..." +   // 每行 96 字符
        "..."                 // 行间用 + 连接
}
```

**`Widgets/CleanLiveActivity.swift`** — 加载逻辑：

```swift
struct AppIconView: View {
    var size: CGFloat

    // 纯内存解码，无失败路径，static let 安全
    private static let embeddedIcon: UIImage? = {
        guard let data = Data(base64Encoded: LaIconData.pngBase64,
                              options: .ignoreUnknownCharacters),
              let img = UIImage(data: data),
              let cg = img.cgImage, cg.width > 0 else { return nil }
        return img
    }()

    var body: some View {
        if let icon = Self.embeddedIcon {
            Image(uiImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        } else {
            // 防御兜底（理论上不可达）：品牌色块 + SF Symbol
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(Color(red: 0.55, green: 0.89, blue: 0.68))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundStyle(.white)
                )
        }
    }
}
```

### Base64 生成脚本（换图标时重跑）

```python
from PIL import Image
import base64

img = Image.open('AppIcon_1024.png')          # 原始 1024x1024 图标
small = img.resize((204, 204), Image.LANCZOS)  # 显示尺寸的 2 倍
small.save('/tmp/la_icon.png', optimize=True)

b64 = base64.b64encode(open('/tmp/la_icon.png', 'rb').read()).decode()
lines = [b64[i:i+96] for i in range(0, len(b64), 96)]

parts = []
for i, ln in enumerate(lines):
    if i == 0:
        parts.append(f'        "{ln}" +')
    elif i == len(lines) - 1:
        parts.append(f'        "{ln}"')
    else:
        parts.append(f'        "{ln}" +')

swift = 'import UIKit\n\nenum LaIconData {\n    static let pngBase64 =\n' \
        + '\n'.join(parts) + '\n}\n'
open('Widgets/LaIconData.swift', 'w').write(swift)
```

**生成脚本的坑**：每行字符串必须用引号包好、行间用 `+` 连接、首行前不能多引号。生成后直接编译验证，一次引号格式错误就是一轮编译失败。

## 四、排查方法论（比方案本身更值钱）

### 1. 先建立本地可视化验证手段

前四轮效率低的根源：只能「进程内单测通过 → 祈祷真机正常」，无法闭环。
第四轮后发现在模拟器上**锁屏截图能直接拍到 LA 卡片**（`xcrun simctl io booted screenshot`），才实现本地闭环迭代。

### 2. 系统侧日志是金矿

验证 LA 是否拉起，查 chronod 日志：

```bash
xcrun simctl spawn booted log show --last 5m \
  --predicate 'process == "chronod"' --info |
  grep "Publishing changed activity descriptors"
# count = 1 即 LA 成功注册
```

渲染器缓存的图标可以直接提取检查：

```
~/Library/Developer/CoreSimulator/Devices/<UDID>/data/Library/chronod/icons/Ƭ::<bundleId>.heic
```

### 3. 不要相信「日志没有 = 代码没跑」

App 自定义 Logger 的 info 级日志在 `log show` 里经常不出现（被过滤）。
判断代码是否执行，要看 **UI 结果**或**系统侧日志**，不能只看 App 日志。

### 4. 进程内单测通过 ≠ 渲染进程正常

UIImage 解码、cgImage 完整性、亮度统计等所有「图片本身」的检查都可能在开发进程通过，而渲染进程的黑块发生在「跨进程拿位图」这一段——单测根本覆盖不到。

## 五、给后续项目的规则

1. **Widget / Live Activity 里显示静态图片，默认用 Base64 内嵌方案**（本方案的 `LaIconData.swift` 模式），不要尝试 Asset Catalog 或文件路径
2. 例外：SF Symbol（`Image(systemName:)`）始终可靠，小图标优先用 SF Symbol
3. 图标更新流程：替换源 PNG → 重跑生成脚本 → 编译 → 模拟器锁屏截图验证
4. `static let` 缓存 UIImage 在**纯内存数据源**下是安全的（无失败路径可缓存）；但任何涉及 IO 的加载禁止用 `static let` 缓存结果

## 六、相关文件

| 文件 | 作用 |
|---|---|
| `Widgets/CleanLiveActivity.swift` | LA 卡片视图 + AppIconView（内嵌图标加载） |
| `Widgets/LaIconData.swift` | Base64 图标数据常量（脚本生成） |
| `Widgets/Assets.xcassets/LiveActivityIcon.imageset/` | 保留（历史方案，已不依赖） |
| `Widgets/Resources/AppIcon.bin` | 保留（历史方案，已不依赖） |
| 项目记忆 `.workbuddy-ai/memory/2026-11-21.md` | 五轮排查的完整日志 |
