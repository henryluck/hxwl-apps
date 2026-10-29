"""测试主流程：验证完整的登录流程、解密失败处理及统计事件转发。"""
import time

import httpx
from fastapi.testclient import TestClient

import app.config as cfg
from app.crypto import encrypt_to_b64
from app.main import create_app


def _app_with_tianxu(monkeypatch):
    """构造注入天枢mock transport的测试应用。"""
    # 用 MockTransport 让 AccessToken 与 login 都成功
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/accesstoken":
            return httpx.Response(200, json={"success": True, "code": 0, "data": {
                "accessToken": "TOK", "expiresIn": int(time.time() * 1000) + 86400000}})
        return httpx.Response(200, json={"success": True, "code": 0, "data": {"userId": 100123}})
    monkeypatch.setenv("TIANXU_APP_KEY", "real_key")
    monkeypatch.setenv("TIANXU_APP_SECRET", "real_secret")
    monkeypatch.setenv("TOKEN_API_URL", "https://provider.example.com/api/accesstoken")
    monkeypatch.setenv("TOKEN_API_KEY", "provider-api-key")

    from app import main as main_module
    # 重建 app 以应用 env 变更（显式传入重载后的 settings，避免使用 import 时固化的默认配置）
    app = main_module.create_app(settings=cfg.load_settings(),
                                 http_client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    return app


def test_full_login_flow(monkeypatch):
    """验证完整的登录流程：从请求解密到天枢转发再到响应返回。"""
    app = _app_with_tianxu(monkeypatch)
    client = TestClient(app)
    body = encrypt_to_b64({"data": {}})
    r = client.post("/api/v1/session/start", content=body,
                    headers={"Authorization": encrypt_to_b64({"deviceId": "d", "prdId": "1234501"}),
                             "Content-Type": "application/json",
                             "X-Forwarded-For": "8.8.8.8"})
    assert r.status_code == 200
    assert r.json() == {"ok": True, "code": 0, "message": "", "result": {"userId": 100123}}


def test_missing_prd_id_returns_9004(monkeypatch):
    """端到端：客户端未带 prdId 时本地拦截为 9004，不请求上游（HTTP 仍为 200）。

    服务端已不再按环境补 prdId（改由 App 的 spec.json 透传），缺值必须在本地立即失败，
    否则会带着空值打上游、只能拿到「310016 没有产品数据权限」这类无法区分原因的错误。
    """
    app = _app_with_tianxu(monkeypatch)
    client = TestClient(app)
    body = encrypt_to_b64({"data": {}})
    r = client.post("/api/v1/session/start", content=body,
                    headers={"Authorization": encrypt_to_b64({"deviceId": "d"}),
                             "Content-Type": "application/json"})
    assert r.status_code == 200
    j = r.json()
    assert j["ok"] is False
    assert j["code"] == 9004
    assert "prdId" in j["message"]


def test_decrypt_failure_returns_9001(monkeypatch):
    """验证解密失败时返回9001错误码。"""
    app = _app_with_tianxu(monkeypatch)
    client = TestClient(app)
    # body 是无法解密的乱码
    r = client.post("/api/v1/session/start", content="!!!not ciphertext!!!",
                    headers={"Authorization": "!!!bad!!!", "Content-Type": "application/json"})
    assert r.status_code == 200
    j = r.json()
    assert j["ok"] is False
    assert j["code"] == 9001


def test_statistics_event_forwards_to_shence(monkeypatch):
    """验证统计事件会转发到天枢shence接口。"""
    app = _app_with_tianxu(monkeypatch)
    client = TestClient(app)
    body = encrypt_to_b64({"data": {"eventName": "$AppStart"}})
    r = client.post("/api/v1/telemetry/event", content=body,
                    headers={"Authorization": encrypt_to_b64({"deviceId": "d", "prdId": "1234501"}),
                             "Content-Type": "application/json"})
    assert r.status_code == 200
    # 事件转发到天枢 shence，响应来自天枢 mock（不再是本地 stub 的 {result:{}}）
    assert r.json() == {"ok": True, "code": 0, "message": "", "result": {"userId": 100123}}


def test_docs_blocked_by_default(monkeypatch):
    """验证默认（未配置 DOCS_ENABLED，即非本地/生产）时 API 文档全部 404。"""
    monkeypatch.delenv("DOCS_ENABLED", raising=False)  # 隔离本地 .env 里的显式开启
    app = create_app(settings=cfg.load_settings())
    client = TestClient(app)
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert client.get(path).status_code == 404, path


def test_docs_enabled_via_env(monkeypatch):
    """验证 DOCS_ENABLED=true（本地开发）时可访问 Swagger 文档。"""
    monkeypatch.setenv("DOCS_ENABLED", "true")
    app = create_app(settings=cfg.load_settings())
    client = TestClient(app)
    assert client.get("/docs").status_code == 200
    assert client.get("/openapi.json").status_code == 200
