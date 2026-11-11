"""订阅页策略决策路由（多策略商品映射 A/B/C/D）：按投放策略 ID 决定客户端展示哪个周订阅商品。

链路（订阅页策略映射架构）：
1. 客户端归因完成后调 POST /api/v1/paywall/strategy（AES 信封与既有接口一致）；
2. 服务端调天枢「查询设备信息」 commerce_attribution_service/s2s/deviceInfo
   （正式 open-api / 测试 open-test，由 TIANXU_ENV 切换；data = {deviceId, prdId}）；
3. 用返回 strategyId 查映射表 data/paywall_strategy_map.json（管理页/人工可热编辑，
   mtime 变化自动重载，无需重启）；
4. 命中 → 下发套餐 + productId + 文案；未命中 / 天枢失败 → DEFAULT + B 兜底
   （业务兜底不算错误：ok=True、HTTP 200，客户端以 fallback 埋点量化）。

时序红线：strategyId 依赖归因结果，本接口只读不写；客户端已在归因返回后才调用，
服务端转发 deviceInfo 亦不落任何状态，天然满足「先归因后查设备信息」。

上线顺序红线：映射表新加套餐前，对应商品必须已在 ASC 建好并生效——客户端对
「spec 内但商店加载不到」的商品会整组回落 B（安全哲学），等于该策略白投。
先 ASC、后北极星（commodityId）、最后改映射表。
"""
import json
import logging
import time
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, Depends

from app.adheader import build_tianxu_adheader
from app.deps import ParsedRequest, get_tianxu, parse_request
from app.errors import success_response
from app.tianxu import TianxuClient

logger = logging.getLogger("edge")

router = APIRouter()

# ---------------------------------------------------------------------------
# 映射表：data/paywall_strategy_map.json
# ---------------------------------------------------------------------------
# 形态：
# {
#   "plans": {                       # 套餐代号 → 商品与默认文案（productId 必须与 spec.json weekly_plans 一致）
#     "A": {"product_id": "com.yourcompany.appname.vip.weekly.offer", "copy": {...}},
#     "B": {"product_id": "com.yourcompany.appname.vip.weekly",      "copy": {...}},
#     "C": {"product_id": "com.yourcompany.appname.vip.weekly.deal", "copy": {...}},
#     "D": {"product_id": "com.yourcompany.appname.vip.weekly.promo","copy": {...}}
#   },
#   "strategy_map": {                # 天枢 strategyId（字符串键，JSON 限制）→ 套餐代号
#     "16642": "A", ...
#   },
#   "default_plan": "B"
# }
# copy 四字段（launch_price_line / card_title / card_desc / tag）均可省略——
# 客户端内置模板兜底（文案三级兜底：服务端 → 客户端模板 → 现状 B 文案）。

_MAP_PATH = Path(__file__).resolve().parents[2] / "data" / "paywall_strategy_map.json"
_map_cache: dict = {}
_map_mtime: float = -1.0


def _load_map() -> dict:
    """读映射表（mtime 变化自动重载；文件缺失/格式错误 → 空表，全部走 DEFAULT 兜底）。"""
    global _map_cache, _map_mtime
    try:
        mtime = _MAP_PATH.stat().st_mtime
    except OSError:
        return {}
    if mtime != _map_mtime or not _map_cache:
        try:
            loaded = json.loads(_MAP_PATH.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                _map_cache = loaded
                _map_mtime = mtime
                logger.info("策略映射表已加载: %d 个策略ID, %d 个套餐",
                            len(loaded.get("strategy_map", {})), len(loaded.get("plans", {})))
        except (json.JSONDecodeError, OSError) as e:
            logger.warning("策略映射表加载失败（保持空表，全量兜底 B）: %s", e)
    return _map_cache


def _plan_payload(plan_code: str, strategy_id: Optional[int], mapping: dict) -> dict:
    """组装单套餐下发载荷：plan / productId / copy。"""
    plans = mapping.get("plans", {})
    plan = plans.get(plan_code, {}) if isinstance(plans, dict) else {}
    product_id = plan.get("product_id", "")
    copy_obj = plan.get("copy", {}) if isinstance(plan.get("copy"), dict) else {}
    data: dict[str, Any] = {
        "strategyId": strategy_id,
        "plan": plan_code,
        "productId": product_id,
    }
    if copy_obj:
        # 键转 camelCase 对齐客户端契约（launchPriceLine/cardTitle/cardDesc/tag）
        data["copy"] = {
            "launchPriceLine": copy_obj.get("launch_price_line", ""),
            "cardTitle": copy_obj.get("card_title", ""),
            "cardDesc": copy_obj.get("card_desc", ""),
            "tag": copy_obj.get("tag", ""),
        }
    return data


@router.post("/api/v1/paywall/strategy")
async def strategy(req: ParsedRequest = Depends(parse_request),
                   tianxu: TianxuClient = Depends(get_tianxu)):
    """订阅页策略决策：deviceId/prdId 取自 adhead（信封自带），调天枢 deviceInfo 拿 strategyId 查映射。"""
    adhead = req.adhead or {}
    device_id = str(adhead.get("deviceId") or "")
    prd_id = str(adhead.get("prdId") or "")
    mapping = _load_map()
    default_plan = mapping.get("default_plan", "B") or "B"

    def fallback(strategy_id: Optional[int], reason: str) -> dict:
        logger.info("[%s] 策略决策兜底(%s): plan=%s deviceId=%s", req.rid, reason, default_plan, device_id[:12])
        payload = _plan_payload(default_plan, strategy_id, mapping)
        payload["plan"] = "DEFAULT" if strategy_id is None else payload.get("plan", default_plan)
        return success_response(payload)

    if not device_id or not prd_id:
        return fallback(None, "adhead缺deviceId/prdId")

    # 先归因后查设备信息：客户端已在归因返回后调用本接口；此处只读转发。
    ad = build_tianxu_adheader(adhead, req.client_ip, int(time.time() * 1000))
    try:
        resp = await tianxu.forward("commerce_attribution_service/s2s/deviceInfo",
                                    ad, {"deviceId": device_id, "prdId": prd_id}, rid=req.rid)
    except Exception as e:  # TianxuError / 网络异常：业务兜底，不算错误
        logger.warning("[%s] deviceInfo 调用失败，兜底 %s: %s", req.rid, default_plan, e)
        return fallback(None, "deviceInfo失败")

    if not resp.get("ok"):
        logger.info("[%s] deviceInfo 返回失败 code=%s，兜底 %s",
                    req.rid, resp.get("code"), default_plan)
        return fallback(None, "deviceInfo业务失败")

    result = resp.get("result") or {}
    raw_strategy = result.get("strategyId")
    try:
        strategy_id = int(raw_strategy) if raw_strategy is not None else None
    except (TypeError, ValueError):
        strategy_id = None
    if strategy_id is None:
        return fallback(None, "无strategyId")

    plan_code = mapping.get("strategy_map", {}).get(str(strategy_id))
    if not plan_code or plan_code not in mapping.get("plans", {}):
        logger.info("[%s] strategyId=%s 未配置映射，兜底 %s", req.rid, strategy_id, default_plan)
        return fallback(strategy_id, "strategyId未映射")

    logger.info("[%s] 策略决策: strategyId=%s → %s", req.rid, strategy_id, plan_code)
    return success_response(_plan_payload(plan_code, strategy_id, mapping))
