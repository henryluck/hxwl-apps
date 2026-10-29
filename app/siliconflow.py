"""SiliconFlow 流式对话客户端：封装 OpenAI 兼容 chat/completions 的 SSE 透传。

API Key 只在服务端持有，绝不透出给客户端；上游网络/HTTP 错误统一转译为
SiliconFlowError，供路由层在流开始前返回标准错误信封、流中追加错误事件。
"""
import logging
from typing import Any, AsyncIterator, Optional

import httpx

from app.config import Settings
from app.errors import CODE_LLM_NOT_CONFIGURED, CODE_LLM_UNREACHABLE

logger = logging.getLogger("edge")


def _has_api_key(value: str) -> bool:
    """检查 API Key 是否有效（与天枢 has_credentials 同约定：TODO_ 占位视为未配置）。"""
    return bool(value) and not value.startswith("TODO_")


class SiliconFlowError(Exception):
    """SiliconFlow 请求错误（含错误码和错误信息）"""
    def __init__(self, code: int, msg: str):
        self.code = code  # 错误码（如 CODE_LLM_UNREACHABLE）
        self.msg = msg  # 错误信息
        super().__init__(msg)


class UpstreamSSEStream:
    """上游 SSE 流句柄：lines() 逐行产出上游响应，消费结束或中断时关闭底层连接。"""

    def __init__(self, response: httpx.Response):
        self._response = response  # 已建立的流式响应（stream=True）
        self._closed = False  # 关闭标记（aclose 幂等）

    async def aclose(self) -> None:
        """幂等关闭上游连接（兜底：生成器从未启动时由路由的 BackgroundTask 调用）。"""
        if not self._closed:
            self._closed = True
            await self._response.aclose()

    async def lines(self) -> AsyncIterator[str]:
        """逐行迭代上游 SSE 响应；流中途网络错误转译为 SiliconFlowError。"""
        try:
            async for line in self._response.aiter_lines():
                yield line
        except httpx.HTTPError as e:
            raise SiliconFlowError(CODE_LLM_UNREACHABLE, f"SiliconFlow 流中断: {e}") from e
        finally:
            await self.aclose()  # 客户端断开/迭代结束都释放上游连接


class SiliconFlowClient:
    """SiliconFlow OpenAI 兼容对话客户端（SSE 流式）"""
    def __init__(self, http_client: httpx.AsyncClient, settings: Settings):
        self._http = http_client  # HTTP 客户端（复用全局 app.state.http）
        self._settings = settings  # 配置对象

    async def open_stream(self, messages: Any, model: Optional[str] = None) -> UpstreamSSEStream:
        """建立上游流式连接：发送请求并校验状态码，成功后返回 SSE 行迭代器。

        Args:
            messages: OpenAI 格式消息列表（role/content）
            model: 模型名（None 时用服务端默认模型；白名单校验由路由层负责）

        Returns:
            UpstreamSSEStream（调用其 lines() 逐行消费 SSE）

        Raises:
            SiliconFlowError: 未配置 API Key、网络失败或上游返回非 200
        """
        if not _has_api_key(self._settings.siliconflow_api_key):
            raise SiliconFlowError(CODE_LLM_NOT_CONFIGURED,
                                   "SILICONFLOW_API_KEY 未配置，请在 .env 填入")
        payload = {"model": model or self._settings.siliconflow_model,
                   "messages": messages, "stream": True,
                   "max_tokens": self._settings.siliconflow_max_tokens}  # 单响应成本上限
        # 思考模式开关（DeepSeek OpenAI 兼容格式，见 api-docs.deepseek.com/guides/thinking_mode）：
        # thinking.type = "enabled"/"disabled"。本场景为短问答，默认禁用以保证首字节快；
        # 传 SiliconFlow 风格的 enable_thinking 会被 DeepSeek 忽略（思考模式默认打开）。
        payload["thinking"] = {"type": "enabled" if self._settings.siliconflow_enable_thinking
                               else "disabled"}
        url = f"{self._settings.siliconflow_base_url}/chat/completions"
        # LLM 流式响应远慢于天枢接口，读超时用专属配置（connect/write 仍取常规值）
        timeout = httpx.Timeout(connect=10.0, read=self._settings.llm_timeout_sec,
                                write=10.0, pool=10.0)
        request = self._http.build_request(
            "POST", url, json=payload, timeout=timeout,
            headers={"Authorization": f"Bearer {self._settings.siliconflow_api_key}",
                     "Accept": "text/event-stream"})
        try:
            response = await self._http.send(request, stream=True)
        except httpx.HTTPError as e:
            raise SiliconFlowError(CODE_LLM_UNREACHABLE, f"SiliconFlow 请求失败: {e}") from e
        if response.status_code != 200:
            detail = b""
            async for chunk in response.aiter_bytes():  # 有界读取，防巨型错误体撑爆日志
                detail += chunk
                if len(detail) >= 512:
                    break
            await response.aclose()
            raise SiliconFlowError(CODE_LLM_UNREACHABLE,
                                   f"SiliconFlow 返回 HTTP {response.status_code}: "
                                   f"{detail[:200].decode('utf-8', 'ignore')}")
        return UpstreamSSEStream(response)
