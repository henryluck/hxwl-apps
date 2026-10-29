import time
from typing import Any, Optional

from fastapi import APIRouter, Depends

from app.adheader import build_tianxu_adheader
from app.deps import ParsedRequest, get_tianxu, parse_request
from app.tianxu import TianxuClient

router = APIRouter()


@router.post("/api/v1/install/attribute")
async def report(req: ParsedRequest = Depends(parse_request),
                 tianxu: TianxuClient = Depends(get_tianxu)):
    """归因上报：转发到天枢 commerce_attribution_service/api/sdk/appStartNew，补 oceanengineAttr、newAttribution、installTime 字段"""
    adheader = build_tianxu_adheader(req.adhead, req.client_ip, int(time.time() * 1000))
    return await tianxu.forward(
        "commerce_attribution_service/api/sdk/appStartNew", adheader,
        _enrich_attribution(req.data, req.adhead), rid=req.rid)


def _enrich_attribution(data: Any, adhead: Optional[dict] = None) -> Any:
    """补全归因数据字段。

    1. 补 oceanengineAttr、newAttribution、installTime（如缺失）。
    2. zgxMap（广点通 CAID）兜底：平台归因服务从 **body** 读该字段，只放广告头
       （header，与 phoneId 同层级）时后台按 extraRequest 检索不到（2026-10-14 定案）。
       存量客户端（老版本 App）只把 CAID 放广告头 → body 缺失时从广告头拷贝，
       存量客户端免发版即生效。body 已有非空值时一律以 body 为准。
    """
    if isinstance(data, dict):
        out = dict(data)
        # 补巨量引擎归因字段，默认值为 1
        out.setdefault("oceanengineAttr", 1)
        # 补新归因字段，默认值为 1
        out.setdefault("newAttribution", 1)
        # 补安装时间字段（如缺失），使用当前时间戳
        if not out.get("installTime"):
            out["installTime"] = int(time.time() * 1000)
        # zgxMap 兜底：仅当 body 没带（或带了空值）时才从广告头回填
        if not out.get("zgxMap") and isinstance(adhead, dict):
            fallback = adhead.get("zgxMap")
            if fallback:
                out["zgxMap"] = fallback
        return out
    return data
