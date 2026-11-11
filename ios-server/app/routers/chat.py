"""AI 对话路由：解密客户端 AES 请求，转发 SiliconFlow 并以 SSE 流式返回。

请求沿用与其他 /api/v1 接口一致的加密信封（parse_request）；响应为 OpenAI 兼容
SSE 透传。流开始前的失败（参数/白名单/建流）返回标准 JSON 错误信封（HTTP 200），
流中途失败在流内追加错误事件并以 [DONE] 收尾。
"""
import json
import logging

from fastapi import APIRouter, Depends, Request
from fastapi.responses import StreamingResponse
from starlette.background import BackgroundTask

from app.deps import ParsedRequest, parse_request
from app.errors import CODE_INTERNAL, CODE_INVALID_REQUEST, CODE_RATE_LIMITED, error_response
from app.ratelimit import build_key
from app.siliconflow import SiliconFlowClient, SiliconFlowError

logger = logging.getLogger("edge")

router = APIRouter()

_VALID_ROLES = ("system", "user", "assistant")  # OpenAI 兼容的对话角色
_MAX_MESSAGES = 50  # 单次请求消息条数上限（防刷服务端付费额度）
_MAX_CONTENT_CHARS = 16_000  # 单条消息 content 字符上限
_MAX_TOTAL_CHARS = 64_000  # 全部消息 content 总字符上限


def get_siliconflow(request: Request) -> SiliconFlowClient:
    """从应用状态获取 SiliconFlow 客户端（lifespan/create_app 启动时注入）"""
    return request.app.state.siliconflow


def _validate(data, settings):
    """校验对话入参（messages 形状/长度上限 + 模型白名单），并投影剥离额外键。

    Returns:
        (messages, model, None) 校验通过；否则 (None, None, 错误信封 dict)
    """
    if not isinstance(data, dict):
        return None, None, error_response(CODE_INVALID_REQUEST, "请求体必须是对象")
    messages = data.get("messages")
    if not isinstance(messages, list) or not messages:
        return None, None, error_response(CODE_INVALID_REQUEST, "messages 必须为非空数组")
    if len(messages) > _MAX_MESSAGES:
        return None, None, error_response(CODE_INVALID_REQUEST,
                                          f"messages 条数超过上限 {_MAX_MESSAGES}")
    cleaned, total = [], 0
    for m in messages:
        if (not isinstance(m, dict) or m.get("role") not in _VALID_ROLES
                or not isinstance(m.get("content"), str)):
            return None, None, error_response(
                CODE_INVALID_REQUEST,
                "messages 每项需含合法 role(system/user/assistant) 与字符串 content")
        if len(m["content"]) > _MAX_CONTENT_CHARS:
            return None, None, error_response(CODE_INVALID_REQUEST,
                                              f"单条 content 超过上限 {_MAX_CONTENT_CHARS} 字符")
        total += len(m["content"])
        # 投影为 role/content：客户端夹带的 tool_calls 等额外键不透传上游
        cleaned.append({"role": m["role"], "content": m["content"]})
    if total > _MAX_TOTAL_CHARS:
        return None, None, error_response(CODE_INVALID_REQUEST,
                                          f"messages 总长度超过上限 {_MAX_TOTAL_CHARS} 字符")
    model = data.get("model")
    if model is None:
        model = settings.siliconflow_model  # 未指定模型时回落服务端默认
    elif not isinstance(model, str):
        return None, None, error_response(CODE_INVALID_REQUEST, "model 必须为字符串")
    if model not in settings.siliconflow_allowed_models:
        return None, None, error_response(CODE_INVALID_REQUEST, f"model 不在允许列表内: {model}")
    return cleaned, model, None


def _trim_history(messages, settings, rid=""):
    """按 CHAT_HISTORY_MODE 裁剪发给上游的消息。

    full（默认）：全量透传，模型携带完整多轮上下文；
    current_only：只保留 system 消息与最后一条 user 消息——每次调用只发当前
        问题、不携带历史（省 token/成本、上下文隔离），system 人设指令仍保留。

    Args:
        messages: _validate 清洗后的消息列表（role/content 投影）
        settings: 应用配置
        rid: 请求关联 ID（日志定位）

    Returns:
        裁剪后的消息列表（full 模式原样返回）
    """
    if settings.chat_history_mode != "current_only":
        return messages
    kept = [m for m in messages if m["role"] == "system"]
    for m in reversed(messages):  # 最后一条 user 即当前问题
        if m["role"] == "user":
            kept.append(m)
            break
    logger.info("[%s] chat current_only 模式: %d 条消息裁剪为 %d 条", rid, len(messages), len(kept))
    return kept


@router.post("/api/v1/assistant/chat")
async def completions(request: Request, req: ParsedRequest = Depends(parse_request),
                      siliconflow: SiliconFlowClient = Depends(get_siliconflow)):
    """流式对话：解密入参 → 限流 → 校验 → 建立 SiliconFlow 流 → SSE 透传。"""
    # 限流在参数校验前：被拒请求零成本（不触上游），滥用者也消耗配额
    limiter = request.app.state.chat_limiter
    key = build_key(req.adhead, req.client_ip)
    allowed, reason = limiter.check(key)
    if not allowed:
        logger.warning("[%s] chat rate limited: key=%s %s", req.rid, key[:16], reason)
        return error_response(CODE_RATE_LIMITED, f"请求过于频繁（{reason}），请稍后再试")
    messages, model, err = _validate(req.data, request.app.state.settings)
    if err is not None:
        return err
    messages = _trim_history(messages, request.app.state.settings, req.rid)
    try:
        upstream = await siliconflow.open_stream(messages, model=model)
    except SiliconFlowError as e:  # 流未开始，仍可返回标准 JSON 错误信封
        logger.warning("[%s] llm open failed: %s", req.rid, e.msg)
        return error_response(e.code, e.msg)

    async def event_stream():
        """逐行透传上游 SSE；中途失败追加错误事件收尾（此时响应头已发出，无法改回 JSON）。"""
        try:
            async for line in upstream.lines():
                yield (line + "\n").encode("utf-8")
            return
        except SiliconFlowError as e:
            logger.warning("[%s] llm stream aborted: %s", req.rid, e.msg)
            code, msg = e.code, e.msg
        except Exception as e:  # noqa: BLE001 - 非预期异常也收敛为错误事件，避免静默截断流
            logger.exception("[%s] llm stream crashed", req.rid)
            code, msg = CODE_INTERNAL, f"内部错误: {e}"
        event = json.dumps({"error": {"code": code, "message": msg}}, ensure_ascii=False)
        yield f"data: {event}\n\n".encode("utf-8")
        yield "data: [DONE]\n\n".encode("utf-8")

    # 禁用缓存与 Nginx 代理缓冲，否则 SSE 会被反代攒成整包返回；
    # BackgroundTask 兜底关闭上游连接（覆盖生成器从未启动的窗口）
    return StreamingResponse(event_stream(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
                             background=BackgroundTask(upstream.aclose))
