import Foundation

// MARK: - 地址整理：本地文字规则提取器（规则 v0.31.1 §1.1）
//
// 边界（需求红线）：
// · 纯本地文字规则——无 AI、无 OCR、无地理编码；候选不是坐标，只交给真实检索判定
// · 识别「地址/收货地址/详细地址/联系地址/地点/位置/目的地」等标签后的内容
// · 去掉姓名/手机号/固话/订单号/邮编/备注及「请送到/导航到/我要去」前缀、「到了请联系」后缀
// · 候选质量：道路连门牌/楼栋、行政区连道路或命名地点、专有名称 POI/车站；
//   只有行政区、只有类别词（公园/医院/公交站）、电话、订单号、网址、广告句、闲聊 → 不算地址
// · 跨行「行政区＋道路门牌」可合并；两个完整地址不拼接
// · 归一（全半角/首尾空白/连续空格）去重；按输入顺序；最多前 5 个，超出须提示

/// 提取结果：候选 + 是否超过显示上限（超 5 提示「仅显示前 5 个，请缩小原文范围」）
public struct AddressExtractionOutcome: Equatable {
    public var candidates: [String]
    public var totalFound: Int          // 归一去重后的总数（可能 > 5）
    public var truncated: Bool { totalFound > candidates.count }

    public init(candidates: [String], totalFound: Int) {
        self.candidates = candidates
        self.totalFound = totalFound
    }
}

enum AddressExtractor {

    // MARK: - 对外入口

    static func extractOutcome(from raw: String) -> AddressExtractionOutcome {
        let all = extractAll(from: raw)
        return AddressExtractionOutcome(candidates: Array(all.prefix(5)), totalFound: all.count)
    }

    /// 兼容旧接口：返回最多 5 个候选
    static func extract(from raw: String) -> [String] {
        extractOutcome(from: raw).candidates
    }

    // MARK: - 归一化

    /// 全角→半角（数字/字母/空格/标点）、连续空白折叠为单空格、去首尾空白。
    /// 【分段保真】换行符不折叠——提取主流程按换行分段必须在归一后仍可见；
    /// 折叠只作用于行内空白（空格/制表符）。
    static func normalize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFF10...0xFF19: out.append(UnicodeScalar(scalar.value - 0xFF10 + 48)!)   // 全角数字
            case 0xFF21...0xFF3A: out.append(UnicodeScalar(scalar.value - 0xFF21 + 65)!)   // 全角大写
            case 0xFF41...0xFF5A: out.append(UnicodeScalar(scalar.value - 0xFF41 + 97)!)   // 全角小写
            case 0x3000: out.append(" ")                                                   // 全角空格
            case 0xFF0C: out.append(",")                                                   // ，
            case 0xFF1B: out.append(";")                                                   // ；
            case 0xFF1A: out.append(":")                                                   // ：
            default: out.append(scalar)
            }
        }
        // 行内折叠：按行处理，行内空白折为单空格；换行保留为分段边界
        let lines = String(out).components(separatedBy: CharacterSet(charactersIn: "\n\r"))
        let collapsed = lines.map { line in
            line.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 主流程

    private static func extractAll(from raw: String) -> [String] {
        let normalized = normalize(raw)
        guard !normalized.isEmpty else { return [] }

        // ① 分段：换行 + 中英文分号（不用逗号——门牌内逗号常见）
        let segments = normalized
            .components(separatedBy: CharacterSet(charactersIn: "\n;；"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var pieces: [String] = []
        for segment in segments {
            // ② 标签提取：「地址：xxx」「收货地址 xxx」等，取标签后内容
            if let afterLabel = contentAfterAddressLabel(segment) {
                pieces.append(afterLabel)
            } else {
                pieces.append(segment)
            }
        }

        // ③ 跨行合并：仅「上一段是纯行政区 + 当前段是道路门牌/POI」才合并为同一地址；
        //    两个完整地址、两个道路段绝不拼接
        var merged: [String] = []
        var pendingAdmin: String? = nil
        for piece in pieces {
            if isPureAdministrativeRegion(piece) {
                // 行政区链：上一候选也是纯行政区（省/市分两行）→ 保序合并成链
                if let existing = merged.last,
                   isPureAdministrativeRegion(existing), existing != piece,
                   let combined = mergeAdminChain(existing, piece) {
                    merged[merged.count - 1] = combined
                    pendingAdmin = combined
                } else {
                    pendingAdmin = piece   // 挂起等待道路门牌
                }
                continue
            }
            if let admin = pendingAdmin {
                // 只有道路门牌形态才与挂起行政区合并；完整地址（含行政区）不拼
                if looksLikeRoadOrPOI(piece), !containsAdministrativeSuffix(piece) {
                    merged.append("\(admin) \(piece)")
                } else {
                    merged.append(piece)
                }
                pendingAdmin = nil
                continue
            }
            merged.append(piece)
        }

        // ④ 清洗：去姓名/电话/订单号/邮编/备注/前后缀；去个人无关文本
        var cleaned: [String] = []
        for piece in merged {
            var text = piece
            text = stripNoise(from: text)
            text = text.trimmingCharacters(in: .whitespaces)
            // ⑤ 质量判定 + 长度 3～160
            guard text.count >= 3, text.count <= 160 else { continue }
            guard isSpecificPlace(text) else { continue }
            cleaned.append(text)
        }

        // ⑥ 归一去重（保序）
        var seen = Set<String>()
        var unique: [String] = []
        for item in cleaned where !seen.contains(item) {
            seen.insert(item)
            unique.append(item)
        }
        return unique
    }

    // MARK: - 标签识别

    /// 「地址」「收货地址」「详细地址」「联系地址」「地点」「位置」「目的地」标签后的内容
    /// 支持带/不带冒号；标签前允许有其他文字（收件人：李先生；地址：xxx）
    private static let addressLabels = ["收货地址", "详细地址", "联系地址", "地址", "目的地", "地点", "位置"]

    private static func contentAfterAddressLabel(_ segment: String) -> String? {
        for label in addressLabels {
            for sep in [":", "："] {
                let key = label + sep
                if let range = segment.range(of: key) {
                    let after = String(segment[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !after.isEmpty { return after }
                }
            }
            // 无冒号形式：「地址天津市北辰区xxx」（标签直接开头）
            if segment.hasPrefix(label), segment.count > label.count {
                let after = String(segment.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
                if !after.isEmpty, after.count >= 3 { return after }
            }
        }
        return nil
    }

    // MARK: - 噪声清洗

    /// 去掉独立噪声项与前后缀，保留地址主体
    private static func stripNoise(from text: String) -> String {
        var result = text

        // 前缀动词短语：「请送到」「帮我导航到」「导航到」「我要去」「前往」
        let prefixes = ["请送到", "请送至", "帮我导航到", "请导航到", "导航到", "我要去", "帮我送到", "送到", "前往"]
        for p in prefixes where result.hasPrefix(p) {
            result = String(result.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        }
        // 后缀尾巴：「到了请联系」「到了电话联系」「见字如面」等
        let suffixes = ["到了请联系", "到了电话联系", "到时联系", "到了打电话", "请联系"]
        for s in suffixes where result.hasSuffix(s) {
            result = String(result.dropLast(s.count)).trimmingCharacters(in: .whitespaces)
        }

        // 按逗号/空格分词，剔除噪声 token 后重组
        let tokens = result.components(separatedBy: CharacterSet(charactersIn: "，, 、"))
        var kept: [String] = []
        for token in tokens {
            let t = token.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if isNoiseToken(t) { continue }
            kept.append(t)
        }
        // 重组用空格（地址内空格不影响检索）
        return kept.joined(separator: " ")
    }

    /// 独立噪声项：姓名（纯中文 2-4 字且无地址特征）/ 手机号 / 固话 / 订单号 / 邮编 / 备注词
    private static func isNoiseToken(_ t: String) -> Bool {
        // 手机号（1xx…）与固话（区号-号码）
        if isPhoneNumber(t) { return true }
        // 订单号：纯数字 6 位以上 / 「订单」前缀 / 字母数字混合单号
        if t.range(of: #"^订单[号:]?\s*\S+$"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"^\d{6,}$"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"^[A-Z]{2}\d{10,}$"#, options: .regularExpression) != nil { return true }
        // 邮编：6 位纯数字且以行政区无关方式出现（已上面覆盖）；姓名标签
        if t.range(of: #"^(收件人|发件人|联系人|姓名|收货人)[:：]?$"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"^(收件人|发件人|联系人|姓名|收货人)[:：].+$"#, options: .regularExpression) != nil { return true }
        // 纯中文姓名：2-4 个汉字、无任何地址特征（道路/门牌/行政区词都不含）且不是 POI 名称
        // 【保护】含道路字（路/街/道/巷/弄/号）或行政区字（省市区县镇乡旗盟）的 token 一律不判姓名
        if t.count >= 2, t.count <= 4,
           t.range(of: #"^[\u{4E00}-\u{9FFF}]+$"#, options: .regularExpression) != nil,
           !t.contains(where: { "路街道巷弄号省市区县镇乡旗盟栋楼层苑园".contains($0) }),
           !looksLikeNamedPOI(t) {
            return true
        }
        // 备注类词
        let noiseWords = ["备注", "电话", "手机", "联系方式", "邮箱", "谢谢", "感谢", "快递", "包邮",
                          "尽快", "急", "勿拆", "放门口", "放前台", "代收"]
        if noiseWords.contains(t) { return true }
        if t.hasPrefix("电话") || t.hasPrefix("手机") { return true }
        return false
    }

    private static func isPhoneNumber(_ t: String) -> Bool {
        t.range(of: #"^1[3-9]\d{9}$"#, options: .regularExpression) != nil
            || t.range(of: #"^0\d{2,3}-?\d{7,8}$"#, options: .regularExpression) != nil
    }

    // MARK: - 质量判定

    /// 是否「具体地点」：道路连门牌/楼栋、行政区连道路或命名地点、专有名称 POI/车站
    /// 排除：只有行政区、只有类别词、时间、电话、订单号、网址、广告句、闲聊
    private static func isSpecificPlace(_ text: String) -> Bool {
        // 网址 / 纯数字 / 纯标点 / 表情符号为主 → 排除
        if text.range(of: #"^https?://"#, options: .regularExpression) != nil { return false }
        if text.range(of: #"^www\."#, options: .regularExpression) != nil { return false }
        if text.range(of: #"^[\d\s\-\+()]+$"#, options: .regularExpression) != nil { return false }

        // 只有行政区（无道路/门牌/POI）→ 不算（「北京市海淀区」「广东省深圳市」）
        if isPureAdministrativeRegion(text) { return false }

        // 只有类别词（公园/医院/公交站/地铁站/学校/超市…）无专名 → 不算
        if isBareCategory(text) { return false }

        // 时间/动作闲聊：「今天天气好，去公园散步」「我想去…」无具体地点 → 排除
        if looksLikeChatter(text) { return false }

        // 正向判定：含道路门牌特征 或 命名 POI 或 行政区+命名地点
        return containsAddressFeature(text) || looksLikeNamedPOI(text)
    }

    /// 纯行政区：整串是 1-3 段「专名+行政后缀」的组合（「天津市」「北辰区」「天津市北辰区」），
    /// 不含道路/门牌/POI。每段必须以后缀结尾，专名部分 ≥1 字。
    private static func isPureAdministrativeRegion(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 24 else { return false }
        guard text.range(of: #"^[\u{4E00}-\u{9FFF}]+$"#, options: .regularExpression) != nil else { return false }
        let adminSuffixes = ["特别行政区", "自治区", "省", "市", "区", "县", "镇", "乡", "旗", "盟"]
        // 贪心分段：从尾剥「专名+后缀」，最多 3 段（省-市-区）
        var remainder = text
        var segments = 0
        while segments < 3 {
            // 找当前尾部段的后缀：最靠左的未消费后缀（保证专名≥1字）
            var matched: (Range<String.Index>, String)?
            for suffix in adminSuffixes {
                if let r = remainder.range(of: suffix, options: .backwards), r.upperBound == remainder.endIndex {
                    // 该后缀之前至少还剩 1 个字（专名），且是本段的
                    if r.lowerBound > remainder.startIndex, matched == nil || r.lowerBound < matched!.0.lowerBound {
                        // 取最左匹配（一次剥一整段「专名+后缀」）
                        // 先找这段专名的起点：再往前找上一个后缀的结尾
                        var nameStart = remainder.startIndex
                        for s2 in adminSuffixes {
                            if let r2 = remainder.range(of: s2, options: .backwards),
                               r2.upperBound <= r.lowerBound, r2.upperBound > nameStart {
                                nameStart = r2.upperBound
                            }
                        }
                        if nameStart < r.lowerBound {   // 专名至少 1 字
                            matched = (Range(uncheckedBounds: (nameStart, r.upperBound)), suffix)
                        }
                    }
                }
            }
            guard let m = matched else { break }
            remainder.removeSubrange(m.0)
            segments += 1
            if remainder.isEmpty { return true }
        }
        return false
    }

    /// 只有类别词（无专名）：「公园」「医院」「公交站」「地铁站」「学校」「超市」「银行」…
    private static let categoryWords = ["公园", "医院", "公交站", "地铁站", "车站", "火车站", "机场",
                                        "学校", "小学", "中学", "大学", "幼儿园", "超市", "便利店",
                                        "银行", " atm", "ATM", "加油站", "充电站", "停车场", "厕所",
                                        "派出所", "邮局", "图书馆", "博物馆", "商场", "菜市场", "写字楼"]

    private static func isBareCategory(_ text: String) -> Bool {
        guard text.count <= 8 else { return false }
        if categoryWords.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) { return true }
        // 「一个公园」「附近的医院」这类泛指
        if text.range(of: #"^(一个|附近|附近的|旁边的|最近的)?[\u{4E00}-\u{9FFF}]{1,3}(公园|医院|车站|学校|超市|银行)$"#,
                      options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// 闲聊/动作句：无专名，只有天气感叹、动作意向
    private static func looksLikeChatter(_ text: String) -> Bool {
        let chatterMarkers = ["天气", "散步", "遛弯", "逛街", "随便", "不知道", "再看", "还没想好",
                              "暂未确定", "待定", "以后再说", "哈哈", "呵呵"]
        // 闲聊词在场且整串不含任何地址特征 → 排除
        if chatterMarkers.contains(where: { text.contains($0) }),
           !containsAddressFeature(text), !looksLikeNamedPOI(text) {
            return true
        }
        return false
    }

    /// 地址特征：道路/街巷+门牌/楼栋
    private static func containsAddressFeature(_ text: String) -> Bool {
        // 「路/街/道/巷/弄」+ 数字门牌；「N栋」「N号楼」「N单元」（跨空白可匹配）
        if text.range(of: #"[路街道巷弄]\s*\d{1,5}\s*号?"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"\d{1,4}\s*(栋|号楼|单元|层|楼)"#, options: .regularExpression) != nil { return true }
        // 行政区 + 道路（无门牌也算具体）：「北辰区光荣道」「北辰区 光荣道」（合并时空格分隔）
        if text.range(of: #"[区县旗]\s*\S{0,8}?\s*(路|街|道|巷)"#, options: .regularExpression) != nil { return true }
        // 小区/大厦/广场/中心/园/苑 等命名地标（排除纯类别词已在前面过滤）
        let landmarks = ["小区", "大厦", "广场", "公寓", "花园", "苑", "府", "庭", "阁", "轩",
                         "中心", "写字楼", "产业园", "科技园", "创业园", "工业园", "开发区"]
        if landmarks.contains(where: { text.contains($0) }) { return true }
        return false
    }

    /// 命名 POI/车站：带专名的场所（「天津站」「维多利广场」「协和医院」——专名+类别后缀）
    private static func looksLikeNamedPOI(_ text: String) -> Bool {
        guard text.count >= 3, text.count <= 40 else { return false }
        // 专名+站：不含「公交站/地铁站」裸词的「XX站」「XX机场」
        if text.range(of: #"^\S{1,12}站$"#, options: .regularExpression) != nil,
           text != "公交站", text != "地铁站", text != "火车站" { return true }
        if text.range(of: #"^\S{1,12}机场$"#, options: .regularExpression) != nil { return true }
        // 专名+类别：2+ 汉字专名 + 医院/学校/公园等（「协和医院」「清华园公园」）
        if text.range(of:#"^[\u{4E00}-\u{9FFF}a-zA-Z0-9]{2,12}(医院|大学|中学|小学|公园|广场|大厦|中心|市场|银行|酒店|宾馆|药店|书店)$"#,
                      options: .regularExpression) != nil {
            // 排除纯类别（一个字+类别）：已被 isBareCategory 覆盖，这里专名≥2字
            return true
        }
        return false
    }

    /// 道路或 POI 形态（跨行合并判定用）
    private static func looksLikeRoadOrPOI(_ text: String) -> Bool {
        text.range(of: #"[路街道巷弄]"#, options: .regularExpression) != nil
            || looksLikeNamedPOI(text)
            || text.range(of: #"\d{1,5}\s*号"#, options: .regularExpression) != nil
    }

    /// 含行政区后缀（市/区/县…）——用于排除「完整地址」与挂起行政区拼接
    private static func containsAdministrativeSuffix(_ text: String) -> Bool {
        let suffixes = ["特别行政区", "自治区", "省", "市", "区", "县", "镇", "乡", "旗", "盟"]
        return suffixes.contains { text.contains($0) }
    }

    /// 行政区链合并：「天津市」+「北辰区」→「天津市北辰区」（两段都是纯行政区才并）
    private static func mergeAdminChain(_ first: String, _ second: String) -> String? {
        guard isPureAdministrativeRegion(first), isPureAdministrativeRegion(second),
              !first.contains(second), !second.contains(first) else { return nil }
        return first + second
    }
}
