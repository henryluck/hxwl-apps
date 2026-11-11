"""天枢平台转发客户端。

注意：本模块顶部启用 PEP 563（`from __future__ import annotations`），注解在运行期不求值。
原因：`_load_shared_token` 的返回注解写作 `tuple[str, int] | None`，该写法需要 Python 3.10+；
而生产机可能是 RHEL/CentOS 8 系（默认 Python 3.6/3.9）。启用后本模块在 3.7+ 均可导入。
本模块不含 FastAPI 路由/依赖，注解不会被框架 `get_type_hints()` 解析，故安全。
"""
from __future__ import annotations

import asyncio
import fcntl
import json
import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Any

import httpx

from app.config import Settings
from app.errors import (CODE_INVALID_REQUEST, CODE_NO_CREDENTIALS,
                        CODE_UPSTREAM_UNREACHABLE, remap_upstream)

logger = logging.getLogger("edge")

CODE_TOKEN_EXPIRED = 310002  # 天枢业务码：ACCESS_TOKEN过期（被其他实例刷新作废，或自然过期）


def _mask(value: str | None, keep: int = 4) -> str:
    """脱敏字符串（保留首尾各 keep 个字符），用于日志中隐藏凭证。

    Args:
        value: 待脱敏的字符串（如 appSecret、accessToken）
        keep: 首尾各保留的字符数

    Returns:
        脱敏后的字符串（如 "abcd...wxyz"）；过短或为空时返回 "***"
    """
    if not value:
        return "***"
    if len(value) <= keep * 2:
        return "***"
    return f"{value[:keep]}...{value[-keep:]}"


class TianxuError(Exception):
    """天枢 API 错误（含错误码和错误信息）"""
    def __init__(self, code: int, msg: str):
        self.code = code  # 错误码（如 CODE_NO_CREDENTIALS）
        self.msg = msg  # 错误信息
        super().__init__(msg)


class TianxuClient:
    """天枢 API 客户端（AccessToken 三级缓存：内存 → 共享文件 → 跨进程单飞刷新；310002 自愈重试）"""
    def __init__(self, http_client: httpx.AsyncClient, settings: Settings):
        self._http = http_client  # HTTP 客户端（异步）
        self._settings = settings  # 配置对象
        self._token: str | None = None  # 当前缓存的 AccessToken
        self._expires_at_ms: int = 0  # Token 过期时间（毫秒时间戳）
        self._lock = asyncio.Lock()  # Token 刷新锁（进程内并发单飞）
        self._shared_loaded = False  # 本进程是否已成功加载过共享缓存（观测位，暂无消费方）

    def _now_ms(self) -> int:
        """获取当前时间的毫秒时间戳"""
        return int(time.time() * 1000)

    def _token_valid(self) -> bool:
        """检查内存 Token 是否有效（未过期且未到提前刷新时间）"""
        lead_ms = self._settings.access_token_refresh_lead_sec * 1000  # 提前刷新时间（毫秒）
        return bool(self._token) and self._now_ms() < self._expires_at_ms - lead_ms

    # MARK: - 共享 token 缓存（多 worker 共用同一 AccessToken，防止 refresh 互踢）

    def _load_shared_token(self) -> tuple[str, int] | None:
        """读取跨进程共享 token 文件。

        Returns:
            (token, expires_at_ms)；未配置路径/不可读/损坏/临近过期时返回 None
            （临近过期判定与内存缓存同口径：提前 lead 秒视为失效）
        """
        path = self._settings.token_cache_path
        if not path:
            return None  # 未启用共享缓存
        try:
            with open(path, encoding="utf-8") as f:
                payload = json.load(f)
            token = payload.get("token")
            expires_at_ms = int(payload.get("expires_at_ms") or 0)
        except (OSError, ValueError):
            return None  # 文件不存在/无权限/损坏：按无共享缓存处理
        if not token or expires_at_ms <= 0:
            return None
        lead_ms = self._settings.access_token_refresh_lead_sec * 1000
        if self._now_ms() >= expires_at_ms - lead_ms:
            return None  # 已过期或进入提前刷新窗口 → 视为无效
        return token, expires_at_ms

    def _store_shared_token(self, token: str, expires_at_ms: int) -> None:
        """原子写入共享 token 文件（tmp+rename，600 权限）；失败静默降级为仅进程内缓存。"""
        path = self._settings.token_cache_path
        if not path:
            return
        tmp = f"{path}.tmp.{os.getpid()}"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"token": token, "expires_at_ms": expires_at_ms}, f)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o600)
            os.replace(tmp, path)  # 原子替换，其他 worker 读到的总是完整文件
        except OSError:
            try:
                os.unlink(tmp)  # 清理半写状态的临时文件
            except OSError:
                pass

    def _clear_shared_token(self) -> None:
        """删除共享 token 文件（310002 后作废，避免其他 worker 继续用坏 token）。"""
        path = self._settings.token_cache_path
        if not path:
            return
        try:
            os.unlink(path)
        except OSError:
            pass

    @asynccontextmanager
    async def _refresh_lock(self):
        """跨进程刷新锁（flock）：同一时刻只允许一个 worker 刷新 token，锁横跨整个 HTTP 刷新。

        缓存路径未配置或锁文件不可用时降级为不加锁（各 worker 自刷，与旧行为一致）。
        """
        path = self._settings.token_cache_path
        fd = None
        if path:
            try:
                fd = os.open(f"{path}.lock", os.O_CREAT | os.O_RDWR, 0o600)
                await asyncio.to_thread(fcntl.flock, fd, fcntl.LOCK_EX)
            except OSError:
                if fd is not None:
                    os.close(fd)
                fd = None
        try:
            yield
        finally:
            if fd is not None:
                try:
                    await asyncio.to_thread(fcntl.flock, fd, fcntl.LOCK_UN)
                finally:
                    os.close(fd)

    async def get_access_token(self) -> str:
        """获取有效的 AccessToken（内存缓存 → 共享文件缓存 → 跨进程单飞刷新）

        Returns:
            有效的 AccessToken 字符串

        Raises:
            TianxuError: 未配置凭证或网络失败时抛出
        """
        if self._token_valid():
            return self._token  # type: ignore[return-value]  # Token 有效，直接返回缓存
        async with self._lock:  # 进程内单飞
            if self._token_valid():  # double-check after acquiring lock  # 获取锁后再次检查（避免重复刷新）
                return self._token  # type: ignore[return-value]
            shared = self._load_shared_token()  # 其他 worker 可能已刷新过，直接采用
            if shared:
                self._token, self._expires_at_ms = shared
                self._shared_loaded = True
                logger.info("天枢 token: 采用共享缓存 token=%s", _mask(self._token))
                return self._token  # type: ignore[return-value]
            async with self._refresh_lock():  # 跨进程单飞（锁横跨 HTTP 刷新，杜绝并发 refresh 互踢）
                shared = self._load_shared_token()  # 拿到锁后复查（等锁期间其他 worker 可能已刷新）
                if shared:
                    self._token, self._expires_at_ms = shared
                    self._shared_loaded = True
                    logger.info("天枢 token: 采用共享缓存(锁后复查) token=%s", _mask(self._token))
                    return self._token  # type: ignore[return-value]
                if not self._settings.token_api_url or not self._settings.token_api_key:
                    raise TianxuError(CODE_NO_CREDENTIALS,
                                      "TOKEN_API_URL/TOKEN_API_KEY 未配置，请在 .env 填入 token provider 地址和密钥")
                url = self._settings.token_api_url  # Token provider 地址
                headers = {"X-API-Key": self._settings.token_api_key}  # 鉴权头
                logger.info("token 刷新请求: GET %s X-API-Key=%s",
                            url, _mask(self._settings.token_api_key))
                try:
                    resp = await self._http.get(url, headers=headers)
                    resp.raise_for_status()  # 检查 HTTP 错误
                except httpx.HTTPError as e:
                    logger.warning("token 刷新失败(网络): %s", e)
                    raise TianxuError(CODE_UPSTREAM_UNREACHABLE, f"获取 AccessToken 失败: {e}") from e
                payload = resp.json()
                _data = payload.get("data") if isinstance(payload.get("data"), dict) else {}
                logger.info("token 刷新响应: HTTP %s success=%s code=%s msg=%s token=%s expiresIn=%s",
                            resp.status_code, payload.get("success"), payload.get("code"),
                            payload.get("msg"), _mask(_data.get("accessToken")), _data.get("expiresIn"))
                if not payload.get("success"):  # provider 业务错误（success != true）
                    raise TianxuError(CODE_UPSTREAM_UNREACHABLE,
                                      f"获取 AccessToken 失败: {payload.get('msg')}")
                data = payload.get("data") or {}
                token = data.get("accessToken")
                if not token:
                    raise TianxuError(CODE_UPSTREAM_UNREACHABLE, "AccessToken 响应缺少 accessToken")
                self._token = token  # 更新缓存
                self._expires_at_ms = int(data.get("expiresIn", 0))  # 更新过期时间（毫秒时间戳）
                self._store_shared_token(token, self._expires_at_ms)  # 写共享缓存供其他 worker 复用
                return token

    def invalidate_token(self) -> None:
        """作废当前 token（内存 + 共享文件），下次 get_access_token 强制刷新。"""
        self._token = None
        self._expires_at_ms = 0
        self._clear_shared_token()

    def _require_prd_id(self, adheader: dict, rid: str) -> None:
        """校验 adheader 里的 prdId 非空，并就地归一化为字符串。

        prdId 的权威来源是客户端（App 的 `spec.json → integrations.edge.prdId`），
        服务端只透传、不做任何产品映射 —— 这样同一台 server 可以**零配置**同时服务任意多个
        App / 产品，新增一个 App 不需要改服务器任何配置。

        因此缺失 prdId 属于客户端配置问题，必须**本地拦截**：
        带空值打上游只会拿到「310016 没有产品数据权限」这类无法区分原因的响应，
        既污染上游日志，也让真机联调难以定位。

        注意：本服务**不做 prdId 白名单**（有意为之）。AES 信封密钥随客户端分发，
        任何持有密钥的客户端都能传任意 prdId，白名单曾是唯一闸门，但会让「新增 App 要改服务器」
        违背零配置目标，故按产品决策放弃；对外的信任边界是 AES 密钥 + 天枢 appKey 的产品数据权限。

        Args:
            adheader: 待发往天枢的广告头（原地写入归一化后的 prdId）
            rid: 请求关联 ID（仅用于日志）

        Raises:
            TianxuError: prdId 缺失或为空（CODE_INVALID_REQUEST）
        """
        if not isinstance(adheader, dict):
            raise TianxuError(CODE_INVALID_REQUEST, "请求头格式错误：adheader 必须是 JSON 对象")
        prd_id = str(adheader.get("prdId") or "").strip()
        if not prd_id:
            logger.warning("[%s] 拦截：请求头缺少 prdId（客户端未配置 spec.json integrations.edge.prdId）",
                           rid)
            raise TianxuError(
                CODE_INVALID_REQUEST,
                "请求头缺少 prdId（客户端未配置 spec.json integrations.edge.prdId）")
        adheader["prdId"] = prd_id  # 归一化：客户端传数字型 prdId 时统一成字符串

    async def forward(self, path: str, adheader: dict, data: Any, rid: str = "") -> dict:
        """转发请求到天枢 API

        Args:
            path: API 路径（如 "api/v1/ad"）
            adheader: 天枢广告头（含 platform、version、prdId、ip 等）
            data: 请求数据（任意可 JSON 序列化的对象）
            rid: 请求关联 ID（串联入口→转发→响应，便于真机联调定位）

        Returns:
            本服务统一包络字典（ok/code/message/result），由上游响应重映射而来

        Raises:
            TianxuError: 缺少 prdId、网络失败或天枢返回非 JSON 时抛出
        """
        self._require_prd_id(adheader, rid)  # 本地拦截：不发无 prdId 的请求（先于 token 刷新）
        result: dict = {}
        for attempt in (1, 2):  # 310002 最多重试一次：作废缓存→强制刷新→重发
            token = await self.get_access_token()  # 获取有效 Token
            url = f"{self._settings.tianxu_base_url}/{path.lstrip('/')}"  # 拼接完整 URL
            headers = {
                "Content-Type": "application/json",
                "Access-Token": token,  # 天枢认证头
                # 广告头（JSON 字符串）。ensure_ascii=True：HTTP 头仅允许 ASCII，
                # 非 ASCII 字段（如 zgxMap 里的中文 message）转义为 \uXXXX——
                # JSON 语义不变，天枢侧解析等价；否则 httpx 编码头时 'ascii' codec 5000
                "Authorization": json.dumps(adheader, ensure_ascii=True),
            }
            logger.info("[%s] 天枢转发请求%s: POST %s adheader=%s data=%s",
                        rid, "" if attempt == 1 else "(310002重试)", url,
                        json.dumps(adheader, ensure_ascii=False),
                        json.dumps(data, ensure_ascii=False))
            try:
                resp = await self._http.post(url, json={"data": data}, headers=headers)  # 发送 POST 请求
            except httpx.HTTPError as e:
                logger.warning("[%s] 天枢转发失败(网络): POST %s %s", rid, url, e)
                raise TianxuError(CODE_UPSTREAM_UNREACHABLE, f"转发天枢失败: {e}") from e
            # 天枢业务错误（含 HTTP 4xx）通过 body 透传：天枢把 code/msg 放在 JSON body 里
            # （如 401 + {success:false, code:310003}），HTTP 状态码不代表网络失败，需原样返回给客户端。
            try:
                result = resp.json()  # 解析天枢的响应 JSON（透传给客户端）
            except Exception as e:
                logger.warning("[%s] 天枢返回非JSON响应: HTTP %s body=%s",
                               rid, resp.status_code, (resp.text or "")[:500])
                raise TianxuError(CODE_UPSTREAM_UNREACHABLE,
                                  f"天枢返回非JSON响应(HTTP {resp.status_code})") from e
            logger.info("[%s] 天枢转发响应: HTTP %s path=%s body=%s",
                        rid, resp.status_code, path, json.dumps(result, ensure_ascii=False))
            if result.get("code") == CODE_TOKEN_EXPIRED and attempt == 1:
                # token 被其他实例刷新作废（多 worker 互踢）或已到天枢侧有效期：
                # 作废本进程与共享缓存 → 强制刷新 → 重试一次；再失败则原样透传给客户端。
                logger.warning("[%s] 天枢返回310002，作废token强制刷新后重试", rid)
                self.invalidate_token()
                continue
            return remap_upstream(result)  # 成功或非 310002 错误：重映射为本服务包络后返回
