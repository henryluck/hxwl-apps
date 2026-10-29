"""测试对话路由：加密信封解密、参数校验、模型白名单、SSE 透传与错误信封。"""
import dataclasses

import httpx
from fastapi import FastAPI
from fastapi.testclient import TestClient

import app.config as cfg
from app.crypto import encrypt_to_b64
from app.errors import (CODE_INVALID_REQUEST, CODE_LLM_NOT_CONFIGURED, CODE_LLM_UNREACHABLE,
                        CODE_RATE_LIMITED)
from app.ratelimit import SlidingWindowLimiter
from app.routers import chat
from app.siliconflow import SiliconFlowClient, SiliconFlowError

MESSAGES = [{"role": "user", "content": "你好，你是谁"}]


class FakeSiliconFlow:
    """SiliconFlow 客户端测试替身：记录调用参数并返回预设 SSE 行。"""
    def __init__(self, lines=None, error=None):
        self.calls = []
        self.closed = 0  # aclose 调用次数（验证 BackgroundTask 兜底关闭）
        self._lines = lines if lines is not None else ['data: {"delta":{"content":"嗨"}}', "data: [DONE]"]
        self.error = error  # open_stream 阶段抛出的异常（流开始前失败）

    async def open_stream(self, messages, model=None):
        self.calls.append({"messages": messages, "model": model})
        if self.error:
            raise self.error
        return self

    async def lines(self):
        for line in self._lines:
            yield line

    async def aclose(self):
        self.closed += 1


class FakeFailingStream:
    """流中途失败的替身：产出第一行后抛 SiliconFlowError。"""
    def __init__(self):
        self.closed = 0

    async def open_stream(self, messages, model=None):
        return self

    async def lines(self):
        yield 'data: {"delta":{"content":"你"}}'
        raise SiliconFlowError(CODE_LLM_UNREACHABLE, "上游连接中断")

    async def aclose(self):
        self.closed += 1


class FakeRuntimeErrorStream:
    """流中途抛非预期异常的替身（如编码/迭代 bug），不应静默截断流。"""
    async def open_stream(self, messages, model=None):
        return self

    async def lines(self):
        yield 'data: {"delta":{"content":"你"}}'
        raise RuntimeError("意外的迭代错误")

    async def aclose(self):
        pass


def _app(fake, **setting_over):
    """构造注入替身客户端的测试应用（bare FastAPI，无日志中间件）。"""
    s = dataclasses.replace(cfg.settings, **setting_over)
    a = FastAPI()
    a.include_router(chat.router)
    a.state.siliconflow = fake
    a.state.settings = s
    a.state.chat_limiter = SlidingWindowLimiter(s.rate_limit_per_minute, s.rate_limit_per_day)
    return a


def _post(client, data, adhead=None):
    """构造并发送加密的 POST 请求（默认 adhead 带 deviceId=d）。"""
    return client.post("/api/v1/assistant/chat", content=encrypt_to_b64({"data": data}),
                       headers={"Authorization": encrypt_to_b64(adhead or {"deviceId": "d"}),
                                "Content-Type": "application/json"})


def test_chat_streams_sse():
    """验证正常请求返回 SSE：上游行原样透传，事件分隔保留。"""
    c = TestClient(_app(FakeSiliconFlow()))
    resp = _post(c, {"messages": MESSAGES})
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/event-stream")
    assert resp.text == 'data: {"delta":{"content":"嗨"}}\ndata: [DONE]\n'
    # SSE 必须禁用缓存与代理缓冲，否则流式会被 nginx 打包成整包
    assert resp.headers["cache-control"] == "no-cache"
    assert resp.headers["x-accel-buffering"] == "no"


def test_chat_passes_messages_and_default_model():
    """验证消息列表解密后透传，未指定模型时用服务端默认模型。"""
    fake = FakeSiliconFlow()
    c = TestClient(_app(fake))
    _post(c, {"messages": MESSAGES})
    assert fake.calls == [{"messages": MESSAGES, "model": "Qwen/Qwen3.5-4B"}]


def test_chat_full_mode_passes_all_history():
    """full 模式（默认）：多轮历史全量透传上游，模型可看到完整上下文。"""
    fake = FakeSiliconFlow()
    c = TestClient(_app(fake))
    history = [{"role": "system", "content": "你是助手"},
               {"role": "user", "content": "第一问"},
               {"role": "assistant", "content": "第一答"},
               {"role": "user", "content": "第二问"}]
    _post(c, {"messages": history})
    assert fake.calls[0]["messages"] == history


def test_chat_current_only_mode_keeps_system_and_last_user():
    """current_only 模式：只发 system + 最后一条 user，历史 user/assistant 全部丢弃。"""
    fake = FakeSiliconFlow()
    c = TestClient(_app(fake, chat_history_mode="current_only"))
    _post(c, {"messages": [{"role": "system", "content": "你是助手"},
                           {"role": "user", "content": "第一问"},
                           {"role": "assistant", "content": "第一答"},
                           {"role": "user", "content": "第二问"}]})
    assert fake.calls[0]["messages"] == [{"role": "system", "content": "你是助手"},
                                         {"role": "user", "content": "第二问"}]


def test_chat_current_only_mode_without_system():
    """current_only 模式且无 system：只保留最后一条 user（当前问题）。"""
    fake = FakeSiliconFlow()
    c = TestClient(_app(fake, chat_history_mode="current_only"))
    _post(c, {"messages": [{"role": "user", "content": "第一问"},
                           {"role": "assistant", "content": "第一答"},
                           {"role": "user", "content": "只发这条"}]})
    assert fake.calls[0]["messages"] == [{"role": "user", "content": "只发这条"}]


def test_chat_model_in_whitelist_allowed():
    """验证白名单内的模型可被客户端指定。"""
    fake = FakeSiliconFlow()
    c = TestClient(_app(fake, siliconflow_allowed_models=("m1", "Qwen/Qwen3.5-4B")))
    _post(c, {"messages": MESSAGES, "model": "m1"})
    assert fake.calls[0]["model"] == "m1"


def test_chat_rejects_model_not_in_whitelist():
    """验证白名单外的模型被拒绝（9004），且不发起上游请求。"""
    fake = FakeSiliconFlow()
    c = TestClient(_app(fake, siliconflow_allowed_models=("m1", "Qwen/Qwen3.5-4B")))
    resp = _post(c, {"messages": MESSAGES, "model": "expensive"})
    assert resp.status_code == 200
    assert resp.json() == {"ok": False, "code": CODE_INVALID_REQUEST,
                           "message": "model 不在允许列表内: expensive"}
    assert fake.calls == []


def test_chat_rejects_invalid_messages():
    """验证 messages 缺失/空/形状不对时返回 9004，且不发起上游请求。"""
    fake = FakeSiliconFlow()
    c = TestClient(_app(fake))
    for bad in (
        {},                                     # 缺 messages
        {"messages": "not-a-list"},             # 非列表
        {"messages": []},                       # 空列表
        {"messages": [{"role": "user"}]},       # 缺 content
        {"messages": [{"content": "hi"}]},      # 缺 role
        {"messages": [{"role": "hack", "content": "hi"}]},  # role 非法
        {"messages": [{"role": "user", "content": 123}]},   # content 非字符串
    ):
        resp = _post(c, bad)
        assert resp.json()["ok"] is False, bad
        assert resp.json()["code"] == CODE_INVALID_REQUEST, bad
    assert fake.calls == []


def test_chat_open_stream_error_returns_error_envelope():
    """验证流开始前的上游失败返回标准 JSON 错误信封（HTTP 200）。"""
    fake = FakeSiliconFlow(error=SiliconFlowError(CODE_LLM_UNREACHABLE, "SiliconFlow 请求失败: x"))
    c = TestClient(_app(fake))
    resp = _post(c, {"messages": MESSAGES})
    assert resp.status_code == 200
    assert resp.json() == {"ok": False, "code": CODE_LLM_UNREACHABLE,
                           "message": "SiliconFlow 请求失败: x"}


def test_chat_not_configured_returns_error_envelope():
    """验证未配置 API Key（真实客户端）返回 9005 错误信封。"""
    real = SiliconFlowClient(httpx.AsyncClient(),
                             dataclasses.replace(cfg.settings, siliconflow_api_key=""))
    c = TestClient(_app(real))
    resp = _post(c, {"messages": MESSAGES})
    assert resp.json() == {"ok": False, "code": CODE_LLM_NOT_CONFIGURED,
                           "message": "SILICONFLOW_API_KEY 未配置，请在 .env 填入"}


def test_chat_mid_stream_error_appends_error_event():
    """验证流中途失败：已产出行保留，随后追加错误事件与 [DONE] 收尾。"""
    c = TestClient(_app(FakeFailingStream()))
    resp = _post(c, {"messages": MESSAGES})
    assert resp.status_code == 200
    text = resp.text
    assert text.startswith('data: {"delta":{"content":"你"}}\n')
    assert '"code": 9006' in text and "上游连接中断" in text
    assert "data: [DONE]" in text


def test_chat_mid_stream_unexpected_error_appends_error_event():
    """验证流中途的非预期异常也追加错误事件（9000）而非静默截断。"""
    c = TestClient(_app(FakeRuntimeErrorStream()))
    resp = _post(c, {"messages": MESSAGES})
    assert resp.status_code == 200
    text = resp.text
    assert text.startswith('data: {"delta":{"content":"你"}}\n')
    assert '"code": 9000' in text and "意外的迭代错误" in text
    assert "data: [DONE]" in text


def test_chat_closes_upstream_after_stream():
    """验证响应结束后 BackgroundTask 兜底关闭上游流（生成器未启动窗口也不泄漏连接）。"""
    fake = FakeSiliconFlow()
    c = TestClient(_app(fake))
    _post(c, {"messages": MESSAGES})
    assert fake.closed == 1


def test_chat_rejects_too_many_messages():
    """验证 messages 条数超上限被拒绝（9004），防止刷服务端付费额度。"""
    fake = FakeSiliconFlow()
    c = TestClient(_app(fake))
    resp = _post(c, {"messages": [{"role": "user", "content": "hi"}] * 51})
    assert resp.json()["code"] == CODE_INVALID_REQUEST
    assert fake.calls == []


def test_chat_rejects_oversized_single_content():
    """验证单条 content 超长被拒绝（9004）。"""
    fake = FakeSiliconFlow()
    c = TestClient(_app(fake))
    resp = _post(c, {"messages": [{"role": "user", "content": "x" * 16001}]})
    assert resp.json()["code"] == CODE_INVALID_REQUEST
    assert fake.calls == []


def test_chat_rejects_oversized_total_content():
    """验证所有 content 总长超上限被拒绝（9004）。"""
    fake = FakeSiliconFlow()
    c = TestClient(_app(fake))
    resp = _post(c, {"messages": [{"role": "user", "content": "x" * 14000}] * 5})  # 70k > 64k
    assert resp.json()["code"] == CODE_INVALID_REQUEST
    assert fake.calls == []


def test_chat_strips_extra_message_keys():
    """验证转发前把消息投影为 role/content，客户端夹带的 tool_calls 等额外键不透传上游。"""
    fake = FakeSiliconFlow()
    c = TestClient(_app(fake))
    _post(c, {"messages": [{"role": "user", "content": "hi",
                            "tool_calls": [{"id": "x"}], "name": "evil"}]})
    assert fake.calls[0]["messages"] == [{"role": "user", "content": "hi"}]


def test_chat_rate_limited_after_minute_burst():
    """验证超分钟配额返回 9007，且超限请求不再打到上游（零成本拒绝）。"""
    fake = FakeSiliconFlow()
    c = TestClient(_app(fake, rate_limit_per_minute=2))
    assert _post(c, {"messages": MESSAGES}).status_code == 200      # 第 1 次
    assert _post(c, {"messages": MESSAGES}).status_code == 200      # 第 2 次
    resp = _post(c, {"messages": MESSAGES})                          # 第 3 次 → 限流
    assert resp.json()["ok"] is False
    assert resp.json()["code"] == CODE_RATE_LIMITED
    assert "每分钟" in resp.json()["message"]
    assert len(fake.calls) == 2  # 被拒请求未触达上游


def test_chat_rate_limit_isolated_per_device():
    """验证限流按设备维度隔离：设备 A 打满不影响设备 B。"""
    fake = FakeSiliconFlow()
    c = TestClient(_app(fake, rate_limit_per_minute=1))
    assert _post(c, {"messages": MESSAGES}, adhead={"deviceId": "A"}).status_code == 200
    assert _post(c, {"messages": MESSAGES}, adhead={"deviceId": "A"}).json()["code"] == CODE_RATE_LIMITED
    assert _post(c, {"messages": MESSAGES}, adhead={"deviceId": "B"}).status_code == 200


def test_chat_rate_limit_day_window():
    """验证日配额独立生效：分钟配额富余但日上限到了仍拒绝。"""
    fake = FakeSiliconFlow()
    c = TestClient(_app(fake, rate_limit_per_minute=10, rate_limit_per_day=2))
    _post(c, {"messages": MESSAGES})
    _post(c, {"messages": MESSAGES})
    resp = _post(c, {"messages": MESSAGES})
    assert resp.json()["code"] == CODE_RATE_LIMITED
    assert "每天" in resp.json()["message"]


async def test_sse_not_buffered_by_middleware():
    """端到端（create_app 全栈 + 请求日志中间件）：SSE 必须增量下发，中间件不得全量缓冲。

    用裸 ASGI 驱动（httpx ASGITransport 自身会缓冲响应体，测不出流式）：
    上游第二块被事件门闸挡住，只有当首块真实穿过中间件到达 send() 才放行。
    若中间件全量缓冲，app() 会永远等不到门闸放行 → 超时失败。
    """
    import asyncio

    from app.main import create_app

    release = asyncio.Event()  # 门闸：首块到达客户端前不放行上游第二块

    class GatedStream:
        async def open_stream(self, messages, model=None):
            return self

        async def lines(self):
            yield 'data: {"delta":{"content":"块1"}}'
            await release.wait()
            yield "data: [DONE]"

        async def aclose(self):
            pass

    def tianxu_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"ok": True, "code": 0, "message": "", "result": {}})

    app = create_app(settings=dataclasses.replace(cfg.settings, siliconflow_api_key="sk-test"),
                     http_client=httpx.AsyncClient(transport=httpx.MockTransport(tianxu_handler)))
    app.state.siliconflow = GatedStream()  # 覆盖真实客户端，专注测中间件行为

    body = encrypt_to_b64({"data": {"messages": MESSAGES}}).encode()
    scope = {
        "type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
        "method": "POST", "scheme": "http",
        "path": "/api/v1/assistant/chat", "raw_path": b"/api/v1/assistant/chat",
        "query_string": b"", "headers": [
            (b"content-type", b"application/json"),
            (b"authorization", encrypt_to_b64({"deviceId": "d"}).encode()),
            (b"content-length", str(len(body)).encode()),
        ], "server": ("testserver", 80), "client": ("127.0.0.1", 123),
    }
    body_messages = []

    async def receive():
        if not receive.sent:  # 一次性发完整请求体
            receive.sent = True
            return {"type": "http.request", "body": body, "more_body": False}
        # 模拟真实连接：请求体发完后挂起等待，而不是伪造 http.disconnect
        # （伪造断开会让 StreamingResponse 的 disconnect 监听取消整个流）
        await asyncio.Event().wait()
    receive.sent = False

    async def send(message):
        if message["type"] == "http.response.body" and message.get("body"):
            body_messages.append(message["body"])
            if "块1".encode() in message["body"]:
                release.set()  # 首块已穿过中间件 → 放行上游第二块

    await asyncio.wait_for(app(scope, receive, send), timeout=5)  # 中间件若缓冲则此处超时
    joined = b"".join(body_messages)
    assert b'data: {"delta":{"content":"\xe5\x9d\x971"}}' in joined  # 首块内容完整
    assert b"data: [DONE]" in joined
