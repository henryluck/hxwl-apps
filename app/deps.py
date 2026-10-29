import json
import logging
from dataclasses import dataclass
from typing import Any

from fastapi import Request

from app.crypto import decrypt_b64
from app.tianxu import TianxuClient

logger = logging.getLogger("edge")


@dataclass
class ParsedRequest:
    """解析后的请求对象（含广告头、业务数据、客户端 IP、请求关联 ID）"""
    adhead: dict  # 广告头（从 Authorization header 解密）
    data: Any  # 业务数据（从请求 body 解密）
    client_ip: str  # 客户端真实 IP
    rid: str = ""  # 请求关联 ID（中间件生成，供 forward 日志串联前后端定位问题）


def _extract_client_ip(request: Request) -> str:
    """从请求中提取客户端真实 IP（优先 X-Forwarded-For，其次 remote_addr）

    Args:
        request: FastAPI Request 对象

    Returns:
        客户端 IP 字符串（无法提取时返回空字符串）
    """
    xff = request.headers.get("x-forwarded-for", "")  # 代理转发的客户端 IP 列表
    if xff:
        return xff.split(",")[0].strip()  # 取第一个 IP（真实客户端 IP）
    if request.client:
        return request.client.host  # 直连时取 remote_addr
    return ""  # 无法提取时返回空字符串


async def parse_request(request: Request) -> ParsedRequest:
    """解析并解密请求（Authorization header → adhead，body → data）

    Args:
        request: FastAPI Request 对象

    Returns:
        ParsedRequest 对象（含解密后的 adhead、data、client_ip）
    """
    auth = request.headers.get("authorization", "")  # 获取 Authorization header（base64 编密）
    adhead = decrypt_b64(auth) if auth.strip() else {}  # 解密广告头（空字符串时返回空字典）
    raw = (await request.body()).decode("utf-8", "ignore")  # 读取请求 body 并解码为 UTF-8
    payload = decrypt_b64(raw) if raw.strip() else {}  # 解密业务数据（空字符串时返回空字典）
    if isinstance(payload, dict):
        data = payload.get("data", {})  # 提取 data 字段（标准格式）
    else:
        data = payload  # 非 dict 时直接使用（兼容格式）
    rid = getattr(request.state, "rid", "")  # 中间件注入的请求关联 ID（无中间件时为空）
    # 记录 app 端发送的解密参数（adhead=设备信息，data=业务入参），便于真机联调定位
    # data 截断到 1000 字符：AI 对话上线后完整对话内容不宜全量进日志（隐私+日志量）
    data_json = json.dumps(data, ensure_ascii=False)
    if len(data_json) > 1000:
        data_json = data_json[:1000] + f"...(已截断,共{len(data_json)}字符)"
    logger.info("[%s] 收到App请求参数: adhead=%s data=%s", rid,
                json.dumps(adhead, ensure_ascii=False), data_json)
    return ParsedRequest(adhead=adhead, data=data, client_ip=_extract_client_ip(request), rid=rid)  # 构造返回对象


def get_tianxu(request: Request) -> TianxuClient:
    """从 FastAPI 应用状态中获取天枢客户端实例

    Args:
        request: FastAPI Request 对象

    Returns:
        TianxuClient 实例（在应用启动时注入到 app.state）
    """
    return request.app.state.tianxu  # 从应用状态获取天枢客户端
