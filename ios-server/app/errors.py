"""统一响应包络与错误码。

对外包络固定为 `{"ok": bool, "code": int, "message": str, "result": any}`：
- 成功：ok=true、code=0、message=""、result=业务数据
- 失败：ok=false、code=<错误码>、message=<说明>、无 result

上游（天枢）返回的是 `{success, code, msg, data}`，由 remap_upstream 转成本包络，
保证客户端只见到一种形状。
"""
from typing import Any

CODE_INTERNAL = 9000  # 内部错误
CODE_DECRYPT_FAILED = 9001  # 解密失败
CODE_NO_CREDENTIALS = 9002  # 未配置上游凭证（TIANXU_APP_KEY/TIANXU_APP_SECRET）
CODE_UPSTREAM_UNREACHABLE = 9003  # 上游不可达（网络失败或业务错误）
CODE_INVALID_REQUEST = 9004  # 请求业务参数缺失或类型错误
CODE_LLM_NOT_CONFIGURED = 9005  # 未配置对话上游 Key（SILICONFLOW_API_KEY）
CODE_LLM_UNREACHABLE = 9006  # 对话上游不可达（网络失败或 HTTP 错误）
CODE_RATE_LIMITED = 9007  # 对话请求超过限流阈值（每设备 分钟/日 双窗口）
CODE_UPSTREAM_FAILED = 9010  # 领域上游接口失败（天气/高程：网络失败或业务错误）
CODE_WEATHER_NOT_CONFIGURED = 9011  # 未配置天气上游凭证


def error_response(code: int, msg: str) -> dict:
    """构造失败包络。

    Args:
        code: 错误码（如 CODE_DECRYPT_FAILED）
        msg: 错误说明

    Returns:
        失败包络字典（ok=False、code、message）
    """
    return {"ok": False, "code": code, "message": msg}


def success_response(result: Any = None, message: str = "") -> dict:
    """构造成功包络。

    Args:
        result: 业务数据（任意可 JSON 序列化对象）
        message: 可选的提示文案

    Returns:
        成功包络字典（ok=True、code=0、message、result）
    """
    return {"ok": True, "code": 0, "message": message, "result": result}


def remap_upstream(resp: Any) -> dict:
    """把上游响应 `{success, code, msg, data}` 重映射为本服务包络。

    上游响应形状不符合预期（非 dict）时收敛为上游不可达错误，
    避免把不可识别的结构直接透给客户端。

    Args:
        resp: 上游响应的 JSON body

    Returns:
        本服务包络字典
    """
    if not isinstance(resp, dict):
        return error_response(CODE_UPSTREAM_UNREACHABLE, "上游响应格式异常")
    out = {
        "ok": bool(resp.get("success")),
        "code": resp.get("code", 0),
        "message": resp.get("msg") or "",
    }
    if "data" in resp:
        out["result"] = resp["data"]
    return out
