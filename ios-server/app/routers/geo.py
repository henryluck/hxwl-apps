"""高程路由：POST /api/v1/terrain/height 转发 Open-Meteo 免费高程接口。

高程不随时间变化 → 进程内永久缓存（key=round4 坐标序列），同批坐标
只触一次上游。响应统一包络，data = {"elevations": [...]}。
"""
import logging

from fastapi import APIRouter, Depends, Request

from app.deps import ParsedRequest, parse_request
from app.errors import CODE_INVALID_REQUEST, CODE_UPSTREAM_FAILED, error_response, success_response

logger = logging.getLogger("edge")

router = APIRouter()

_MIN_POINTS = 2     # 最少坐标数（单点场景由客户端复写补足，服务端统一 2~100）
_MAX_POINTS = 100   # Open-Meteo 单请求坐标上限
_CACHE_MAX_ENTRIES = 2048  # 缓存条目上限（端点无独立限流，防坐标枚举撑爆内存；超限整表清空）
_OPEN_METEO_URL = "https://api.open-meteo.com/v1/elevation"


def _validate_points(data) -> list | None:
    """校验 points 形状（[[lat,lng]…]×2~100，数值对），返回 float 坐标列表或 None。

    Returns:
        [(lat, lng), ...] 校验通过；None 校验失败（调用方返回 5004）
    """
    pts = (data or {}).get("points") if isinstance(data, dict) else None
    if not isinstance(pts, list) or not _MIN_POINTS <= len(pts) <= _MAX_POINTS:
        return None
    coords = []
    for p in pts:
        if not isinstance(p, (list, tuple)) or len(p) != 2:
            return None
        if not all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in p):
            return None
        coords.append((float(p[0]), float(p[1])))
    return coords


@router.post("/api/v1/terrain/height")
async def elevation(request: Request, req: ParsedRequest = Depends(parse_request)):
    """批量高程：round4 归一缓存 → Open-Meteo 透传，失败 5200。"""
    coords = _validate_points(req.data)
    if coords is None:
        return error_response(CODE_INVALID_REQUEST, f"points 须为 {_MIN_POINTS}~{_MAX_POINTS} 个 [lat,lng] 数值对")
    # 高程不随时间变 → 永久内存缓存（key=round4 坐标序列，第 4 位小数内差异视为同点）
    key = tuple((round(lat, 4), round(lng, 4)) for lat, lng in coords)
    cache = request.app.state.elev_cache
    if key in cache:
        return success_response({"elevations": cache[key]})
    latitudes = ",".join(f"{lat:.4f}" for lat, _ in coords)
    longitudes = ",".join(f"{lng:.4f}" for _, lng in coords)
    try:
        r = await request.app.state.http.get(_OPEN_METEO_URL,
                                             params={"latitude": latitudes,
                                                     "longitude": longitudes},
                                             timeout=15)
        data = r.json()
    except Exception as e:  # noqa: BLE001 - 网络/解析异常统一收敛为上游失败
        logger.warning("[%s] elevation upstream failed: %s", req.rid, e)
        return error_response(CODE_UPSTREAM_FAILED, f"高程接口失败: {e}")
    if r.status_code != 200 or "elevation" not in data:
        logger.warning("[%s] elevation upstream error: HTTP %s body=%s",
                       req.rid, r.status_code, str(data)[:200])
        return error_response(CODE_UPSTREAM_FAILED, f"高程接口失败 {r.status_code}")
    elevations = data["elevation"]
    cache[key] = elevations
    if len(cache) > _CACHE_MAX_ENTRIES:
        cache.clear()   # 仿 qweather：超上限整表清空（缓存是性能优化，可全量重建）
    return success_response({"elevations": elevations})
