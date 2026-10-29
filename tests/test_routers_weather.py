"""测试天气路由：QWeatherClient 替身验证 now/24h/7d 转发到和风 v1、未配置 9011、location 校验 9004。"""
from dataclasses import replace

import httpx
import jwt as pyjwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi import FastAPI
from fastapi.testclient import TestClient
from httpx import AsyncClient, MockTransport

from app.config import settings as base_settings
from app.crypto import encrypt_to_b64
from app.qweather import QWeatherClient, QWeatherError
from app.routers import weather

_NOW = {"now": {"temp": "21", "pressure": "1008"}}


class FakeQWeather:
    """QWeatherClient 测试替身：记录调用并按 path 返回预设响应（或抛上游错误）。"""
    def __init__(self, responses=None, configured=True, error=None):
        self.responses = responses or {}
        self.configured_flag = configured
        self.error = error
        self.calls = []

    def configured(self):
        return self.configured_flag

    async def get(self, path, ttl=600):
        self.calls.append(path)
        if self.error:
            raise self.error
        return self.responses.get(path, _NOW)


def _app(qw):
    """构造注入替身的测试应用。"""
    a = FastAPI()
    a.include_router(weather.router)
    a.state.qweather = qw
    return a


def _post(client, path, data):
    """按客户端信封约定（Authorization + 加密 body）POST 并返回解密后的响应 JSON。"""
    r = client.post(path, content=encrypt_to_b64({"data": data}),
                    headers={"Authorization": encrypt_to_b64({"deviceId": "d"}),
                             "Content-Type": "application/json"})
    assert r.status_code == 200
    return r.json()


def test_weather_now_success():
    """验证 now 成功透传和风 v1 原样数据，location「lng,lat」按 lat/lon 编入上游路径。"""
    fake = FakeQWeather({"/weather/v1/current/39.92/116.41": _NOW})
    client = TestClient(_app(fake))
    resp = _post(client, "/api/v1/forecast/now", {"location": "116.41,39.92"})
    assert resp["ok"] is True and resp["code"] == 0
    assert resp["result"]["now"]["temp"] == "21"
    assert fake.calls == ["/weather/v1/current/39.92/116.41"]


def test_weather_forecast_paths():
    """验证 24h/7d 分别转发到 /weather/v1/hourly（?hours=24）与 /weather/v1/daily（?days=7）。"""
    fake = FakeQWeather({"/weather/v1/hourly/39.92/116.41?hours=24": {"hourly": []},
                         "/weather/v1/daily/39.92/116.41?days=7": {"daily": []}})
    client = TestClient(_app(fake))
    assert _post(client, "/api/v1/forecast/24h", {"location": "116.41,39.92"})["code"] == 0
    assert _post(client, "/api/v1/forecast/7d", {"location": "116.41,39.92"})["code"] == 0
    assert fake.calls == ["/weather/v1/hourly/39.92/116.41?hours=24",
                          "/weather/v1/daily/39.92/116.41?days=7"]


def test_weather_not_configured():
    """验证未配置和风凭证时返回 9011（fail-closed，不触上游）。"""
    fake = FakeQWeather(configured=False)
    client = TestClient(_app(fake))
    resp = _post(client, "/api/v1/forecast/now", {"location": "116.41,39.92"})
    assert resp["ok"] is False and resp["code"] == 9011
    assert fake.calls == []


@pytest.mark.parametrize("location", ["abc", "116.41", "116.41,39.92,extra", ""])
def test_weather_invalid_location(location):
    """验证 location 非 'lng,lat' 形状时返回 9004。"""
    client = TestClient(_app(FakeQWeather()))
    resp = _post(client, "/api/v1/forecast/now", {"location": location})
    assert resp["ok"] is False and resp["code"] == 9004


def test_weather_missing_location():
    """验证缺 location 字段返回 9004。"""
    client = TestClient(_app(FakeQWeather()))
    resp = _post(client, "/api/v1/forecast/now", {})
    assert resp["code"] == 9004


def test_weather_upstream_error():
    """验证上游 QWeatherError 透传错误码（9010）。"""
    fake = FakeQWeather(error=QWeatherError(9010, "天气接口失败 HTTP 401"))
    client = TestClient(_app(fake))
    resp = _post(client, "/api/v1/forecast/now", {"location": "116.41,39.92"})
    assert resp["ok"] is False and resp["code"] == 9010


# ---------- QWeatherClient 直测（EdDSA 签名 + 进程内缓存） ----------

def _make_client(tmp_path, handler) -> QWeatherClient:
    """生成 Ed25519 密钥对并构造指向 MockTransport 的客户端。"""
    private = Ed25519PrivateKey.generate()
    pem = private.private_bytes(encoding=serialization.Encoding.PEM,
                                format=serialization.PrivateFormat.PKCS8,
                                encryption_algorithm=serialization.NoEncryption())
    key_path = tmp_path / "ed25519.pem"
    key_path.write_bytes(pem)
    s = replace(base_settings, qweather_kid="test-kid", qweather_project_id="test-proj",
                qweather_api_host="api.qweather.test", qweather_private_key_path=str(key_path))
    return QWeatherClient(AsyncClient(transport=MockTransport(handler)), s)


async def test_qweather_token_signs_and_caches(tmp_path):
    """验证 JWT 以 EdDSA 签名（sub=project_id、kid 头）且缓存期内复用同一 token。"""
    client = _make_client(tmp_path, lambda r: httpx.Response(200, json=_NOW))
    t1 = client._token()
    t2 = client._token()
    assert t1 == t2  # 未过期不重签
    header = pyjwt.get_unverified_header(t1)
    assert header["kid"] == "test-kid" and header["alg"] == "EdDSA"
    with open(f"{tmp_path}/ed25519.pem") as f:
        payload = pyjwt.decode(t1, f.read(), algorithms=["EdDSA"],
                               options={"verify_aud": False})
    assert payload["sub"] == "test-proj"


async def test_qweather_get_caches_by_path(tmp_path):
    """验证 path 进程内缓存：TTL 内二次调用不再请求上游。"""
    calls = []

    def handler(request):
        calls.append(str(request.url))
        return httpx.Response(200, json=_NOW)

    client = _make_client(tmp_path, handler)
    d1 = await client.get("/weather/v1/current/39.92/116.41")
    d2 = await client.get("/weather/v1/current/39.92/116.41")
    assert d1 == d2 == _NOW and len(calls) == 1


async def test_qweather_get_business_error(tmp_path):
    """验证 v1 响应带 error 字段（HTTP 200）时抛 QWeatherError(9010)。"""
    client = _make_client(tmp_path, lambda r: httpx.Response(200, json={"error": {"status": 401}}))
    with pytest.raises(QWeatherError) as e:
        await client.get("/weather/v1/current/39.92/116.41")
    assert e.value.code == 9010


async def test_qweather_get_http_error(tmp_path):
    """验证 HTTP 非 200 时抛 QWeatherError(9010)。"""
    client = _make_client(tmp_path, lambda r: httpx.Response(500, json={}))
    with pytest.raises(QWeatherError) as e:
        await client.get("/weather/v1/current/39.92/116.41")
    assert e.value.code == 9010


def test_qweather_configured_requires_all_four(tmp_path):
    """验证四项配置缺任一即 configured()=False（默认 Settings 全空 → False）。"""
    assert QWeatherClient(AsyncClient(), base_settings).configured() is False
    client = _make_client(tmp_path, lambda r: httpx.Response(200, json=_NOW))
    assert client.configured() is True
