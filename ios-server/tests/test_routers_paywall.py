"""测试订阅页策略决策路由：天枢 deviceInfo → strategyId → 套餐映射 → 下发商品+文案；
未映射 / 天枢失败 / 缺参数时 DEFAULT+B 兜底（业务兜底 ok=True 不算错误）。"""
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.crypto import encrypt_to_b64
from app.routers import paywall


class FakeTianxu:
    """天枢客户端测试替身：preset_strategy 控制返回的 strategyId；None 模拟业务失败。"""
    def __init__(self, preset_strategy=None, ok=True):
        self.preset_strategy = preset_strategy
        self.ok = ok
        self.calls = []

    async def forward(self, path, adheader, data, rid=""):
        self.calls.append((path, data))
        if not self.ok:
            return {"ok": False, "code": 500, "message": "upstream fail", "result": None}
        return {"ok": True, "code": 0, "message": "",
                "result": {"strategyId": self.preset_strategy} if self.preset_strategy is not None else {}}

    async def get_access_token(self):
        return "TOK"


def _app(fake, mapping):
    paywall._map_cache.clear()
    paywall._map_mtime = -1.0
    import json as _json
    import tempfile, pathlib
    tmp = pathlib.Path(tempfile.mkdtemp()) / "map.json"
    tmp.write_text(_json.dumps(mapping), encoding="utf-8")
    paywall._MAP_PATH = tmp
    a = FastAPI()
    a.include_router(paywall.router)
    a.state.tianxu = fake
    return a


MAPPING = {
    "default_plan": "B",
    "plans": {
        "A": {"product_id": "com.yourcompany.appname.vip.weekly.offer",
              "copy": {"launch_price_line": "新人0元试用3天，之后¥58/周",
                        "card_title": "新人0元试用",
                        "card_desc": "试用3天，之后¥58/周自动续费",
                        "tag": "新人0元"}},
        "B": {"product_id": "com.yourcompany.appname.vip.weekly"},
        "C": {"product_id": "com.yourcompany.appname.vip.weekly.deal"},
        "D": {"product_id": "com.yourcompany.appname.vip.weekly.promo"},
    },
    "strategy_map": {"16645": "B", "16648": "C", "99999": "X"},
}


def _post(client, adhead):
    return client.post("/api/v1/paywall/strategy",
                       content=encrypt_to_b64({"data": {}}),
                       headers={"Authorization": encrypt_to_b64(adhead),
                                "Content-Type": "application/json"})


def test_strategy_mapped_returns_plan_and_product():
    fake = FakeTianxu(preset_strategy=16648)
    r = _post(TestClient(_app(fake, MAPPING)), {"deviceId": "dev1", "prdId": "p1"})
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["result"]["plan"] == "C"
    assert body["result"]["productId"] == "com.yourcompany.appname.vip.weekly.deal"
    assert body["result"]["strategyId"] == 16648


def test_strategy_mapped_with_copy_camelizes_fields():
    fake = FakeTianxu(preset_strategy=16645)
    r = _post(TestClient(_app(fake, MAPPING)), {"deviceId": "dev1", "prdId": "p1"})
    body = r.json()
    # B 在测试映射表里没配 copy → 不带 copy 键（客户端模板兜底）
    assert "copy" not in body["result"]

    mapping2 = dict(MAPPING)
    mapping2["strategy_map"] = {"1": "A"}
    fake2 = FakeTianxu(preset_strategy=1)
    body2 = _post(TestClient(_app(fake2, mapping2)),
                  {"deviceId": "dev1", "prdId": "p1"}).json()
    copy = body2["result"]["copy"]
    assert copy["launchPriceLine"] == "新人0元试用3天，之后¥58/周"
    assert copy["tag"] == "新人0元"


def test_unmapped_strategy_falls_back_default_b():
    fake = FakeTianxu(preset_strategy=77777)
    body = _post(TestClient(_app(fake, MAPPING)), {"deviceId": "dev1", "prdId": "p1"}).json()
    assert body["ok"] is True
    assert body["result"]["plan"] == "B"
    assert body["result"]["productId"] == "com.yourcompany.appname.vip.weekly"
    assert body["result"]["strategyId"] == 77777


def test_tianxu_failure_falls_back_default():
    fake = FakeTianxu(ok=False)
    body = _post(TestClient(_app(fake, MAPPING)), {"deviceId": "dev1", "prdId": "p1"}).json()
    assert body["ok"] is True
    assert body["result"]["plan"] == "DEFAULT"
    assert body["result"]["productId"] == "com.yourcompany.appname.vip.weekly"


def test_missing_adhead_fields_fall_back():
    fake = FakeTianxu(preset_strategy=16645)
    body = _post(TestClient(_app(fake, MAPPING)), {"prdId": "p1"}).json()
    assert body["ok"] is True
    assert body["result"]["plan"] == "DEFAULT"
    # 缺 deviceId 时不该去打天枢
    assert fake.calls == []


def test_no_strategy_id_falls_back_default():
    fake = FakeTianxu(preset_strategy=None)  # 天枢成功但无 strategyId
    body = _post(TestClient(_app(fake, MAPPING)), {"deviceId": "dev1", "prdId": "p1"}).json()
    assert body["result"]["plan"] == "DEFAULT"


def test_strategy_map_entry_pointing_to_unknown_plan_falls_back():
    # strategy_map 里 99999 → "X"（plans 没有 X）：按未映射兜底
    fake = FakeTianxu(preset_strategy=99999)
    body = _post(TestClient(_app(fake, MAPPING)), {"deviceId": "dev1", "prdId": "p1"}).json()
    assert body["result"]["plan"] == "B"
