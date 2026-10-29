import time

from fastapi import APIRouter, Depends

from app.adheader import build_tianxu_adheader
from app.deps import ParsedRequest, get_tianxu, parse_request
from app.tianxu import TianxuClient
from app.errors import CODE_INVALID_REQUEST, error_response

router = APIRouter()


def _ad(req: ParsedRequest) -> dict:
    """构建天枢请求头：包含客户端 IP 和当前时间戳"""
    return build_tianxu_adheader(req.adhead, req.client_ip, int(time.time() * 1000))


@router.post("/api/v1/telemetry/event")
async def event(req: ParsedRequest = Depends(parse_request),
                tianxu: TianxuClient = Depends(get_tianxu)):
    """神策事件埋点：转发到天枢 commerce_shence_service/api/common/uploadShenceData，原样转发 data"""
    # 神策事件埋点：data = {eventName, params}，原样转发天枢
    return await tianxu.forward(
        "commerce_shence_service/api/common/uploadShenceData", _ad(req), req.data, rid=req.rid)


@router.post("/api/v1/telemetry/profile")
async def profile(req: ParsedRequest = Depends(parse_request),
                  tianxu: TianxuClient = Depends(get_tianxu)):
    """神策用户属性：转发到天枢 commerce_shence_service/api/common/uploadShenceUserProperty，原样转发 data"""
    # 神策用户属性：data = {params, create?}，原样转发天枢
    return await tianxu.forward(
        "commerce_shence_service/api/common/uploadShenceUserProperty", _ad(req), req.data, rid=req.rid)


@router.post("/api/v1/telemetry/event/batch")
async def event_batch(req: ParsedRequest = Depends(parse_request),
                      tianxu: TianxuClient = Depends(get_tianxu)):
    """神策批量事件埋点：转发到天枢 scenead_shence_service/api/sensor/event，原样转发 sensorList

    文档（309-796）：data = {"sensorList": [{eventName, offset(毫秒), params}]}
    """
    # 基础格式校验：sensorList 必须为非空数组（条目结构由天枢侧校验，服务端保持透传）
    if (not isinstance(req.data, dict)
            or not isinstance(req.data.get("sensorList"), list)
            or not req.data["sensorList"]):
        return error_response(CODE_INVALID_REQUEST, "sensorList 必须为非空数组")
    return await tianxu.forward(
        "scenead_shence_service/api/sensor/event", _ad(req), req.data, rid=req.rid)
