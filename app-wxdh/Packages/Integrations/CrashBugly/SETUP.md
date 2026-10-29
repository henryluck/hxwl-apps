# CrashBugly 适配包设置说明

Bugly（腾讯）不支持 SPM，framework 在腾讯 CDN 上（需网页下载），无法自动获取。
本包做好骨架，**需要人工下载 framework 后放入指定目录**。

## 步骤

1. **下载 Bugly framework**
   - 访问 https://bugly.qq.com/v2/sdkDownload
   - 选 iOS 平台 → Bugly 2.6.1（标准版，不是 Pro 版）
   - 下载 zip，解压得到 `Bugly.framework`

2. **放到本目录**
   ```
   Packages/Integrations/CrashBugly/xcframeworks/Bugly.framework/
   ```

3. **打开 Package.swift 的 binaryTarget 注释**
   ```swift
   .binaryTarget(name: "Bugly", path: "xcframeworks/Bugly.framework"),
   ```

4. **打开 Adapter 里的真实调用**
   - `BuglyCrashAdapter.swift` 里的 TODO 处
   - init: `Crash.start(AppId: appId)`
   - breadcrumb: Bugly 留痕接口

5. **验证**
   - 在 project.yml 引用 CrashBugly
   - xcodebuild 编译通过
   - nm 验证二进制有 Bugly 符号

## 为什么不自动下载

Bugly 的二进制在腾讯 CDN（bugly.qq.com），下载需要网页交互/可能需要登录，
curl/wget 无法直接获取。GitHub 仓库只有 podspec，不含 framework。

## 版本信息

- Bugly 标准版 2.6.1（2024-04 发布，适配 Privacy Manifest）
- 不存在标准版 2.7/2.8（那是 BuglyPro 专业版，另一个 SDK）
