# Bugly dSYM 缺失问题与修复

## 报错原文

> The archive did not include a dSYM for the Bugly.framework with the UUIDs
> [5AE43443-64A0-3D03-82CC-BDF902527112]. Ensure that the archive's dSYM folder
> includes a DWARF file for Bugly.framework with the expected UUIDs.

## 根因

- Bugly 官方 SDK 的 `Bugly.framework` 是 **静态库**（`ar archive`，内含
  `libBugly.a-arm64-master.o`）。
- 经 SPM `binaryTarget` 接入后，swift-build 在链接 app 时会为它生成一个
  **转发空壳 dylib** 塞进 `App/Frameworks/Bugly.framework/Bugly`：
  - `__TEXT` 段 0 字节、无任何导出符号（`nm -gU` = 0）
  - 带 LC_UUID（链接期随机生成，如 `5AE43443-…`）
  - 真实的 Bugly 代码（97 个 BLY ObjC 类、202 处 `[Bugly]` 日志字符串）全部
    静态链入主程序
- Xcode 归档时 `dsymutil` 对这个空壳报 "no debug symbols in executable"，
  于是归档的 `dSYMs/` 里只有主程序的 dSYM，没有 Bugly.framework 的 →
  App Store Connect / Organizer 机械比对 UUID 后报警。

## 影响

- 只是**上传校验报警**，不影响上架审核；也不影响崩溃解析 —— Bugly 的
  崩溃栈落在主程序里，主程序的 `.app.dSYM`（UUID `F53A0AB4-…`）才
  是符号化真正需要的文件。
- 但每次归档上传都会弹这个 warning，且 Xcode Organizer 的 dSYM 列表不完整。

## 修复

对空壳 dylib 跑 `dsymutil`，生成**同 UUID 的 dSYM 容器**（空 DWARF 也能产
出合法容器，校验只比对 UUID）：

```bash
dsymutil "<archive>/Products/Applications/<App>.app/Frameworks/Bugly.framework/Bugly" \
    -o "<archive>/dSYMs/Bugly.framework.dSYM"
```

工程里已封装成脚本，每次 `xcodebuild archive` 之后、上传之前跑一次：

```bash
Scripts/fixup-dsyms.sh "<xcarchive 路径>"
```

脚本逻辑：遍历归档 `Frameworks/` 下所有 framework，按 UUID 查 `dSYMs/`
里是否已有匹配的 dSYM，缺的自动补（幂等，可重复执行）。

一份与本次归档同 UUID 的样例 dSYM 已存放在：
`Packages/Integrations/CrashBugly/dSYMs/Bugly.framework.dSYM`
（注意：**每次重新归档 UUID 都会变**，此文件只是样例，实际使用以脚本生成
的为准。）

## 验证

```bash
# 归档里两个二进制的 UUID
dwarfdump --uuid "<archive>/Products/Applications/<App>.app/<App>"            # F53A0AB4-…
dwarfdump --uuid "<archive>/Products/Applications/<App>.app/Frameworks/Bugly.framework/Bugly"  # 5AE43443-…

# dSYMs/ 里必须能找到同样两个 UUID
ls "<archive>/dSYMs/"
# Bugly.framework.dSYM  垃圾清理助手.app.dSYM
```

## 备选方案（未采用）

1. **静态直链**：不用 SPM `binaryTarget`，把 `libBugly.a` 直接加为
   Frameworks 链接项 —— Frameworks/ 下不再出现空壳 dylib，问题消失。
   代价：脱离 SPM 依赖图，头文件/Modules 要手工配置。
2. **官方 dSYM**：Bugly 官网可下载 SDK 自带 dSYM，但那是**官方库**的 UUID，
   与本机链接出的空壳 dylib UUID 永远不匹配，帮不上这个报错。
3. **改写 UUID**：十六进制编辑 dSYM 容器把 UUID 改成目标值。能过校验但
   属于 hack，且工具链不可靠，不推荐。

## 为什么同一个报错会反复出现（4 个不同 UUID）

每次重新归档，链接器都会重新生成一次空壳 dylib，`LC_UUID` 必然变化
（`5AE43443` → `4E091F7F` → `6277C456` → `F700C405` …）。所以「手工补一次」
只对那一个归档有效，重新 Archive 就复发。

更关键的坑：旧版 scheme 的 archive postAction 用 `${BUILD_ROOT}/../../..`
反推工程目录，实际指到 `~/Library/Developer/Xcode/DerivedData/`
（`Products` → `Build` → `DerivedData/FactoryCore-xxx` → `DerivedData`），
`fixup-dsyms.sh` 永远找不到 → **GUI 归档从未自动补过**。命令行
`archive.sh` 一直是好的，所以只有从 Xcode Organizer 上传时反复报警。

另外确认：`otool -L` 显示主程序并不依赖
`@rpath/Bugly.framework/Bugly`（空壳 `__text` = 0、导出符号 = 0），
Bugly 真代码全部静态链入主可执行文件，所以补的只是「过校验的空容器」。

## 现在的三层保险

1. **`project.yml` → `postBuildScripts`**：Release 构建时直接把空壳 dSYM
   产到 `${DWARF_DSYM_FOLDER_PATH}`，Xcode 归档阶段会把该目录下所有
   `.dSYM` 一起收进 `archive/dSYMs/`。不依赖 scheme 缓存，GUI 与 CLI 归档都生效。
2. **`project.yml` → scheme 的 archive postAction**：归档后再按 UUID 兜底补一次，
   脚本自包含内联，不再引用工程内文件。
3. **`Scripts/fixup-dsyms.sh`**：上传前一键自检/修复。不传参数自动定位最新归档，
   遍历所有嵌入 framework + 主程序做 UUID 覆盖检查，输出 PASS/FAIL 并用退出码表示结果；
   `archive.sh` 也会调用它。

上传前（尤其是从 Xcode Organizer 里选归档上传）跑一次：

```bash
Scripts/fixup-dsyms.sh                       # 自动处理最新归档
Scripts/fixup-dsyms.sh "<xcarchive 路径>"    # 或显式指定
```

看到 `✓ 校验通过：所有 UUID 均有 dSYM，可以上传` 再上传。

⚠️ 生成新 scheme / 新 build phase 后，**Xcode 需要重启一次**才会加载
（会话内会缓存旧 scheme）。想完全绕开 GUI 直接用 `Scripts/archive.sh` 归档即可。
