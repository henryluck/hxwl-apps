# 马甲开机包 · 垃圾清理助手

> 已差异化的可构建源码工程：母包装配 → 配置/素材注入 → 符号重命名 → 结构扰动。
> 本包自包含（含 factory.py），在任意 Mac 构建机上出包即可装机验证。

## 构建出包

依赖：macOS + Xcode + xcodegen（`brew install xcodegen`）。

```bash
cd <解压目录>
python3 factory.py build-source --source .
# 成功：DerivedData/Build/Products/Debug-iphonesimulator/*.app
```

- 模拟器构建默认 `ARCHS=x86_64`（Bugly 无 arm64-sim slice，Rosetta 模拟器可正常运行）
- 真机构建加 `--device`（需在 Apple 开发者后台配好签名证书/描述文件）

## 本包身份

| 项 | 值 |
|---|---|
| 马甲包 | 垃圾清理助手 |
| 代号 | — |
| bundle_id | com.hxwl.qlzs |

## 上架前核对

1. bundle_id / 显示名与本包开发者账号下登记的一致
2. 埋点/推送/崩溃/中台凭证为本包**独立注册**，不复用母包
3. 图/视频素材为全新设计（母包素材已在生成时清除，`Resources/assets/` 内即最终物料）
4. 协议（privacy/terms/续费规则等）主体为本包公司主体（`Resources/spec.json` 的 compliance.legal）
5. 正式提交前用 Archive + 真机回归一遍

## 工程约定

- 工程配置写 `project.yml`——不要手改 `.xcodeproj`（每次构建被 xcodegen 重建）
- 数据契约 `Resources/spec.json`（AppSpec 字段只增不改名）
