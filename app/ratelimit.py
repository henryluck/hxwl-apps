"""AI 对话限流：内存滑动窗口（每设备 分钟+日 双窗口）。

单进程 uvicorn 部署下事件循环内无并发竞争，无需锁；重启清零（v1 可接受）。
限流 key 优先 deviceId（移动网络大量用户共享出口 IP，按 IP 会误伤），无设备号退回 IP。
"""
import time
from collections import deque
from typing import Callable

_MINUTE_SEC = 60.0  # 分钟窗口长度
_DAY_SEC = 86400.0  # 日窗口长度（滚动 24h，非自然日）
_MAX_KEYS = 65536  # key 字典规模上限（超过后清扫空窗口，防长期运行内存增长）


class SlidingWindowLimiter:
    """内存滑动窗口限流器：check() 同时完成检查与计数（被拒请求也消耗配额）。"""

    def __init__(self, per_minute: int, per_day: int, clock: Callable[[], float] = time.monotonic):
        self._per_minute = per_minute  # 每分钟上限（<=0 表示不限）
        self._per_day = per_day  # 每日上限（<=0 表示不限）
        self._clock = clock  # 时钟函数（可注入，便于测试）
        self._minute_hits: dict = {}  # key → 命中时间戳队列（分钟窗口）
        self._day_hits: dict = {}  # key → 命中时间戳队列（日窗口）

    @staticmethod
    def _prune(hits: deque, now: float, window: float) -> None:
        """移除滑出窗口的旧时间戳。"""
        while hits and hits[0] <= now - window:
            hits.popleft()

    def _sweep_if_large(self) -> None:
        """字典规模超上限时清扫空窗口（无近期命中的 key），防内存无界增长。"""
        if len(self._minute_hits) <= _MAX_KEYS:
            return
        for hits in (self._minute_hits, self._day_hits):
            for key in [k for k, dq in hits.items() if not dq]:
                del hits[key]

    def check(self, key: str):
        """检查 key 是否放行并记账。

        Args:
            key: 限流维度 key（如 "dev:xxx" / "ip:1.2.3.4"）

        Returns:
            (True, "") 放行；(False, 原因) 拒绝（原因说明触发的窗口与限额）
        """
        now = self._clock()
        minute = self._minute_hits.setdefault(key, deque())
        self._prune(minute, now, _MINUTE_SEC)
        if 0 < self._per_minute <= len(minute):
            return False, f"每分钟最多 {self._per_minute} 次"
        day = self._day_hits.setdefault(key, deque())
        self._prune(day, now, _DAY_SEC)
        if 0 < self._per_day <= len(day):
            return False, f"每天最多 {self._per_day} 次"
        minute.append(now)
        day.append(now)
        self._sweep_if_large()
        return True, ""


def build_key(adhead: dict, client_ip: str) -> str:
    """构建限流 key：adhead 含合法 deviceId 用设备维度，否则退回客户端 IP。

    Args:
        adhead: 解密后的广告头（设备信息）
        client_ip: 客户端真实 IP

    Returns:
        限流 key（"dev:<deviceId>" 或 "ip:<ip>"，无 IP 时 "ip:unknown"）
    """
    device = adhead.get("deviceId") if isinstance(adhead, dict) else None
    if isinstance(device, str) and device.strip():
        return f"dev:{device.strip()}"
    return f"ip:{client_ip.strip() or 'unknown'}"
