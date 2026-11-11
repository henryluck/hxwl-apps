import time
from typing import Any

from fastapi import APIRouter, Depends

from app.adheader import build_tianxu_adheader
from app.deps import ParsedRequest, get_tianxu, parse_request
from app.errors import CODE_INVALID_REQUEST, error_response
from app.tianxu import TianxuClient

router = APIRouter()


def _ad(req: ParsedRequest) -> dict:
    """构建天枢请求头：包含客户端 IP 和当前时间戳"""
    return build_tianxu_adheader(req.adhead, req.client_ip, int(time.time() * 1000))


@router.post("/api/v1/store/catalog")
async def products(req: ParsedRequest = Depends(parse_request),
                   tianxu: TianxuClient = Depends(get_tianxu)):
    """获取商品列表：转发到天枢 commerce_pay_service/api/purchase/goodsList，原样转发 data"""
    return await tianxu.forward("commerce_pay_service/api/purchase/goodsList", _ad(req), req.data, rid=req.rid)


@router.post("/api/v1/store/order")
async def order(req: ParsedRequest = Depends(parse_request),
                tianxu: TianxuClient = Depends(get_tianxu)):
    """创建订单：转发到天枢 commerce_pay_service/api/purchase/addOrder，原样转发 data"""
    return await tianxu.forward("commerce_pay_service/api/purchase/addOrder", _ad(req), req.data, rid=req.rid)


@router.post("/api/v1/store/restore")
async def restore(req: ParsedRequest = Depends(parse_request),
                  tianxu: TianxuClient = Depends(get_tianxu)):
    """恢复购买：转发到天枢 commerce_pay_service/api/purchase/recover，原样转发 data"""
    return await tianxu.forward("commerce_pay_service/api/purchase/recover", _ad(req), req.data, rid=req.rid)


@router.post("/api/v1/store/verify")
async def verify(req: ParsedRequest = Depends(parse_request),
                 tianxu: TianxuClient = Depends(get_tianxu)):
    """验单（V2）：转发到天枢 commerce_pay_service/api/purchase/iosVerifyOrderV2，原样转发 data
    V2 纯 transactionId 验单入参：transactionId + simulatesAskToBuyInSandbox + identifier + uuidString（+ 可选 receiptData）"""
    if (not isinstance(req.data, dict)
            or not isinstance(req.data.get("simulatesAskToBuyInSandbox"), bool)):
        return error_response(CODE_INVALID_REQUEST, "simulatesAskToBuyInSandbox 必须为布尔值")
    return await tianxu.forward("commerce_pay_service/api/purchase/iosVerifyOrderV2", _ad(req), req.data, rid=req.rid)


@router.post("/api/v1/store/state")
async def pay_state(req: ParsedRequest = Depends(parse_request),
                    tianxu: TianxuClient = Depends(get_tianxu)):
    """上报支付状态：转发到天枢 commerce_pay_service/api/purchase/reportState，补 platform 字段（默认 apple）"""
    return await tianxu.forward(
        "commerce_pay_service/api/purchase/reportState", _ad(req), _enrich_pay_state(req.data), rid=req.rid)


def _enrich_pay_state(data: Any) -> Any:
    """补全支付状态数据：添加 platform 字段，默认值为 apple"""
    if isinstance(data, dict):
        out = dict(data)
        # 补平台字段，默认值为 apple
        out.setdefault("platform", "apple")
        return out
    return data
