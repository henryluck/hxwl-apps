"""测试高程路由：Open-Meteo 透传、round4 坐标永久缓存、points 边界与上游失败。"""
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.crypto import encrypt_to_b64
from app.routers import geo


class FakeResponse:
    """httpx 响应替身：预设状态码与 JSON。"""
    def __init__(self, status_code=200, payload=None):
        self.status_code = status_code
        self._payload = payload or {}

    def json(self):
        return self._payload


class FakeHttp:
    """app.state.http 替身：计数上游调用并返回预设响应。"""
    def __init__(self, status_code=200, payload=None):
        self.response = FakeResponse(status_code, payload)
        self.calls = []

    async def get(self, url, params=None, timeout=None):
        self.calls.append({"url": url, "params": params})
        return self.response


def _app(http):
    """构造注入替身上游的测试应用（elev_cache 每应用独立，互不污染）。"""
    a = FastAPI()
    a.include_router(geo.router)
    a.state.http = http
    a.state.elev_cache = {}
    return a


def _post(client, points):
    """按客户端信封约定 POST /api/v1/terrain/height 并返回响应 JSON。"""
    r = client.post("/api/v1/terrain/height", content=encrypt_to_b64({"data": {"points": points}}),
                    headers={"Authorization": encrypt_to_b64({"deviceId": "d"}),
                             "Content-Type": "application/json"})
    assert r.status_code == 200
    return r.json()


_PTS = [[39.9200, 116.4100], [39.9300, 116.4200]]


def test_elevation_success():
    """验证成功透传 Open-Meteo elevations，纬经度按逗号拼接转发。"""
    http = FakeHttp(payload={"elevation": [43.2, 44.0]})
    client = TestClient(_app(http))
    resp = _post(client, _PTS)
    assert resp == {"ok": True, "code": 0, "message": "", "result": {"elevations": [43.2, 44.0]}}
    assert len(http.calls) == 1
    assert http.calls[0]["url"] == "https://api.open-meteo.com/v1/elevation"
    assert http.calls[0]["params"]["latitude"] == "39.9200,39.9300"
    assert http.calls[0]["params"]["longitude"] == "116.4100,116.4200"


def test_elevation_caches_by_round4():
    """验证同批坐标（round4 归一）命中永久缓存：二次调用不再触上游。"""
    http = FakeHttp(payload={"elevation": [43.2, 44.0]})
    client = TestClient(_app(http))
    first = _post(client, _PTS)
    # 第 5 位小数差异在 round4 后同 key → 命中缓存
    second = _post(client, [[39.92001, 116.40999], [39.93002, 116.42001]])
    assert len(http.calls) == 1
    assert first["result"] == second["result"]


def test_elevation_rejects_out_of_bounds():
    """验证 points 少于 2 个或超过 100 个返回 9004。"""
    client = TestClient(_app(FakeHttp()))
    assert _post(client, [[39.92, 116.41]])["code"] == 9004
    assert _post(client, [[39.92, 116.41]] * 101)["code"] == 9004


def test_elevation_rejects_bad_shape():
    """验证 points 非列表/每项非 [lat,lng] 数值对返回 9004。"""
    client = TestClient(_app(FakeHttp()))
    assert _post(client, "not-a-list")["code"] == 9004
    assert _post(client, [[39.92], [39.93, 116.42]])["code"] == 9004
    assert _post(client, [["39.92", "116.41"], [39.93, 116.42]])["code"] == 9004


def test_elevation_upstream_failure():
    """验证上游非 200 或缺 elevation 字段返回 9010。"""
    http = FakeHttp(status_code=500)
    resp = _post(TestClient(_app(http)), _PTS)
    assert resp["ok"] is False and resp["code"] == 9010
    http_missing = FakeHttp(status_code=200, payload={"unexpected": []})
    resp2 = _post(TestClient(_app(http_missing)), _PTS)
    assert resp2["code"] == 9010


def test_elevation_cache_capped_at_2048():
    """验证缓存超 2048 条整表清空（防坐标枚举内存耗尽），清空后上游调用恢复正常。"""
    http = FakeHttp(payload={"elevation": [43.2, 44.0]})
    app = _app(http)
    # 预塞 2050 个键逼近上限之外的下一个插入（>2048 即清空）
    app.state.elev_cache = {(39.9 + i / 1e4, 116.4 + i / 1e4): [1.0, 2.0]
                            for i in range(2050)}
    client = TestClient(app)
    first = _post(client, _PTS)          # 未命中（key 不同）→ 触上游 → 插入后超限整表清空
    assert first["code"] == 0 and len(http.calls) == 1
    assert len(app.state.elev_cache) == 0
    second = _post(client, _PTS)         # 缓存已被清空 → 再触上游一次，仍正常成功
    assert second["code"] == 0 and len(http.calls) == 2
