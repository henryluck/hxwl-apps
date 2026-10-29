"""测试 SiliconFlow 流式客户端：鉴权头、请求体、SSE 行透传、超时与错误转译。"""
import dataclasses
import json

import httpx

import app.config as cfg
from app.errors import CODE_LLM_NOT_CONFIGURED, CODE_LLM_UNREACHABLE
from app.siliconflow import SiliconFlowClient, SiliconFlowError

MESSAGES = [{"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "你好，你是谁"}]
SSE_LINES = ['data: {"id":"1","choices":[{"delta":{"content":"你"}}]}',
             'data: {"id":"1","choices":[{"delta":{"content":"好"}}]}',
             "data: [DONE]"]


def _settings(**over):
    """构造仅覆盖 LLM 相关配置的 Settings（其余字段沿用全局配置）。"""
    defaults = dict(
        siliconflow_api_key="sk-test",
        siliconflow_base_url="https://api.siliconflow.cn/v1",
        siliconflow_model="Qwen/Qwen3.5-4B",
        siliconflow_allowed_models=("Qwen/Qwen3.5-4B",),
        llm_timeout_sec=120.0,
    )
    defaults.update(over)
    return dataclasses.replace(cfg.settings, **defaults)


def _client(handler, **settings_over):
    """构造挂 MockTransport 的 SiliconFlow 客户端（真实 httpx 栈，仅替换网络层）。"""
    return SiliconFlowClient(httpx.AsyncClient(transport=httpx.MockTransport(handler)),
                             _settings(**settings_over))


async def _drain(client, messages=MESSAGES, model=None):
    """打开上游流并收完全部 SSE 行。"""
    stream = await client.open_stream(messages, model=model)
    return [line async for line in stream.lines()]


def _sse_response(lines=SSE_LINES):
    """构造上游 SSE 成功响应。"""
    body = ("\n".join(lines) + "\n").encode("utf-8")
    return httpx.Response(200, content=body, headers={"content-type": "text/event-stream"})


async def test_open_stream_sends_auth_and_payload():
    """验证请求打到 chat/completions，带 Bearer 鉴权头，payload 含默认模型和 stream=True。"""
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["auth"] = request.headers.get("authorization")
        seen["payload"] = json.loads(request.content)
        return _sse_response()

    client = _client(handler)
    await _drain(client)
    assert seen["url"] == "https://api.siliconflow.cn/v1/chat/completions"
    assert seen["auth"] == "Bearer sk-test"
    assert seen["payload"]["model"] == "Qwen/Qwen3.5-4B"  # 未传模型时用服务端默认
    assert seen["payload"]["messages"] == MESSAGES
    assert seen["payload"]["stream"] is True


async def test_model_override_passed_to_upstream():
    """验证客户端指定的模型会透传给上游。"""
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["payload"] = json.loads(request.content)
        return _sse_response()

    client = _client(handler)
    await _drain(client, model="Qwen/Qwen3.5-8B")
    assert seen["payload"]["model"] == "Qwen/Qwen3.5-8B"


async def test_sse_lines_passed_through_in_order():
    """验证上游 SSE 行按原顺序完整透传。"""
    def handler(request: httpx.Request) -> httpx.Response:
        return _sse_response()

    assert await _drain(_client(handler)) == SSE_LINES


async def test_read_timeout_uses_llm_config():
    """验证读超时用 LLM 专属配置（而非全局 10s 天枢超时）。"""
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["timeout"] = request.extensions.get("timeout")
        return _sse_response()

    client = _client(handler, llm_timeout_sec=77.0)
    await _drain(client)
    assert seen["timeout"]["read"] == 77.0


async def test_missing_api_key_raises_not_configured():
    """验证未配置 SILICONFLOW_API_KEY 时直接报未配置错误，不发起上游请求。"""
    def handler(request: httpx.Request) -> httpx.Response:  # pragma: no cover - 不应被调用
        raise AssertionError("不应发起上游请求")

    client = _client(handler, siliconflow_api_key="")
    try:
        await client.open_stream(MESSAGES)
        raise AssertionError("应当抛出 SiliconFlowError")
    except SiliconFlowError as e:
        assert e.code == CODE_LLM_NOT_CONFIGURED


async def test_todo_placeholder_key_treated_as_unconfigured():
    """验证 TODO_ 占位 Key 视为未配置（与天枢 has_credentials 约定一致），返回 9005 而非外呼 401。"""
    def handler(request: httpx.Request) -> httpx.Response:  # pragma: no cover - 不应被调用
        raise AssertionError("不应发起上游请求")

    client = _client(handler, siliconflow_api_key="TODO_填你的SiliconFlowKey")
    try:
        await client.open_stream(MESSAGES)
        raise AssertionError("应当抛出 SiliconFlowError")
    except SiliconFlowError as e:
        assert e.code == CODE_LLM_NOT_CONFIGURED


async def test_payload_includes_max_tokens():
    """验证上游请求带 max_tokens 上限（控制单响应成本），值取自配置。"""
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["payload"] = json.loads(request.content)
        return _sse_response()

    await _drain(_client(handler))
    assert seen["payload"]["max_tokens"] == 2048  # 默认值

    seen.clear()
    await _drain(_client(handler, siliconflow_max_tokens=512))
    assert seen["payload"]["max_tokens"] == 512  # 环境变量可覆盖


async def test_payload_disables_thinking_by_default():
    """验证上游请求默认带 thinking.type="disabled"（DeepSeek 思考模式关闭）。

    DeepSeek OpenAI 兼容格式的思考开关是 extra_body {"thinking": {"type": ...}}；
    旧 SiliconFlow 风格 enable_thinking 会被 DeepSeek 忽略（其思考模式默认打开）。
    """
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["payload"] = json.loads(request.content)
        return _sse_response()

    await _drain(_client(handler))
    assert seen["payload"]["thinking"] == {"type": "disabled"}

    seen.clear()
    await _drain(_client(handler, siliconflow_enable_thinking=True))
    assert seen["payload"]["thinking"] == {"type": "enabled"}


async def test_upstream_error_detail_bounded():
    """验证上游错误详情有界截断：巨型错误体不会撑爆日志与错误信封。"""
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, content=b"x" * 100_000)  # 100KB 错误体

    client = _client(handler)
    try:
        await client.open_stream(MESSAGES)
        raise AssertionError("应当抛出 SiliconFlowError")
    except SiliconFlowError as e:
        assert e.code == CODE_LLM_UNREACHABLE
        assert len(e.msg) < 500  # 错误消息有界


async def test_upstream_http_error_raises_unreachable():
    """验证上游非 200 响应被转译为 LLM 不可达错误（含状态码）。"""
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, json={"error": {"message": "Invalid key"}})

    client = _client(handler)
    try:
        await client.open_stream(MESSAGES)
        raise AssertionError("应当抛出 SiliconFlowError")
    except SiliconFlowError as e:
        assert e.code == CODE_LLM_UNREACHABLE
        assert "401" in e.msg


async def test_network_error_raises_unreachable():
    """验证连接失败被转译为 LLM 不可达错误。"""
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    client = _client(handler)
    try:
        await client.open_stream(MESSAGES)
        raise AssertionError("应当抛出 SiliconFlowError")
    except SiliconFlowError as e:
        assert e.code == CODE_LLM_UNREACHABLE


async def test_mid_stream_network_error_translated():
    """验证流中途断开：已收行正常透传，之后抛 SiliconFlowError（路由据此追加错误事件）。"""
    async def gen():  # 异步生成器：AsyncClient 要求响应流为 AsyncByteStream
        yield b'data: {"delta":{"content":"\xe4\xbd\xa0"}}\n'
        raise httpx.ReadError("connection reset")

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=gen(),
                              headers={"content-type": "text/event-stream"})

    client = _client(handler)
    stream = await client.open_stream(MESSAGES)
    got, err = [], None
    try:
        async for line in stream.lines():
            got.append(line)
    except SiliconFlowError as e:
        err = e
    assert got == ['data: {"delta":{"content":"你"}}']
    assert err is not None and err.code == CODE_LLM_UNREACHABLE
