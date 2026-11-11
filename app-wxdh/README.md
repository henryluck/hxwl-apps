# 马甲开机包 · 智能卫星定位

> 已差异化的可构建源码工程：母包装配 → 配置/素材注入 → 符号重命名 → 结构扰动。
> 本包自包含（含 factory.py），在任意 Mac 构建机上出包即可装机验证。

## 构建出包

依赖：macOS + Xcode + xcodegen（`brew install xcodegen`）。

```bash
cd <解压目录>
python3 factory.py build-source --source .
# 成功：DerivedData/Build/Products/Debug-iphonesimulator/*.app
```

- 模拟器构建默认 `ARCHS=arm64`（Xcode 26 起已无 Rosetta 模拟器，需 Apple Silicon Mac）
  如需 x86_64 切片：`FACTORY_SIM_ARCH=x86_64 python3 factory.py build-source --source .`
- 真机构建加 `--device`（需在 Apple 开发者后台配好签名证书/描述文件）
- 首次构建如报 SPM 沙箱错误，先执行：
  `defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES`

## 功能模块

导航能力以本地 SPM 包 `Packages/NavKit` 实现（插件 id `nav_kit`，`ownsTabBar: true` 整屏接管底部四 Tab）。

| Tab | 页面 | 依赖 |
|---|---|---|
| 导航 | 卫星地图首页 / 地点联想 / 搜索结果 / 周边列表 / 路线方案 / 导航中 / 到达页 | MapKit（`MKDirections`、`MKLocalSearch`、`MKLocalSearchCompleter`） |
| 罗盘 | 真实方位盘面、真北/磁北、二十四山、校准引导 | CoreLocation heading |
| 海拔 | 实时海拔、垂直精度、坐标复制、海拔记录 | CoreLocation altitude |
| 天气 | 实况 / 24 小时 / 7 天、地区切换 | Open-Meteo（无需密钥） |

支撑模块：`LocationService`（单次/连续定位分离、权限态分档）、`RouteService`（驾车/步行/骑行三方式）、`NavEngine`（`NavPhase` 状态机、偏航 3 次重算、分档语音播报）、`VoiceService`（AVSpeechSynthesizer，音频中断/闪避）、`Stores`（历史 20 条、海拔记录 20 条、停车便签、天气地区，UserDefaults+Codable）、`Geo`（WGS-84 ⇄ GCJ-02）。

会员门槛：`NavAppModel.requireMembership()` → `.presentPaywall` 通知 → 宿主 `ShellRootView` 弹订阅页；法务文档走 `.presentLegalDoc`。

## 会员商品

订阅页按需求「订阅四场景」实现：**场景 = 变体 × 首期资格**（`PaywallVariant` + `PayStore.introOfferState`），同一份配置渲染四种页面。

| 场景 | 变体 | 首期资格 | 展示内容 | 按钮 | 入口 |
|---|---|---|---|---|---|
| 01 | `.startup` | 有 | 「首周 5.8，之后 ¥58/周」，无选择卡 | 下一步 | 开机引导第 4 页 |
| 02 | `.unlock` | 有 | 四卖点 + 周「首周优惠 / 之后 ¥58/周，自动续费 / 首周 5.8」+ 终身「¥188」，**默认选周** | 继续 | 功能拦截 / 我的·会员卡 |
| 03 | `.startup` | 无 | 「¥58/周」，无选择卡，无首周暗示 | 下一步 | 开机引导第 4 页 |
| 04 | `.unlock` | 无 | 四卖点 + 周「周会员 / 每周自动续费，可随时取消 / ¥58 /周」+ 终身「¥188」，**默认选周** | 继续 | 功能拦截 / 我的·会员卡 |

另有两种与变体无关的页面形态：

- **权益已生效**（`isPro`）：标题「会员权益已生效」+ 会员卡 + 按钮「返回使用」，不显示协议勾选
- **资格未确认**（`introOfferState == .unknown`，如商品未就绪/网络失败）：标题「正在确认会员方案」+「重新检查」，不展示首期价、不按新人处理、CTA 禁用。进入页面会主动 `reloadProducts()` 重拉商品 + 刷权益 + 重判资格（结果落 `@State` 触发重绘，因为 `any PayService` 传入且 `AnyPayService` 不转发 `objectWillChange`），点「重新检查」同样会真正重发 StoreKit 商品请求；首次请求失败可自愈，不会永久卡住
  - 模拟器常见根因：`ASDErrorDomain 509 "No active account"`（未登录沙盒账号）→ 商品列表为空 → 资格恒 unknown。本地已配 `Resources/Products.storekit`（见下节）；生产需确认 ASC 商品已生效

价格与商品 ID 全部来自 `Resources/spec.json` 的 `monetization` 段，改配置即改价，无需改代码。

| 套餐 | 商品 ID | 类型 | 价格 | spec 字段 |
|---|---|---|---|---|
| 周会员（自动续费） | `com.hxwl.wxdh.weekly` | 自动续订订阅 | 首期 ¥5.8，续费 ¥58/周 | `product_id` / `weekly_intro` / `weekly_renew` |
| 终身会员（买断） | `com.hxwl.wxdh.unlimited` | 非消耗型 | ¥188 一次付清 | `lifetime_product_id` / `lifetime_price` |

- `lifetime_enabled` 控制终身方案是否可用（关闭时 `.unlock` 场景自动只显示周方案）
- `default_plan`（`weekly`/`lifetime`）控制解锁场景默认选中项，当前按需求为 `weekly`
- 终身权益计入同一 `isPro`，购买/恢复后 `ownsLifetime` 为 true，「我的」会员卡显示「终身会员 · 永久有效」而非「到期自动续费」
- 未配置的商品不会进 `Product.products(for:)` 请求；商品未返回时资格置 `unknown`（不按新人展示首期价）
- 订阅按钮带 90%→110%→90%、0.8 秒循环呼吸动效，处理中/覆盖弹层/后台/「减少动态」时恢复静态
- 未解锁页面（罗盘/海拔）连续停留 10 秒自动提醒一次，订阅页关闭后重新计时
- ASC 后台需同时创建上述两个商品并随版本提交，否则沙盒下点购买会提示「商品信息未加载」

调试入口：启动环境变量 `SIMCTL_CHILD_NAV_DEBUG_SCREEN=<home|nearby|plan|navigating|compass|altitude|weather>`、`SIMCTL_CHILD_NAV_DEBUG_UNLOCK=1`（仅 DEBUG 生效）。
订阅页调试：`SIMCTL_CHILD_PAY_DEBUG_OPEN=1` 直接拉起订阅页；`SIMCTL_CHILD_PAY_DEBUG_VARIANT=startup|unlock` 指定变体（默认 unlock）；`SIMCTL_CHILD_PAY_DEBUG_ELIGIBILITY=available|unavailable|unknown` 固定首期资格（四场景截图用）；`SIMCTL_CHILD_ONBOARDING_DEBUG_PAGE=3` 直接落到引导第 4 页。

## 本地 StoreKit 商品配置（模拟器免沙盒账号）

`Resources/Products.storekit` 按 ASC 清单建了 5 个本地商品，与 `spec.json` 的 `monetization` 一一对应（清单核对结果完全一致）：

| 套餐 | 商品 ID | 首期 / 续费 | 本地首期优惠 | spec 字段 |
|---|---|---|---|---|
| B · 默认 | `com.hxwl.wxdh.weekly` | 5.8 / 58 | 一次性预付 1 周 | `product_id` / `weekly_plans.B` |
| D · sale | `com.hxwl.wxdh.weekly.sale` | 1.8 / 48 | 一次性预付 1 周 | `weekly_plans.D` |
| C · deal | `com.hxwl.wxdh.weekly.deal` | 8 / 48 | 一次性预付 1 周 | `weekly_plans.C` |
| A · offer | `com.hxwl.wxdh.weekly.offer` | 0 / 58 | 免费试用 3 天 | `weekly_plans.A`（`trial_days: 3`） |
| 终身 | `com.hxwl.wxdh.unlimited` | 188 买断 | — | `lifetime_product_id` |

- 四个周商品分属**四个独立订阅组**（首期资格按订阅组判定；若 ASC 里实际是同一组，需同步改本地配置的分组）
- 通过 `project.yml` 的 `scheme.storeKitConfiguration` 写进 `FactoryCore.xcscheme` 的 `StoreKitConfigurationFileReference`；文件用 `buildPhase: none` 只挂在工程导航器，**不进 app bundle**
- **只在 Xcode 点 ⌘R 时生效**：Xcode 会把配置推送给模拟器的 storekitd。`xcodebuild` + `simctl install/launch` 不会注入，仍会看到 `ASDErrorDomain 509 "No active account"` 与「已加载 0 个商品」——这是 Xcode 机制，不是配置写错
- 真机 / 提审走 ASC 真实商品：确认 5 个 ID 已创建、状态可用并随版本提交，且登录沙盒账号；本地 `.storekit` 与生产无关

## Xcode 工程重建（xcodegen）与 `Unable to find module dependency`

`project.yml` 是工程真相源，`.xcodeproj` 每次 `xcodegen generate` 都被重建。重建**不会**写回 Xcode 模板的默认 build settings，必须在 `project.yml` 里显式补齐，否则会出现只在 Xcode GUI（⌘B / ⌘R，具体模拟器 destination）复现、而 `xcodebuild -destination 'generic/platform=iOS Simulator'` 却成功的问题。

症状：`Sources/AppSpec.swift:1:8: error: Unable to find module dependency: 'CoreKit'`，`BaseComponents` / `Capabilities` / `NavKit` 同样报错。这是**真实的 Swift 编译错误**，不是索引器缓存，`File → Packages → Resolve Package Versions` 解决不了。

根因：Debug 的 `ONLY_ACTIVE_ARCH` 被冲成 `NO` → 主 target 在模拟器同时编 `arm64 + x86_64`，而本地 SPM 包 target 在 Debug 只产出 `arm64` 的 `.swiftmodule` → x86_64 那次编译找不到对应架构的模块。generic destination 下所有 target 都编双架构，所以命令行构建把问题掩盖了。

`project.yml` 的 `settings.configs.Debug` 已固定以下项：

| 设置 | 值 | 作用 |
|---|---|---|
| `ONLY_ACTIVE_ARCH` | `YES` | 主 target 只编当前设备架构，与 SPM 包一致 |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | `DEBUG` | 缺了它 `#if DEBUG` 全被裁掉，`PAY_DEBUG_*` / `NAV_DEBUG_*` 调试入口静默失效 |
| `ENABLE_TESTABILITY` | `YES` | Debug 支持 `@testable import` |
| `DEBUG_INFORMATION_FORMAT` | `dwarf` | Debug 调试符号 |

`settings.base` 另补回 `ALWAYS_SEARCH_USER_PATHS` / `CODE_SIGN_IDENTITY` / `DEVELOPMENT_TEAM`（真机签名 + headermap）；Release 的 `ONLY_ACTIVE_ARCH` 保持 `NO`。改完执行 `/Users/gx/.local/bin/xcodegen generate --spec project.yml`（本机 PATH 里没有 xcodegen），Xcode 里先 **⇧⌘K Clean Build Folder** 清掉旧缓存再 ⌘B / ⌘R。

## 多策略商品映射（投放分流 A/B/C/D）

参考《多策略商品映射-跨App移植参考.md》移植：按投放归因（天枢 strategyId）把用户分流到 A/B/C/D 四个周订阅商品之一，**服务端全权下发决策**（套餐 + productId + 文案），客户端校验、兜底与渲染；任何失败回落兜底套餐 B（= 单一主商品现状，客户端可先行发版）。

| 套餐 | productId | 价格 | 类型 |
|---|---|---|---|
| A | `com.hxwl.wxdh.weekly.offer` | ¥0 试用 3 天 / 续 ¥58 | 试用型 |
| **B（兜底）** | `com.hxwl.wxdh.weekly` | ¥5.8 首周 / 续 ¥58 | 首周优惠 |
| C | `com.hxwl.wxdh.weekly.deal` | ¥8 首周 / 续 ¥48 | 首周优惠 |
| D | `com.hxwl.wxdh.weekly.sale` | ¥1.8 首周 / 续 ¥48 | 首周优惠 |

终身 ¥188 与挽留商品**不参与分流**。

**配置开关**：`spec.json → monetization.weekly_plans`。空 = 未启用分流（单一主商品，全功能静默关闭）；非空 = 启用。删除某套餐时其 product_id 必须移入 `legacy_product_ids` 承接存量订阅放权（换策略不掉 Pro 红线）。

**五层实现**：
1. spec 配置（`weekly_plans` + `legacy_product_ids`，宽松解码兼容旧 spec）
2. 决策存储 `Packages/Capabilities/.../PaywallStrategyStore.swift`（拉取/校验/持久化/有界等待 2s/埋点/DEBUG 演示）
3. 支付多商品 `PayService.swift`（全商品加载、`activeWeeklyProductID` 切换、全量放权、按 active 下单）
4. 订阅页渲染 `PaywallPlanCopy.swift`（文案三级兜底：服务端 copy → 内置模板 → 现状 B；决策冻结防热切换；购买目标=展示套餐）
5. 壳层装配 `FactoryApp.swift`（归因成功后拉决策；决策变化 → active 同步；环境注入）

**服务端**（`/Users/gx/apps-dev/code/ios-server`）：`POST /api/v1/paywall/strategy` 已上线；映射表 `data/paywall_strategy_map.json` 已配本 App 四商品（management 热编辑，改完即生效）。查不到/天枢失败 → `"plan": "DEFAULT"` + B 兜底（success=true，客户端 fallback 埋点量化健康度）。

**上线顺序红线**：ASC 建好并生效商品 → 天枢北极星配 commodityId → 最后才在映射表加 strategyId 映射。客户端对「spec 内但商店加载不到」的商品会整组回落 B 售卖。

**演示**（服务端未就绪时）：`xcrun simctl launch <udid> com.hxwl.wxdh -paywallPlan D` 强制按 D 套餐渲染（仅 DEBUG）。线上健康度看 `paywall_strategy_show` 埋点的 fallback 占比。

## 本包身份

| 项 | 值 |
|---|---|
| 马甲包 | 智能卫星定位 |
| 代号 | — |
| bundle_id | com.hxwl.wxdh |

## 后台对接（ios-server）

网关代理配置在 `Resources/spec.json → integrations.edge`，客户端与服务端 `.env` 必须同密钥：

| 项 | 值 |
|---|---|
| baseURL | `https://znwxdh.gzhuanxiwl.com`（本地联调改 `http://127.0.0.1:8000`） |
| prdId | `4115206`（客户端透传、服务端不覆盖；缺 prdId 服务端拦截 9004）。**该 server 同时服务产品线 4115205**，两 App 各自带 prdId 即可区分，服务端零配置 |
| aesKey / aesIv | `BHEBEQd6Qz96aroF` / `B3FaqODiH2GLRNhP`（各 16 字节，与 server `.env` 完全一致；**勿复用其他马甲包密钥**） |
| channel | 61 |

接入范围：

- **启动链路**（Capabilities.ZhongtaiClient，路径 `/api/v1/*`，包络 `{ok, code, message, result}`）：session/start 登录 → install/attribute 归因 → $AppStart 埋点；IAP 验单/支付状态、订阅策略、反馈同走此通道。
- **天气**（NavKit.NavGateway）：Open-Meteo 已移除，改走 `/api/v1/forecast/{now,24h,7d}`（和风 v1，凭证只在服务端）；网关未配置时天气页进入「暂不可用」。
- **意见反馈**（NavKit.ProfileScreen）：真实提交 `/api/v1/support/feedback`（服务端 SQLite 落库），不再只存本机。
- **高德 key**：`integrations.amap.key = 856a4ff6f2205897f26684589161dd8f`（iOS 平台 key）。当前地图用 MapKit，未引入高德 SDK；后续切高德时读取此配置。
- 服务端仓库：`/Users/gx/apps-dev/code/ios-server`（部署 `./scripts/deploy_prod.sh` → znwxdh.gzhuanxiwl.com）。

联调：

```bash
# server 侧（PRD_ID 按产品线传：4115206=本包；4115205=共用此 server 的另一产品线）
PRD_ID=4115206 python scripts/make_request.py --url http://127.0.0.1:8000/api/v1/session/start --data '{}'
```

## 地图品牌水印（MapKit 中国区「高德地图」）

当前地图是 **Apple MapKit `MKMapView`**，不是高德 SDK。参考《去掉高德logo的方法.md》里的
`MAMapView.logoEnable` / `logoCenter` / `AMapNaviDriveView` 都不能用；`NavKit/Package.swift`
没有 AMap 依赖，spec 里的 amap key 只是预留配置。MapKit 在中国区使用高德数据，会在地图右下角
自己挂一个半透明「高德地图」描边 logo。

实现见 `Packages/NavKit/Sources/NavKit/MapBranding.swift`，接入点在
`MapView.makeUIView`（建图）与 `updateUIView`（卫星/标准图层切换后重建内部视图时重挂）。

- **实测视图层级**（iOS 26 模拟器 / zh_CN，`LOGO_DEBUG=1`）：
  `MKMapView` → `UIImageView (46x10)`（图片 anonymous、无名称，就是高德 logo）与
  `MKAttributionLabel (29x11)`（Apple 的 Legal/归属入口）。logo 是 MKMapView 直接子视图，
  且**惰性创建**，建图瞬间遍历不到。
- **多信号命中**：类名含 `logo` / 图片描述含 `logo|amap|autonavi` / `UIImageView` 宽 40~110pt
  且扁平（`h <= w/2.2`）/ 文字含「高德」或 `AMap`。参考文档里高德 SDK logo 是 70pt，MapKit 只有
  46pt，下界必须放到 40；`showsScale` / `showsCompass` 已关，不会误中比例尺和指南针。
- **不隐藏 `MKAttributionLabel`**：第一版按 `attribution` 类名命中，只藏掉了 Apple 的 Legal，
  高德 logo 原样保留（裁剪图 md5 完全相同）。它属于归属入口，保留可降低条款风险。
- **时序**：0 / 0.5 / 1.5 / 3.0 秒四拍处理惰性创建，另有一条每 3 秒的弱引用巡检链兜底
  （图层切换、地图复用后 MapKit 可能重建品牌视图）；用关联对象去重，避免 `apply(to:)` 被调多次
  累积多条链，视图释放后链自动终止。
- **只设 `isHidden` / `alpha`，不 `removeFromSuperview`**：MapKit 自维护子视图，直接移除容易
  触发布局震荡或被立刻重建。
- 调试：`xcrun simctl spawn <UDID> launchctl setenv LOGO_DEBUG 1` 后重启 App，控制台过滤
  `[LogoHunt]` 可看到完整层级与命中原因；验证完 `... launchctl unsetenv LOGO_DEBUG`。

验证结果：主工程 `** BUILD SUCCEEDED **`、Capabilities `16 tests / 0 failures`；
右下角裁剪放大图对比，原始版与第一版 md5 一致（无效），修正版与最终版 md5 一致且水印消失，
App 启动 9 秒后（越过四拍 + 首轮巡检）复查仍无水印。

> ⚠️ **合规风险（上架前必须确认）**：MapKit 的地图归属标注受 Apple MapKit 服务条款约束，
> 与高德 SDK 的商务授权不是同一回事；参考文档的做法以「已获得高德授权」为前提。
> 若未取得相应授权，请改用 `MapBranding.compliantMinimize(in:)`（保留展示，仅缩到 10%、
> alpha 0.35），或撤掉隐藏逻辑、恢复完整归属标注，并由法务确认后再提审。

## 上架前核对

1. bundle_id / 显示名与本包开发者账号下登记的一致
2. 埋点/推送/崩溃/中台凭证为本包**独立注册**，不复用母包
3. 图/视频素材为全新设计（母包素材已在生成时清除，`Resources/assets/` 内即最终物料）
4. 协议（privacy/terms/续费规则等）主体为本包公司主体（`Resources/spec.json` 的 compliance.legal）
5. 正式提交前用 Archive + 真机回归一遍

## 工程约定

- 工程配置写 `project.yml`——不要手改 `.xcodeproj`（每次构建被 xcodegen 重建）
- 数据契约 `Resources/spec.json`（AppSpec 字段只增不改名）
