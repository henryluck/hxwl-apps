"""天气客户端：Ed25519 JWT 签名（PyJWT EdDSA）+ GET 转发 + 进程内缓存。

上游走和风新版 v1 接口（路径形如 /weather/v1/current/{lat}/{lon}），
私钥只在服务端（keys/ 目录 gitignored），客户端经 AES 信封代理访问，
永不接触天气凭证。四项配置（kid/project_id/api_host/private_key_path）
缺任一即视为未配置（configured()=False，路由层降级 9011）。
"""
import logging
import time

import httpx
import jwt

from app.config import Settings
from app.errors import CODE_UPSTREAM_FAILED

logger = logging.getLogger("edge")

_TOKEN_TTL_SEC = 900        # JWT 有效期（和风要求 ≤900s）
_TOKEN_LEEWAY_SEC = 30      # 签发时间回拨（容忍服务端时钟偏差）+ 缓存提前刷新余量
_CACHE_TTL_SEC = 600        # 天气数据进程内缓存 TTL
_CACHE_MAX_ENTRIES = 512    # 缓存条目上限（超过整表清空，防内存无界增长）


class QWeatherError(Exception):
    """和风 API 错误（含错误码和错误信息）"""
    def __init__(self, code: int, msg: str):
        self.code = code  # 错误码（如 CODE_UPSTREAM_FAILED）
        self.msg = msg    # 错误信息
        super().__init__(msg)


class QWeatherClient:
    """天气 API 客户端（EdDSA JWT 签名 + 路径级进程内缓存）"""
    def __init__(self, http: httpx.AsyncClient, settings: Settings):
        self.http = http              # HTTP 客户端（复用全局连接池）
        self.settings = settings      # 配置对象
        self._cached_jwt = None       # (token, exp) —— 缓存的 JWT 及其过期时间
        self._cache: dict = {}        # path -> (ts, json)，TTL 600s

    def _token(self) -> str:
        """获取（或签发）当前有效的 EdDSA JWT（缓存期内直接复用）。"""
        now = int(time.time())
        if self._cached_jwt and self._cached_jwt[1] - _TOKEN_LEEWAY_SEC > now:
            return self._cached_jwt[0]
        with open(self.settings.qweather_private_key_path) as f:
            private_key = f.read()
        payload = {"sub": self.settings.qweather_project_id,   # 项目 ID（和风要求）
                   "iat": now - _TOKEN_LEEWAY_SEC,             # 签发时间（回拨 30s）
                   "exp": now + _TOKEN_TTL_SEC}                # 过期时间（15 分钟）
        headers = {"kid": self.settings.qweather_kid, "alg": "EdDSA"}
        token = jwt.encode(payload, private_key, algorithm="EdDSA", headers=headers)
        self._cached_jwt = (token, now + _TOKEN_TTL_SEC)
        return token

    async def get(self, path: str, ttl: int = _CACHE_TTL_SEC) -> dict:
        """GET 上游接口（v1 路径形如 /weather/v1/current/{lat}/{lon}），命中缓存直接返回。

        Args:
            path: 上游 API 路径（以 / 开头，经纬度已按上游要求编入路径）
            ttl: 缓存有效期秒数

        Returns:
            上游响应 JSON（原样字段）

        Raises:
            QWeatherError: HTTP 非 200，或响应体带 error 字段
        """
        hit = self._cache.get(path)
        now = time.time()
        if hit and hit[0] + ttl > now:
            return hit[1]
        url = f"https://{self.settings.qweather_api_host}{path}"
        r = await self.http.get(url, headers={"Authorization": f"Bearer {self._token()}"},
                                timeout=10)
        try:
            data = r.json()
        except Exception as e:  # noqa: BLE001 - 非 JSON 响应统一收敛为上游失败
            raise QWeatherError(CODE_UPSTREAM_FAILED,
                                f"上游返回非JSON(HTTP {r.status_code})") from e
        # v1 成功响应无 code 字段（只有 metadata/业务字段），失败时带 error 对象
        if r.status_code != 200 or (isinstance(data, dict) and "error" in data):
            logger.warning("weather upstream failed: HTTP %s body=%s",
                           r.status_code, str(data)[:200])
            raise QWeatherError(CODE_UPSTREAM_FAILED, f"天气接口失败 HTTP {r.status_code}")
        self._cache[path] = (now, data)
        if len(self._cache) > _CACHE_MAX_ENTRIES:
            self._cache.clear()   # 超上限整表清空（天气缓存本就是性能优化，可全量重建）
        return data

    def configured(self) -> bool:
        """检查四项配置是否齐备（缺任一即未配置，路由层降级 9011）。"""
        return bool(self.settings.qweather_kid and self.settings.qweather_project_id
                    and self.settings.qweather_api_host and self.settings.qweather_private_key_path)
