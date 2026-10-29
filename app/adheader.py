"""天枢广告头（adheader）构建。

prdId 的权威来源是**客户端**：App 的 `Resources/spec.json → integrations.edge.prdId`。
服务端只做透传、不再按环境强制覆盖，因此同一台 server 可以同时服务多个 App / 多个产品。

缺失 prdId 的请求由 `TianxuClient.forward` 本地拦截（CODE_INVALID_REQUEST），
不会带着空值打上游（否则会拿到「310016 没有产品数据权限」这类难以定位的上游错误）。
"""

TIANXU_FIXED_FIELDS = {
    "platform": "iOS",  # 平台（固定 iOS）
    "phoneType": "iOS",  # 手机类型（固定 iOS）
    "manufacturer": "Apple",  # 设备厂商（固定 Apple）
    "currentChannel": 61,  # 当前渠道号（固定 61）
    "version": "3.0.6.5",  # 版本号（固定 3.0.6.5）
    "versionCode": 3065,  # 版本号（数字形式，固定 3065）
}


def build_tianxu_adheader(adhead: dict, client_ip: str, timestamp_ms: int) -> dict:
    """构建天枢 API 所需的广告头（合并客户端传入字段、固定字段、IP、时间戳）

    Args:
        adhead: 客户端传入的广告头字典（经过解密）
        client_ip: 客户端真实 IP（从 X-Forwarded-For 或 remote_addr 提取）
        timestamp_ms: 当前时间戳（毫秒）

    Returns:
        完整的天枢广告头字典（含固定字段、IP、时间戳）
    """
    out = dict(adhead) if isinstance(adhead, dict) else {}  # 复制客户端传入的广告头
    out.update(TIANXU_FIXED_FIELDS)  # 填充固定字段（平台、版本等）
    # prdId 纯透传客户端值（App 为唯一权威来源，服务端不覆盖 → 一台 server 可服务多 App）。
    # 归一化为去空白的字符串（客户端可能传数字型 prdId）；缺失/为空时**删除该键**，
    # 交由 TianxuClient.forward 本地拦截，避免把空值透给天枢。
    prd_id = str(out.get("prdId") or "").strip()
    if prd_id:
        out["prdId"] = prd_id
    else:
        out.pop("prdId", None)
    out["ip"] = client_ip  # 添加客户端 IP
    out["timestamp"] = timestamp_ms  # 添加时间戳（毫秒）
    return out
