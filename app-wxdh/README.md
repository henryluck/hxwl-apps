# 马甲开机包 · 智能卫星导航

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
- **资格未确认**（`introOfferState == .unknown`，如商品未就绪/网络失败）：标题「正在确认会员方案」+「重新检查」，不展示首期价、不按新人处理、CTA 禁用

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

## 本包身份

| 项 | 值 |
|---|---|
| 马甲包 | 智能卫星导航 |
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

## 上架前核对

1. bundle_id / 显示名与本包开发者账号下登记的一致
2. 埋点/推送/崩溃/中台凭证为本包**独立注册**，不复用母包
3. 图/视频素材为全新设计（母包素材已在生成时清除，`Resources/assets/` 内即最终物料）
4. 协议（privacy/terms/续费规则等）主体为本包公司主体（`Resources/spec.json` 的 compliance.legal）
5. 正式提交前用 Archive + 真机回归一遍

## 工程约定

- 工程配置写 `project.yml`——不要手改 `.xcodeproj`（每次构建被 xcodegen 重建）
- 数据契约 `Resources/spec.json`（AppSpec 字段只增不改名）
