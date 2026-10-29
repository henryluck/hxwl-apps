"""测试限流模块：滑动窗口计数（分钟+日双窗）与限流 key 构建。"""


class FakeClock:
    """可控时钟：避免测试依赖真实时间流逝。"""
    def __init__(self, start=1000.0):
        self.t = start

    def __call__(self) -> float:
        return self.t


def test_minute_window_blocks_after_limit():
    """验证每分钟窗口：达到上限后拒绝，拒绝原因说明分钟限额。"""
    from app.ratelimit import SlidingWindowLimiter
    limiter = SlidingWindowLimiter(per_minute=3, per_day=100, clock=FakeClock())
    assert limiter.check("k")[0] is True   # 1
    assert limiter.check("k")[0] is True   # 2
    assert limiter.check("k")[0] is True   # 3
    ok, reason = limiter.check("k")        # 4 → 拒绝
    assert ok is False
    assert "每分钟" in reason


def test_minute_window_slides():
    """验证分钟窗口滑动：过窗口后配额恢复。"""
    from app.ratelimit import SlidingWindowLimiter
    clock = FakeClock()
    limiter = SlidingWindowLimiter(per_minute=2, per_day=100, clock=clock)
    limiter.check("k")
    limiter.check("k")
    assert limiter.check("k")[0] is False
    clock.t += 61  # 越过 60s 窗口
    assert limiter.check("k")[0] is True


def test_day_window_blocks_independent_of_minute():
    """验证日窗口独立生效：分钟配额恢复但日上限到了仍拒绝。"""
    from app.ratelimit import SlidingWindowLimiter
    clock = FakeClock()
    limiter = SlidingWindowLimiter(per_minute=100, per_day=2, clock=clock)
    limiter.check("k")
    limiter.check("k")
    ok, reason = limiter.check("k")
    assert ok is False
    assert "每天" in reason
    clock.t += 61  # 分钟窗口滑过，日窗口仍在
    assert limiter.check("k")[0] is False


def test_keys_isolated():
    """验证不同 key（设备/IP）配额互不影响。"""
    from app.ratelimit import SlidingWindowLimiter
    limiter = SlidingWindowLimiter(per_minute=1, per_day=100, clock=FakeClock())
    assert limiter.check("dev:a")[0] is True
    assert limiter.check("dev:a")[0] is False  # a 打满
    assert limiter.check("dev:b")[0] is True   # b 不受影响


def test_zero_disables_limit():
    """验证限额配置为 0 表示不限制该窗口。"""
    from app.ratelimit import SlidingWindowLimiter
    limiter = SlidingWindowLimiter(per_minute=0, per_day=0, clock=FakeClock())
    for _ in range(50):
        assert limiter.check("k")[0] is True


def test_build_key_prefers_device_id():
    """验证限流 key：adhead 有 deviceId 用设备维度，缺失/非法时退回 IP。"""
    from app.ratelimit import build_key
    assert build_key({"deviceId": "abc"}, "1.2.3.4") == "dev:abc"
    assert build_key({}, "1.2.3.4") == "ip:1.2.3.4"
    assert build_key({"deviceId": 123}, "1.2.3.4") == "ip:1.2.3.4"  # 非字符串忽略
    assert build_key({"deviceId": "  "}, "1.2.3.4") == "ip:1.2.3.4"  # 空白忽略
    assert build_key({}, "") == "ip:unknown"  # 无 IP 兜底
