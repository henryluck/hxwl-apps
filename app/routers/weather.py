"""天气路由：解密客户端 AES 请求，经 QWeatherClient 转发上游天气接口。

对外三档：now（实况）/ 24h（逐小时）/ 7d（逐日）。入参 `{"location": "lng,lat"}`，
服务端拼成上游 v1 路径（/weather/v1/{kind}/{lat}/{lon}），响应保持统一包络
（ok/code/message/result），result 为上游原样 JSON。未配置凭证 → 9011 fail-closed。
"""
import logging
import re

from fastapi import APIRouter, Depends, Request

from app.deps import ParsedRequest, parse_request
from app.errors import (CODE_INVALID_REQUEST, CODE_WEATHER_NOT_CONFIGURED,
                        error_response, success_response)
from app.qweather import QWeatherClient, QWeatherError

logger = logging.getLogger("edge")

router = APIRouter()

# 入参 location 格式「lng,lat」（十进制度，宽松校验：形状对即可，不卡范围）
_LOCATION_RE = re.compile(r"\s*-?\d{1,3}\.\d+\s*,\s*-?\d{1,3}\.\d+\s*")

# 对外档位 → 上游 v1 路径片段与查询串
_V1_SEGMENT = {
    "now": ("current", ""),
    "24h": ("hourly", "?hours=24"),
    "7d": ("daily", "?days=7"),
}


def get_qweather(request: Request) -> QWeatherClient:
    """从应用状态获取天气客户端（lifespan/create_app 启动时注入）"""
    return request.app.state.qweather


@router.post("/api/v1/forecast/now")
async def weather_now(request: Request, req: ParsedRequest = Depends(parse_request),
                      qw: QWeatherClient = Depends(get_qweather)):
    """实况天气：上游 /weather/v1/current/{lat}/{lon}"""
    return await _forward_common(qw, req, "now")


@router.post("/api/v1/forecast/24h")
async def weather_24h(request: Request, req: ParsedRequest = Depends(parse_request),
                      qw: QWeatherClient = Depends(get_qweather)):
    """24 小时预报：上游 /weather/v1/hourly/{lat}/{lon}?hours=24"""
    return await _forward_common(qw, req, "24h")


@router.post("/api/v1/forecast/7d")
async def weather_7d(request: Request, req: ParsedRequest = Depends(parse_request),
                     qw: QWeatherClient = Depends(get_qweather)):
    """7 天预报：上游 /weather/v1/daily/{lat}/{lon}?days=7"""
    return await _forward_common(qw, req, "7d")


async def _forward_common(qw: QWeatherClient, req: ParsedRequest, kind: str):
    """共用转发：未配置 9011 → location 校验 9004 → 上游失败透传错误码。"""
    if not qw.configured():
        return error_response(CODE_WEATHER_NOT_CONFIGURED, "天气服务未配置")
    location = (req.data or {}).get("location")
    if not isinstance(location, str) or not _LOCATION_RE.fullmatch(location):
        return error_response(CODE_INVALID_REQUEST, "location 必须为 'lng,lat'")
    parts = [p.strip() for p in location.split(",")]
    lng, lat = parts[0], parts[1]
    seg, query = _V1_SEGMENT[kind]
    path = f"/weather/v1/{seg}/{lat}/{lng}{query}"  # 上游按 lat/lon 顺序编入路径
    try:
        data = await qw.get(path)
    except QWeatherError as e:
        logger.warning("[%s] weather failed: %s %s", req.rid, path, e.msg)
        return error_response(e.code, e.msg)
    return success_response(data)
