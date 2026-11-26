# 项目长期约定（智能卫星导航 / app-wxdh）

## 工程
- 工程配置只写 `project.yml`，`.xcodeproj` 每次构建被 xcodegen 重建，不要手改
- xcodegen 重建会冲掉 Xcode 模板默认 build settings，必须在 `project.yml` 显式写回：base 的 `ALWAYS_SEARCH_USER_PATHS`/`CODE_SIGN_IDENTITY`/`DEVELOPMENT_TEAM`；Debug 的 `ONLY_ACTIVE_ARCH=YES`（否则主 target 编 arm64+x86_64 而本地 SPM 包只编 arm64 → Xcode GUI 报 `Unable to find module dependency`，generic destination 命令行不复现）、`SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`（否则 `#if DEBUG` 全被裁掉，`PAY_DEBUG_*` 调试入口静默失效）、`ENABLE_TESTABILITY=YES`、`DEBUG_INFORMATION_FORMAT=dwarf`；Release `ONLY_ACTIVE_ARCH=NO`
- 数据契约 `Resources/spec.json`（AppSpec 字段只增不改名，新增字段必须有 decodeIfPresent 默认值）
- 业务能力以本地 SPM 包实现（`Packages/NavKit` 等），插件通过 `PluginManifest.ownsTabBar` 决定是否整屏接管底部导航
- 插件不直接依赖宿主：会员拦截走 `.presentPaywall`、法务走 `.presentLegalDoc` 通知

## 商业化
- 商品 ID / 价格 / 套餐开关一律写在 `spec.json` 的 `monetization` 段，代码里不硬编码金额
- 当前商品（对齐需求包 v0.25-20261026）：`com.hxwl.wxdh.weekly`（周订阅，首期 ¥5.8 / 续费 ¥58/周）、`com.hxwl.wxdh.unlimited`（终身买断 ¥188，非消耗型）
- 多策略分流四套餐（2026-11-02 接入）：A `weekly.offer` 0试用3天/58、B `weekly` 5.8/58（兜底=主商品）、C `weekly.deal` 8/48、D `weekly.sale` 1.8/48；`monetization.weekly_plans` 非空即启用，空=单一主商品现状；删套餐必须进 `legacy_product_ids` 承接存量放权
- 订阅类商品与买断类商品必须分开维护：`subscriptionIDs` 只放订阅（影响首期资格/到期召回），`entitlementIDs` 放全部放权商品
- 订阅页四场景 = 变体(`.startup`/`.unlock`) × 首期资格三态（available/unavailable/unknown）；资格 unknown 不按新人展示首期价；02/04 场景默认选周（`default_plan: weekly`）；需求真相源 /Users/gx/apps-dev/导航/智能卫星导航-交付开发-v0.25-20261026
- 首期资格 unknown（商品未就绪等）不等于新用户—— StoreKit 商品加载失败时 `introOfferState` 置 unknown，订阅页显示「重新检查」而非首期价
- 策略决策链路：归因成功 → `/api/v1/paywall/strategy` → PaywallStrategyStore 校验/持久化 → sink 同步 pay.setActiveWeeklyProduct → PaywallView 冻结渲染；服务端映射表 /Users/gx/apps-dev/code/ios-server/data/paywall_strategy_map.json 热编辑
- 上线顺序红线：ASC 建商品生效 → 北极星配 commodityId → 最后加映射表 strategyId；「spec 内但商店加载不到」整组回落 B
- DEBUG 演示：`xcrun simctl launch <udid> com.hxwl.wxdh -paywallPlan A|B|C|D`（仅 DEBUG）

## 品牌
- 主题色：导航青绿，`primary #087F5B`、`primaryLight #2A9D8F`、正文 `#193E30`；`theme_pack` 用 `mint`（已改写为青绿）
- 卡片圆角 10pt，可点击目标 ≥ 44pt
- 地图是 Apple MapKit `MKMapView`（中国区用高德数据，右下角自带「高德地图」描边 logo），**不是高德 SDK**；`/Users/gx/apps-dev/导航/去掉高德logo的方法.md` 的 `MAMapView.logoEnable` 不适用。去水印逻辑在 `Packages/NavKit/Sources/NavKit/MapBranding.swift`（多信号识别 + 四拍 + 弱引用巡检），实测 logo 是 `MKMapView` 直接子视图 `UIImageView (46x10)`，Apple 的 `MKAttributionLabel` 必须保留
- ⚠️ 隐藏 MapKit 归属标注有合规风险（受 Apple MapKit 条款约束，与高德 SDK 商务授权不等价）；未获授权时改用 `MapBranding.compliantMinimize(in:)`，上架前需法务确认

## 出包
- `python3 factory.py build-source --source .`，模拟器默认 arm64（Xcode 26 无 Rosetta 模拟器）
- 本机需 `defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES`
- 坑：本机 PATH 无 xcodegen（factory.py 会 FileNotFoundError）；但已生成的 project.pbxproj 是显式文件列表，改代码后直接 `xcodebuild -project FactoryCore.xcodeproj -scheme FactoryCore -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData build` 即可
- 包内单测：cd Packages/<pkg> && `xcodebuild test -scheme <pkg> -destination 'platform=iOS Simulator,name=iPhone 17'`（swift test 会因沙箱/依赖 iOS-only 包失败）
- 订阅页截图调试：`PAY_DEBUG_OPEN=1`，`PAY_DEBUG_VARIANT=startup|unlock`，`PAY_DEBUG_ELIGIBILITY=available|unavailable|unknown`；`SIMCTL_CHILD_XXX=1 simctl launch` 传参不可靠，改用 `xcrun simctl spawn <UDID> launchctl setenv KEY 1` 后重启 App，用完 `unsetenv`（`LOGO_DEBUG` 同理）
- Tab/子流程截图调试：`NAV_DEBUG_SCREEN=compass|altitude|weather|search|nearby|plan|navigating`（仅 DEBUG，`NavAppModel.applyDebugLaunchScreenIfNeeded`）；此版本 Xcode 的 `simctl io tap` 不存在，无法命令行点击
- 定位权限授权：`simctl privacy grant location` 在此版本不生效；直接写 TCC.db（参照 com.apple.Maps 的 access 行整行复制换 client，含 csreq/policy_id），**写完必须 shutdown+boot 重启模拟器**（locationd 启动时缓存）
- 引导态跳过：直接写 App 容器 `Library/Preferences/<bundle>.plist`（`get_app_container ... data` 定位；App 终止后 plutil -replace，再启动）；`simctl spawn defaults write <bundle-id>` 写的是全局域，App 读不到
- 启动序列：静态图 1.5s + splash.mp4 3.17s ≈ 4.7s 进引导页，截图等待 ≥7s；**修启动素材必须同时检查 splash.png 与 splash.mp4 帧**（两者同源，缺陷会同时存在）

## 天气（2026-11-11 修复）
- 服务端上游已升级为和风 v1 新格式：`temperature.value`、`condition.code`、`hours[].forecastTime`、`days[].temperatureMax.value`、`astro.sunrise`（完整 ISO）；v7 老格式字段（`now.temp`/`hourly[].fxTime`/`daily[].tempMax`）已不存在
- `NavWeatherParser`（NavGateway.swift）已兼容 v1/v7 双格式；改解析先跑 `Packages/NavKit/Tests/NavKitTests/NavWeatherParserTests.swift`（4 测试，样本取自线上真实响应）
- 单位归一：v1 湿度 0..1 ×100、风速 m/s ×3.6 → km/h（界面按 km/h、百分数展示）
- NavKit 单测要在 `Packages/NavKit` 目录下用 SPM 自动 scheme 跑（主工程的 NavKit scheme 没有 test action）
