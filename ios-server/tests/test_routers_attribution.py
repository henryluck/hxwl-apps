"""测试归因路由：验证归因上报时会补充必需字段（如oceanengineAttr、newAttribution、installTime），
以及 zgxMap（广点通 CAID）在 body 缺失时从广告头兜底拷贝。"""
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.crypto import encrypt_to_b64


class FakeTianxu:
    """天枢客户端的测试替身：记录调用参数并返回预设响应。"""
    def __init__(self):
        self.calls = []
        self.adheaders = []

    async def forward(self, path, adheader, data, rid=""):
        self.calls.append((path, data))
        self.adheaders.append(adheader)
        return {"ok": True, "code": 0, "message": "", "result": {}}

    async def get_access_token(self):
        return "TOK"


def _app(fake):
    """构造注入FakeTianxu的测试应用。"""
    from app.routers import attribution
    a = FastAPI()
    a.include_router(attribution.router)
    a.state.tianxu = fake
    return a


def _post(fake, data, adhead):
    """按客户端真实形态发一次归因请求（body/adhead 各自 AES 加密后 base64）。"""
    client = TestClient(_app(fake))
    body = encrypt_to_b64({"data": data})
    return client.post("/api/v1/install/attribute", content=body,
                       headers={"Authorization": encrypt_to_b64(adhead),
                                "Content-Type": "application/json"})


def test_attribution_enriches_required_fields():
    """验证归因上报会自动补充oceanengineAttr、newAttribution与installTime字段。"""
    fake = FakeTianxu()
    client = TestClient(_app(fake))
    data = {"uaWeb": "Mozilla", "idfa": "ABCD", "idfv": "IDFV1"}
    body = encrypt_to_b64({"data": data})
    r = client.post("/api/v1/install/attribute", content=body,
                    headers={"Authorization": encrypt_to_b64({"deviceId": "d"}), "Content-Type": "application/json"})
    assert r.status_code == 200
    forwarded = fake.calls[0][1]
    assert forwarded["oceanengineAttr"] == 1
    assert forwarded["newAttribution"] == 1
    assert isinstance(forwarded["installTime"], int)
    # 客户端字段保留
    assert forwarded["idfv"] == "IDFV1"


def test_attribution_keeps_existing_install_time():
    """验证归因上报时客户端传入的installTime会被保留，不会被覆盖。"""
    fake = FakeTianxu()
    client = TestClient(_app(fake))
    body = encrypt_to_b64({"data": {"idfv": "x", "installTime": 12345}})
    client.post("/api/v1/install/attribute", content=body,
                headers={"Authorization": encrypt_to_b64({}), "Content-Type": "application/json"})
    assert fake.calls[0][1]["installTime"] == 12345


# --- zgxMap（广点通 CAID）兜底：平台归因服务从 body 读，只放广告头检索不到（rule #59） ---

CAID = {"code": 0, "message": "OK", "data": [{"value": "abcdef123456", "version": "20230330"}]}


def test_attribution_copies_zgxmap_from_adhead_when_body_missing():
    """存量客户端只把 CAID 放广告头 → body 缺失时服务端兜底拷贝，免发版即生效。"""
    fake = FakeTianxu()
    r = _post(fake, {"idfv": "IDFV1"}, {"deviceId": "d", "zgxMap": CAID})
    assert r.status_code == 200
    assert fake.calls[0][1]["zgxMap"] == CAID  # 已进 body
    assert fake.adheaders[0]["zgxMap"] == CAID  # 广告头原样保留，不丢


def test_attribution_body_zgxmap_wins_over_adhead():
    """body 已带非空 CAID 时以 body 为准，广告头不覆盖它。"""
    fake = FakeTianxu()
    body_caid = {"code": 0, "message": "OK", "data": [{"value": "body-value", "version": "v"}]}
    _post(fake, {"idfv": "IDFV1", "zgxMap": body_caid}, {"zgxMap": CAID})
    assert fake.calls[0][1]["zgxMap"] == body_caid


def test_attribution_empty_body_zgxmap_falls_back_to_adhead():
    """body 带空字典（取号失败形态）时同样回填广告头里的有效值。"""
    fake = FakeTianxu()
    _post(fake, {"idfv": "IDFV1", "zgxMap": {}}, {"zgxMap": CAID})
    assert fake.calls[0][1]["zgxMap"] == CAID


def test_attribution_no_zgxmap_key_when_both_sides_missing():
    """两边都没有 CAID 时不得凭空塞空对象（上游会把空对象当有效值）。"""
    fake = FakeTianxu()
    _post(fake, {"idfv": "IDFV1"}, {"deviceId": "d"})
    assert "zgxMap" not in fake.calls[0][1]


def test_attribution_empty_adhead_zgxmap_not_copied():
    """广告头里的 zgxMap 是空值（None / {} / ""）时不回填。"""
    fake = FakeTianxu()
    _post(fake, {"idfv": "IDFV1"}, {"zgxMap": {}})
    assert "zgxMap" not in fake.calls[0][1]
