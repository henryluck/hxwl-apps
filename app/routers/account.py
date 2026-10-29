import time
from typing import Any

from fastapi import APIRouter, Depends

from app.adheader import build_tianxu_adheader
from app.deps import ParsedRequest, get_tianxu, parse_request
from app.tianxu import TianxuClient

router = APIRouter()


def _ad(req: ParsedRequest) -> dict:
    """构建天枢请求头：包含客户端 IP 和当前时间戳"""
    return build_tianxu_adheader(req.adhead, req.client_ip, int(time.time() * 1000))


@router.post("/api/v1/session/start")
async def login(req: ParsedRequest = Depends(parse_request),
                tianxu: TianxuClient = Depends(get_tianxu)):
    """客户端登录：转发到天枢 commerce_account_service/api/account/login，使用空 data"""
    return await tianxu.forward("commerce_account_service/api/account/login", _ad(req), {}, rid=req.rid)


@router.post("/api/v1/device/union")
async def digital_union(req: ParsedRequest = Depends(parse_request),
                        tianxu: TianxuClient = Depends(get_tianxu)):
    """数字联盟风控：转发到天枢 commerce_account_service/api/account/updateFields，原样转发 data"""
    return await tianxu.forward("commerce_account_service/api/account/updateFields", _ad(req), req.data, rid=req.rid)


@router.post("/api/v1/action/report")
async def behavior(req: ParsedRequest = Depends(parse_request),
                   tianxu: TianxuClient = Depends(get_tianxu)):
    """行为统计：转发到天枢 commerce_attribution_service/api/callback/commonBehavior，将 data.value 强制转为 int"""
    return await tianxu.forward(
        "commerce_attribution_service/api/callback/commonBehavior", _ad(req), _coerce_behavior_value(req.data),
        rid=req.rid)


def _coerce_behavior_value(data: Any) -> Any:
    """将行为数据中的 value 字段强制转换为整型，避免类型错误"""
    if isinstance(data, dict):
        out = dict(data)
        if "value" in out:
            try:
                # 将 value 字段转为 int
                out["value"] = int(out["value"])
            except (TypeError, ValueError):
                pass
        return out
    return data
