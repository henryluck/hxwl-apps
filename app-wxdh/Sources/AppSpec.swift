import CoreKit
import Foundation

/// 产品说明书（App 定义）—— 包内 spec.json 解码。
/// 字段契约见《产品定义规范》；plugins 段在 M2 起用于装配。
struct AppSpec: Decodable {
    struct Identity: Decodable {
        let id: String
        let name: String
        let bundle_id: String
        let version: String
        let build: Int
    }

    struct Brand: Decodable {
        let accent: String
        let plus_name: String
        let theme_pack: String?
    }

    struct PluginRef: Decodable {
        let id: String
        let config: [String: JSONValue]?
    }

    struct Content: Decodable {
        let catalog: String
    }

    struct Monetization: Decodable {
        let strategy: String          // 订阅策略：intro_price(首期低价) | free_trial(免费试用N天)
        let weekly_intro: Double      // 首期价（支持 ¥4.8 这类带小数价格）
        let weekly_renew: Int
        let trial_days: Int           // 免费试用天数（仅 free_trial 策略）
        let product_id: String
        let subscription_name: String     // 订阅名称（审核 3.1.2 要求应用内明示；空则付费墙回退「{App名} {Plus名}」）
        let paywall_copy: PaywallCopy
        // 挽留套餐（诱导页）：订阅页关闭后弹更低价挽留页
        let retention_enabled: Bool
        let retention_price: Int
        let retention_product_id: String
        // 终身会员（非消耗型买断）：与周订阅并存，订阅页可选套餐
        let lifetime_enabled: Bool
        let lifetime_price: Int
        let lifetime_product_id: String
        let lifetime_name: String
        /// 订阅页默认选中的套餐：weekly | lifetime（lifetime 未启用时强制 weekly）
        let default_plan: String

        struct PaywallCopy: Decodable {
            let welcome: String
            let features: [String]
            let button_label: String?        // 订阅主按钮文字（空=默认「立即解锁权益」）
            let show_privacy: Bool?          // 显示「隐私政策」入口（默认 true）
            let show_terms: Bool?            // 显示「用户协议」入口（默认 true）
            let show_restore: Bool?          // 显示「恢复购买」（默认 true）
        }

        // 自定义 init 需要显式声明 CodingKeys（否则编译器不会自动合成）
        private enum CodingKeys: String, CodingKey {
            case strategy, weekly_intro, weekly_renew, trial_days, product_id, subscription_name, paywall_copy
            case retention_enabled, retention_price, retention_product_id
            case lifetime_enabled, lifetime_price, lifetime_product_id, lifetime_name, default_plan
        }

        // 兼容旧 spec.json（无 strategy/trial_days/subscription_name/retention_*）→ 默认值
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            strategy = try c.decodeIfPresent(String.self, forKey: .strategy) ?? "intro_price"
            weekly_intro = try c.decodeIfPresent(Double.self, forKey: .weekly_intro) ?? 0
            weekly_renew = try c.decodeIfPresent(Int.self, forKey: .weekly_renew) ?? 0
            trial_days = try c.decodeIfPresent(Int.self, forKey: .trial_days) ?? 0
            product_id = try c.decodeIfPresent(String.self, forKey: .product_id) ?? ""
            subscription_name = try c.decodeIfPresent(String.self, forKey: .subscription_name) ?? ""
            paywall_copy = try c.decodeIfPresent(PaywallCopy.self, forKey: .paywall_copy)
                ?? PaywallCopy(welcome: "解锁全部会员内容", features: ["全部内容", "专属功能", "无广告", "持续更新"],
                               button_label: nil, show_privacy: nil, show_terms: nil, show_restore: nil)
            retention_enabled = try c.decodeIfPresent(Bool.self, forKey: .retention_enabled) ?? false
            retention_price = try c.decodeIfPresent(Int.self, forKey: .retention_price) ?? 0
            retention_product_id = try c.decodeIfPresent(String.self, forKey: .retention_product_id) ?? ""
            lifetime_enabled = try c.decodeIfPresent(Bool.self, forKey: .lifetime_enabled) ?? false
            lifetime_price = try c.decodeIfPresent(Int.self, forKey: .lifetime_price) ?? 0
            lifetime_product_id = try c.decodeIfPresent(String.self, forKey: .lifetime_product_id) ?? ""
            lifetime_name = try c.decodeIfPresent(String.self, forKey: .lifetime_name) ?? ""
            default_plan = try c.decodeIfPresent(String.self, forKey: .default_plan) ?? "weekly"
        }
    }

    struct Compliance: Decodable {
        let privacy_url: String
        let terms_url: String
        let support_email: String
        let legal: Legal?

        struct Legal: Decodable {
            struct Doc: Decodable {
                let source: String?        // template | ai | uploaded
                let html: String?          // 完整正文（离线浏览用）
            }
            let privacy: Doc?
            let terms: Doc?
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            privacy_url = try c.decodeIfPresent(String.self, forKey: .privacy_url) ?? ""
            terms_url = try c.decodeIfPresent(String.self, forKey: .terms_url) ?? ""
            support_email = try c.decodeIfPresent(String.self, forKey: .support_email) ?? ""
            legal = try c.decodeIfPresent(Legal.self, forKey: .legal)
        }
        private enum CodingKeys: String, CodingKey { case privacy_url, terms_url, support_email, legal }
    }

    /// 我的页 6 项配置（spec.support；缺省=全部走兜底/不显示）。
    struct Support: Decodable {
        struct Field: Decodable {
            let key: String
            let label: String
            let kind: String             // "text" | "picker"
            let options: [String]?
            let required: Bool?
        }
        struct Feedback: Decodable {
            let enabled: Bool?
            let fields: [Field]?
        }
        struct FAQItem: Decodable { let q: String; let a: String }
        struct FAQ: Decodable { let enabled: Bool?; let items: [FAQItem]? }
        struct About: Decodable {
            let enabled: Bool?
            let intro: String?
            let features: [String]?
            let contact_email: String?
        }
        struct Rate: Decodable {
            let enabled: Bool?
            let app_store_url: String?
        }
        let feedback: Feedback?
        let faq: FAQ?
        let about: About?
        let rate: Rate?

        var feedbackEnabled: Bool { feedback?.enabled ?? false }
        var faqEnabled: Bool { faq?.enabled ?? false }
        var aboutEnabled: Bool { about?.enabled ?? false }
        var rateEnabled: Bool { rate?.enabled ?? false }
    }

    struct Onboarding: Decodable {
        let splash: String?       // 开机加载页图片（assets 相对路径）
        let splash_video: String? // 开机加载页视频（assets 相对路径，如 assets/splash.mp4）；与 splash 无缝拼接
        let pages: [String]?      // 引导页图片序列
        let paywall_bg: String?   // 订阅页背景图
        let continue_label: String?   // 引导页底部「继续」按钮文字（空=默认「继续」）
    }

    /// 第三方集成配置。
    ///
    /// 新契约（provider + config）：每个能力声明用哪家厂商 + 该厂商的配置参数。
    /// 厂商实现是独立可选适配包，按 provider 选择链接哪个包（见 integration-registry.yml）。
    /// 能力缺省 = 不打包该能力（Null 兜底）；provider 是自由字符串，装配侧用
    /// `#if canImport(<能力><厂家>)` 路由到对应实现。
    struct Integrations: Decodable {
        /// 中台网关代理配置（走 ios-server AES 代理，对应 spec.integrations.edge 段）。
        /// baseURL=代理地址；aesKey/aesIv 各 16 字节；channel=渠道号（默认 61）。
        /// prdId 是**唯一权威来源**：服务端只透传、不覆盖，缺失时服务端本地拦截 9004。
        struct Zhongtai: Decodable {
            let prdId: String
            let baseURL: String
            let aesKey: String
            let aesIv: String
            let channel: Int

            private enum CodingKeys: String, CodingKey {
                case prdId, baseURL, aesKey, aesIv, channel
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                prdId = try c.decodeIfPresent(String.self, forKey: .prdId) ?? ""
                baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
                let key = try c.decodeIfPresent(String.self, forKey: .aesKey) ?? ""
                aesKey = key
                // 默认 IV = Key（历史约定兼容；本包 spec.json 显式配置了独立 IV）
                aesIv = try c.decodeIfPresent(String.self, forKey: .aesIv) ?? key
                channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? 61
            }
        }

        /// 高德开放平台配置（客户端持有的 iOS 平台 key）。
        struct Amap: Decodable {
            let key: String
        }
        /// 单个第三方能力的配置：provider（厂家）+ 透传给适配包的参数。
        struct ProviderConfig: Decodable {
            let provider: String            // 厂家标识，如 "sensors"/"umeng"/"jpush"/"bugly"
            let config: [String: String]?   // 该厂家所需参数（serverURL/token/appKey...）
        }
        let zhongtai: Zhongtai?
        let amap: Amap?
        let analytics: ProviderConfig?      // 埋点
        let push: ProviderConfig?           // 推送
        let crash: ProviderConfig?          // 崩溃上报

        // 兼容老格式（按厂商分字段 sensors/jpush/bugly）的影子结构
        private struct SensorsLegacy: Decodable { let serverURL: String; let token: String }
        private struct JPushLegacy: Decodable { let appKey: String; let masterSecret: String }
        private struct BuglyLegacy: Decodable { let appId: String; let appKey: String }

        private enum CodingKeys: String, CodingKey {
            case zhongtai, edge, amap, analytics, push, crash
            case sensors, jpush, bugly      // 老格式字段
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // 新键为 edge（与参考工程 spec.json 命名一致）；zhongtai 保留兼容旧包
            if let v = try? c.decodeIfPresent(Zhongtai.self, forKey: .edge) {
                zhongtai = v
            } else {
                zhongtai = try? c.decodeIfPresent(Zhongtai.self, forKey: .zhongtai)
            }
            amap = try? c.decodeIfPresent(Amap.self, forKey: .amap)

            // 新格式优先；缺失时回退到老格式按厂商字段，归一化成 ProviderConfig
            if let v = try c.decodeIfPresent(ProviderConfig.self, forKey: .analytics) {
                analytics = v
            } else if let s = try c.decodeIfPresent(SensorsLegacy.self, forKey: .sensors) {
                analytics = ProviderConfig(provider: "sensors", config: ["serverURL": s.serverURL, "token": s.token])
            } else {
                analytics = nil
            }

            if let v = try c.decodeIfPresent(ProviderConfig.self, forKey: .push) {
                push = v
            } else if let j = try c.decodeIfPresent(JPushLegacy.self, forKey: .jpush) {
                push = ProviderConfig(provider: "jpush", config: ["appKey": j.appKey, "masterSecret": j.masterSecret])
            } else {
                push = nil
            }

            if let v = try c.decodeIfPresent(ProviderConfig.self, forKey: .crash) {
                crash = v
            } else if let b = try c.decodeIfPresent(BuglyLegacy.self, forKey: .bugly) {
                crash = ProviderConfig(provider: "bugly", config: ["appId": b.appId, "appKey": b.appKey])
            } else {
                crash = nil
            }
        }
    }

    let revision: Int?              // 装配版本号（每次 assemble 不同；引导页据此重置，nil 兼容旧包）
    let identity: Identity
    let brand: Brand
    let plugins: [PluginRef]
    let content: Content
    let monetization: Monetization
    let compliance: Compliance
    let onboarding: Onboarding?
    let support: Support?
    let integrations: Integrations?

    static func load() -> AppSpec {
        guard let url = Bundle.main.url(forResource: "spec", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let spec = try? JSONDecoder().decode(AppSpec.self, from: data) else {
            fatalError("spec.json 缺失或格式错误，无法启动装配")
        }
        return spec
    }
}
